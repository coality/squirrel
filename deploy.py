#!/usr/bin/env python3
"""
file-deploy - MOVE files dropped into "input" directories on a mounted NAS share
into a mirror deployment tree, keeping a local archive copy behind in the source.

This is the whole program: CLI, config resolution, the cron lock, discovering the
input directories, scanning them, the per-file transaction, logging and the CSV
report. The parts that can be decided without touching the tree (config parsing,
the conflict policy, the naming rule, the encoders) live in engine.py.

Normally launched through file-deploy.sh (a tiny shell launcher that just picks
the Python interpreter), but it runs directly too: `python3 deploy.py ...`.

THE INVARIANT, which every decision below serves:

    a file never leaves the source unless it is durably present, hash-verified,
    in BOTH the local archive and the deployment tree.

What happens to one file, in order:

  1. stability          now - mtime >= MIN_STABLE_AGE, or leave it alone
  2. hash the source    never consume what could not be read back
  3. deploy             copy to a hidden temp, verify its hash, THEN rename into
                        place -- a bad copy never becomes visible and never
                        clobbers a good one
  4. re-stat the source changed under us? then what we deployed is a snapshot of
                        a half-written file: keep the original, retry
  5. commit             os.rename() into the local archive. The ONE irreversible
                        operation, and the last

Removal is last because removing first would make a deployment failure
unrecoverable -- nothing would be left in the pickup directory to retry from.
And it is a rename, not a copy-then-delete: one atomic operation instead of two,
no second full write over the network, and the archived copy cannot be truncated
because it is the same inode.

Every retry is idempotent: the archive name is a pure function of (name, source
mtime, content hash), so a run interrupted anywhere lands on exactly the same
path next time instead of piling up duplicates.

One configuration file = one source root + one deployment root. To handle
another pair, write another configuration and give it its own run.

Standard library only. Requires Python 3.9 or newer.
"""

import argparse
import csv
import errno
import fcntl
import hashlib
import json
import os
import shutil
import socket
import stat
import sys
import time
from datetime import datetime

import engine

EX_OK = 0
EX_CONFIG = 1        # bad or incomplete configuration
EX_NOSOURCE = 2      # the source is missing, unreadable or not writable
EX_LOCKED = 3        # another run of this configuration holds the lock
EX_DEPLOY = 4        # at least one deploy/archive write failed
EX_SOURCE = 5        # at least one file was deployed but could not leave the source

LEVELS = {"DEBUG": 10, "INFO": 20, "WARN": 30, "ERROR": 40}
LEAVES_CACHE_VERSION = "#v3-python"
# Where the last Log() wrote, so the top-level guard can record a crash in the
# same file as the rest of the run instead of only on stderr.
_LAST_LOG = [""]
TMP_SUFFIX = ".file-deploy-tmp"
PREV_SUFFIX = ".file-deploy-prev"


# ==========================================================================
# Logging
# ==========================================================================
class Log(object):
    """Structured, rotating, one line per event.

    One configuration means one target, so there is no second stream to keep
    apart: startup, per-file events, heartbeat and summary all land in the same
    file. `run=` correlates an execution, `instance=` names the configuration.
    """

    def __init__(self, cfg, run_id, console):
        self.cfg = cfg
        self.run_id = run_id
        self.console = console
        self.level = LEVELS.get(cfg.LOG_LEVEL, 20)
        self.debug_on = self.level <= 10
        self.path = os.path.join(cfg.LOG_DIR, "file-deploy.log")
        self.audit_path = os.path.join(cfg.LOG_DIR, "audit.log")
        self.cycle = None
        self._sizes = {}
        _LAST_LOG[0] = self.path

    def _rotate(self, path):
        keep = self.cfg.LOG_KEEP
        try:
            if keep > 0:
                last = "%s.%d" % (path, keep)
                if os.path.exists(last):
                    os.remove(last)
                for i in range(keep - 1, 0, -1):
                    src = "%s.%d" % (path, i)
                    if os.path.exists(src):
                        os.replace(src, "%s.%d" % (path, i + 1))
                os.replace(path, path + ".1")
            else:
                os.remove(path)
        except OSError:
            pass

    def _append(self, path, line):
        """Append one line, rotating first when the file has grown too big.

        The size is read once per file per run and then tracked in memory, so a
        busy run does not stat the log on every line.
        """
        limit = self.cfg.LOG_MAX_BYTES
        if limit > 0:
            if path not in self._sizes:
                try:
                    self._sizes[path] = os.path.getsize(path)
                except OSError:
                    self._sizes[path] = 0
            if self._sizes[path] >= limit:
                self._rotate(path)
                self._sizes[path] = 0
            self._sizes[path] += len(line) + 1
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass

    def __call__(self, level, event, **fields):
        if LEVELS.get(level, 20) < self.level:
            return
        ts = datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")
        if self.cfg.LOG_FORMAT == "json":
            row = {"ts": ts, "level": level, "run": self.run_id,
                   "instance": self.cfg.INSTANCE_ID}
            if self.cycle is not None:
                row["cycle"] = self.cycle
            row["event"] = event
            for k, v in fields.items():
                row[k] = "" if v is None else str(v)
            line = json.dumps(row, ensure_ascii=False, sort_keys=False)
        else:
            parts = ["%s %s run=%s instance=%s" % (ts, level, self.run_id,
                                                   self.cfg.INSTANCE_ID)]
            if self.cycle is not None:
                parts.append("cycle=%s" % self.cycle)
            parts.append("event=%s" % event)
            for k, v in fields.items():
                parts.append('%s="%s"' % (k, engine.enc("" if v is None else v)))
            line = " ".join(parts)
        self._append(self.path, line)
        if self.console:
            sys.stderr.write(line + "\n")

    def audit(self, outcome, relpath, archive_path, digest, size, prev_hash=""):
        """The provenance record: one line per file that actually moved.

        No separate "target" field: the deployment tree mirrors the source, so
        the relative path is identical on both sides by construction, and both
        roots are logged once per run in the CONFIG line.
        """
        if not self.cfg.AUDIT_LOG:
            return
        ts = datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")
        line = ('ts=%s run=%s action=%s relpath="%s" archive="%s" hash=%s size=%s'
                % (ts, self.run_id, outcome, engine.enc(relpath),
                   engine.enc(archive_path), digest, size))
        if prev_hash:
            line += " prev_hash=%s" % prev_hash
        self._append(self.audit_path, line)


# ==========================================================================
# Small filesystem helpers
# ==========================================================================
def file_digest(path, algo):
    """Content digest, or None if the file could not be read."""
    try:
        h = hashlib.new(algo)
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except (OSError, ValueError):
        return None


def stat_or_none(path):
    try:
        return os.lstat(path)
    except OSError:
        return None


def source_reason(path):
    """Why the source cannot be drained, or None when it can.

    Moving a file out needs write access, not just read: unlinking needs w+x on
    the parent directory, whatever the file's own mode.
    """
    if not os.path.exists(path):
        return "path does not exist"
    if not os.path.isdir(path):
        return "exists but is not a directory"
    if not os.access(path, os.R_OK):
        return "directory not readable (permissions)"
    if not os.access(path, os.X_OK):
        return "directory not searchable (need +x to list)"
    if not os.access(path, os.W_OK):
        return "directory not writable (files are moved out, so +w is required)"
    return None


def deepest_existing(path):
    """Longest existing prefix of a path.

    A diagnostic for a missing source: an unmounted share resolves shallow,
    a typo in the last component resolves deep.
    """
    p = os.path.abspath(path)
    while p and p != "/":
        if os.path.exists(p):
            return p
        p = os.path.dirname(p)
    return "/"


# Plain-language cause for the errnos this tool actually meets. The point is to
# turn "[Errno 1] Operation not permitted" into something an operator can act on
# without reproducing the failure by hand.
ERRNO_CAUSE = {
    errno.EPERM: "the operation itself is refused on this mount, even though the "
                 "permission bits may look fine -- CIFS/SMB commonly refuses "
                 "chmod, utime and chown; an immutable or append-only attribute "
                 "does the same",
    errno.EACCES: "the permission bits deny it, on the path or on one of its parents",
    errno.EROFS: "the filesystem is mounted read-only",
    errno.ENOSPC: "no space left on the destination filesystem",
    errno.EDQUOT: "the quota for this user on the destination is exhausted",
    errno.EXDEV: "source and destination are on different filesystems, so this "
                 "cannot be a rename",
    errno.ENOENT: "a component of the path does not exist",
    errno.ENOTDIR: "a component of the path is not a directory",
    errno.EISDIR: "the target is a directory",
    errno.EBUSY: "the file is in use",
    errno.ETXTBSY: "the file is being executed",
    errno.ESTALE: "a stale NFS handle: the share moved or was remounted underneath",
    errno.ENAMETOOLONG: "the path is too long for this filesystem",
    errno.EEXIST: "the target already exists and could not be replaced",
    errno.EIO: "an I/O error from the underlying device or share",
}


def _owner(uid, gid):
    try:
        import pwd
        user = pwd.getpwuid(uid).pw_name
    except Exception:
        user = str(uid)
    try:
        import grp
        group = grp.getgrgid(gid).gr_name
    except Exception:
        group = str(gid)
    return "%s:%s(%d:%d)" % (user, group, uid, gid)


def describe_path(path):
    """'mode=0644 owner=jerome:jerome(1001:1001)' for a path, or why not."""
    try:
        st = os.lstat(path)
    except OSError as exc:
        return "absent(%s)" % errno.errorcode.get(exc.errno, exc.errno)
    kind = "dir" if stat.S_ISDIR(st.st_mode) else (
        "link" if stat.S_ISLNK(st.st_mode) else "file")
    return "%s mode=%04o owner=%s" % (kind, stat.S_IMODE(st.st_mode),
                                      _owner(st.st_uid, st.st_gid))


def mount_info(path):
    """(fstype, options) of the filesystem holding `path`, from /proc/mounts.

    This is what shows a share mounted read-only, or a CIFS mount whose uid/gid
    mapping explains a refusal the permission bits alone do not.
    """
    try:
        with open("/proc/mounts", "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return "", ""
    target = os.path.abspath(path)
    best = ("", "", -1)
    for line in lines:
        parts = line.split()
        if len(parts) < 4:
            continue
        mnt = parts[1].replace("\\040", " ")
        if target == mnt or target.startswith(mnt.rstrip("/") + "/"):
            if len(mnt) > best[2]:
                best = (parts[2], parts[3], len(mnt))
    return best[0], best[1]


def diagnose(exc, op, path, other=None):
    """Everything known about a refused operation, as log fields.

    Answers "why could this not happen here?" without a second investigation:
    which call failed, on what, with which errno, what the path and its parent
    actually are, what kind of filesystem it sits on, and who we are.
    """
    code = getattr(exc, "errno", None)
    name = errno.errorcode.get(code, "?") if code is not None else "?"
    fstype, opts = mount_info(path)
    fields = {
        "op": op,
        "errno": "%s(%s)" % (name, code),
        "err": str(exc),
        "cause": ERRNO_CAUSE.get(code, "see the errno above"),
        "path": path,
        "path_is": describe_path(path),
        "parent_is": describe_path(os.path.dirname(path) or "."),
        "fs": fstype or "?",
        "fs_opts": opts or "?",
        "process_user": _owner(os.geteuid(), os.getegid()),
    }
    if other:
        fields["other"] = other
        ofs, oopts = mount_info(other)
        fields["other_fs"] = ofs or "?"
        if code == errno.EXDEV:
            fields["hint"] = ("these two paths are on different filesystems (%s vs "
                              "%s); a rename cannot cross that boundary"
                              % (ofs or "?", fstype or "?"))
    if code == errno.EPERM and "hint" not in fields:
        fields["hint"] = ("if the destination is a CIFS/SMB mount, metadata "
                          "preservation is the usual culprit; check the mount's "
                          "uid/gid/file_mode options, and lsattr on the path")
    elif code == errno.EACCES:
        fields["hint"] = ("the process user above needs write+execute on the parent "
                          "directory shown in parent_is")
    elif code == errno.EROFS:
        fields["hint"] = "remount the share read-write, or point DEPLOY_DIR elsewhere"
    return fields


def iso(epoch):
    """A report timestamp, in the same shape file-dispatch writes.

    Local, no offset: the two reports are meant to be read side by side, and a
    column that parses differently in one of them defeats that.
    """
    try:
        return datetime.fromtimestamp(float(epoch)).strftime("%Y-%m-%dT%H:%M:%S")
    except (ValueError, OSError, OverflowError):
        return ""


def now_precise():
    """Same, with milliseconds.

    Only for first_seen, which is half of a row's key: two deliveries of the
    same path within one second would otherwise collapse into one row.
    """
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]


# ==========================================================================
# The runner
# ==========================================================================
class Runner(object):
    def __init__(self, cfg, log, dry_run):
        self.cfg = cfg
        self.log = log
        self.dry = dry_run
        self.host = socket.gethostname()

        # Per-run outcome flags -> exit code
        self.source_ok = False
        self.deploy_failed = False
        self.source_stuck = False
        self.mount_state = None

        # Per-run counters
        self.n_scanned = self.n_deployed = self.n_overwritten = 0
        self.n_conflicts = self.n_moved = self.n_errors = 0

        # Reported-once-per-run sets, so a permanently broken file cannot emit
        # one warning per cycle for the life of the run.
        self._warned_files = set()
        self._warned_conflicts = set()

        self.deploy_checked = False
        self.deployed_marked = os.path.exists(
            os.path.join(cfg.STATE_DIR, "deployed"))
        self.dirlast = {}
        self.input_dirs = []
        self.deep_scan = False
        self.force_rediscover = False
        self._metadata_warned = False
        self._report = None
        self._report_seen = set()

        self.state = cfg.STATE_DIR
        self.archive_name = cfg.LOCAL_ARCHIVE_DIR
        self.excludes = [p.lower() for p in cfg.EXCLUDE_DIR_PATTERNS if p]

    # ---------------------------------------------------------------- report
    #
    # Same shape as file-dispatch, deliberately: report.state is the authority
    # and the CSV is *published* from it. A spreadsheet holding the CSV open on a
    # share blocks the rename that publishes it -- so publishing is allowed to
    # fail, while the state is not, and the next run simply publishes again.
    #
    # One row per file, opened the first time the file is seen and closed when it
    # is delivered, so a file that is stuck (unreadable, blocked by a conflict,
    # waiting to settle) is visible with its status and its retry count instead
    # of being absent from the dataset entirely.
    def report_load(self):
        """Read the state, keyed by (relpath, first_seen).

        Falls back to a published report when there is no state yet, so an
        existing report carries over the first time this runs.
        """
        self._report = {}
        self._report_seen = set()
        if not self.cfg.REPORT_DIR:
            return
        path = self._state_csv()
        if not os.path.exists(path):
            path = self._published_path(self._period_of({}))
        try:
            with open(path, "r", encoding="utf-8", newline="") as fh:
                for row in csv.DictReader(fh):
                    key = (row.get("relpath", ""), row.get("first_seen", ""))
                    if key[0]:
                        self._report[key] = dict(
                            (c, row.get(c, "") or "") for c in engine.REPORT_COLUMNS)
        except (OSError, csv.Error):
            self._report = {}   # unreadable or corrupt: start over, never lose the run

    def _state_csv(self):
        return os.path.join(self.cfg.REPORT_DIR, "report.state")

    def _period_of(self, row):
        """Which published file a row belongs to, from its first_seen.

        Partitioning, not snapshotting: a row lives in exactly one file, so the
        whole set read together is the report -- no duplicates to reconcile,
        which is what makes a Power BI folder import work with no extra step.
        """
        if self.cfg.REPORT_SPLIT == "monthly":
            return (row.get("first_seen") or "")[:7]
        if self.cfg.REPORT_SPLIT == "daily":
            return (row.get("first_seen") or "")[:10]
        return ""

    def _published_path(self, period):
        name = "report-%s.csv" % period if period else "report.csv"
        return os.path.join(self.cfg.REPORT_DIR, name)

    def report_note(self, relpath, status, **fields):
        """Record where `relpath` stands. Called once per file per cycle.

        Reuses the file's open row if it has one -- counting a retry, once per
        run -- and opens a new one otherwise. A delivery closes the row, so the
        next drop of the same name opens a fresh one and the history is kept.
        """
        if self._report is None or not self.cfg.REPORT_DIR or self.dry:
            return
        open_rows = [k for k, r in self._report.items()
                     if k[0] == relpath and r.get("status") != "success"]
        if open_rows:
            key = max(open_rows, key=lambda k: k[1])
            row = self._report[key]
            if key not in self._report_seen:
                row["retries"] = str(int(row.get("retries") or 0) + 1)
        else:
            key = (relpath, now_precise())
            row = dict.fromkeys(engine.REPORT_COLUMNS, "")
            row.update(relpath=relpath, filename=os.path.basename(relpath),
                       first_seen=key[1], retries="0",
                       instance=self.cfg.INSTANCE_ID, host=self.host)
            self._report[key] = row
        self._report_seen.add(key)
        row["status"] = status
        row["run_id"] = self.log.run_id
        for k, v in fields.items():
            if v not in (None, ""):
                row[k] = str(v)
        if status == "success":
            row["moved_at"] = iso(time.time())
        return key

    def report_save(self):
        """Write the state, then publish the CSV from it.

        Two steps on purpose. The state must be written -- losing it loses the
        retry counts and the first_seen of everything in flight -- while
        publishing is best effort.
        """
        if self._report is None or not self.cfg.REPORT_DIR or self.dry:
            return
        try:
            os.makedirs(self.cfg.REPORT_DIR, exist_ok=True)
        except OSError as exc:
            self.log("ERROR", "REPORT_DIR_UNUSABLE", dir=self.cfg.REPORT_DIR,
                     **diagnose(exc, "makedirs", self.cfg.REPORT_DIR))
            return

        rows = [r for k, r in self._report.items()
                if k in self._report_seen or self._keep(r)]
        rows.sort(key=lambda r: (r.get("first_seen", ""), r.get("relpath", "")))

        if not self._report_seen and len(rows) == len(self._report) \
                and not self._publish_lagging(rows):
            # Nothing observed, nothing aged out, and every published file is in
            # step with the state: a quiet cron would otherwise rewrite the whole
            # report every cycle, which on a network share is real traffic.
            return

        if not self._write_csv(self._state_csv(), rows, ","):
            return                      # nothing to publish from

        by_period = {}
        for row in rows:
            by_period.setdefault(self._period_of(row), []).append(row)
        touched = set(self._period_of(self._report[k]) for k in self._report_seen
                      if k in self._report)
        for period, part in sorted(by_period.items()):
            # Only rewrite a file this run actually changed, so a spreadsheet
            # open on last month's file never collides with this month's writes.
            if period and period not in touched \
                    and os.path.exists(self._published_path(period)):
                continue
            if not self._write_csv(self._published_path(period), part,
                                   self.cfg.REPORT_DELIMITER):
                self.log("WARN", "REPORT_NOT_PUBLISHED",
                         file=os.path.basename(self._published_path(period)),
                         state=self._state_csv(),
                         note="a program is probably holding it open; the state is "
                              "safe and it will be published on the next run")
        if self.cfg.REPORT_SPLIT != "none":
            self._prune_published(set(by_period))

    def _keep(self, row):
        """Keep a row not seen this run only while it is inside the retention."""
        if self.cfg.REPORT_KEEP_DAYS <= 0:
            return True
        stamp = row.get("moved_at") or row.get("first_seen") or ""
        try:
            age = datetime.now() - datetime.fromisoformat(stamp)
        except ValueError:
            return True                 # unparseable: keep rather than lose it
        return age.days < self.cfg.REPORT_KEEP_DAYS

    def _publish_lagging(self, rows):
        """True when a published file is missing, or older than the state.

        Without this the report would stay stale after a publish that failed,
        until the next file happened to arrive -- days, on a quiet weekend.
        """
        try:
            state_mtime = os.path.getmtime(self._state_csv())
        except OSError:
            return True
        for period in set(self._period_of(r) for r in rows):
            try:
                if os.path.getmtime(self._published_path(period)) < state_mtime:
                    return True
            except OSError:
                return True
        return False

    def _write_csv(self, path, rows, delimiter):
        """Write rows atomically. Returns False and logs the state's failures."""
        tmp = "%s.partial-%d" % (path, os.getpid())
        try:
            with open(tmp, "w", encoding="utf-8", newline="") as fh:
                w = csv.DictWriter(fh, fieldnames=list(engine.REPORT_COLUMNS),
                                   delimiter=delimiter)
                w.writeheader()
                w.writerows(rows)
            os.replace(tmp, path)       # readers never see a half-written file
            return True
        except (OSError, csv.Error) as exc:
            self._unlink(tmp)
            if path == self._state_csv():   # this one may not fail quietly
                self.log("ERROR", "REPORT_STATE_UNWRITABLE",
                         **diagnose(exc, "write", path))
            return False

    def _prune_published(self, keep):
        """A period emptied by retention leaves a file behind; drop it."""
        try:
            names = os.listdir(self.cfg.REPORT_DIR)
        except OSError:
            return
        for name in names:
            if not (name.startswith("report-") and name.endswith(".csv")):
                continue
            if name[len("report-"):-len(".csv")] in keep:
                continue
            self._unlink(os.path.join(self.cfg.REPORT_DIR, name))

    # ------------------------------------------------------- deployment root
    def check_deploy_root(self):
        """Refuse to write into a destination that is not really there.

        An unmounted deployment share is the worst failure mode: mkdir would
        happily populate the local mount point, every file would then be moved
        out of the source because of it, and on remount the tree would be empty
        and the sources gone. The sentinel tells the two apart.
        """
        dep = self.cfg.DEPLOY_DIR
        marker_name = self.cfg.DEPLOY_MARKER
        if not marker_name or self.deploy_checked:
            return True
        marker = os.path.join(dep, marker_name)
        if os.path.exists(marker):
            self.deploy_checked = True
            return True

        nonempty = False
        try:
            with os.scandir(dep) as it:
                nonempty = any(True for _ in it)
        except OSError:
            nonempty = False

        if self.deployed_marked and not nonempty:
            self.log("ERROR", "DEPLOY_UNAVAILABLE", dep=dep, marker=marker_name,
                     reason="marker missing and the deployment root is absent or "
                            "empty, although this configuration has deployed here before",
                     hint="the share looks unmounted -- nothing was written and "
                          "nothing was removed from the source. Mount it, or recreate "
                          "the marker if the tree really was emptied or moved.")
            return False

        if self.dry:
            self.log("INFO", "DEPLOY_MARKER_MISSING", dep=dep, dry="1")
            self.deploy_checked = True
            return True
        try:
            os.makedirs(dep, exist_ok=True)
            with open(marker, "a"):
                pass
        except OSError as exc:
            self.log("ERROR", "DEPLOY_UNAVAILABLE", dep=dep, marker=marker_name,
                     reason="cannot create the marker file at the deployment root",
                     err=str(exc),
                     hint="check that the deployment root exists and is writable")
            return False
        if self.deployed_marked:
            self.log("WARN", "DEPLOY_MARKER_ADOPTED", dep=dep, marker=marker_name,
                     hint="pre-existing tree adopted; the marker now guards it "
                          "against an unmounted share")
        else:
            self.log("INFO", "DEPLOY_MARKER_CREATED", dep=dep, marker=marker_name)
        self.deploy_checked = True
        return True

    # ------------------------------------------------------------- discovery
    def discovery_signature(self):
        """Everything that changes WHICH directories a walk would find.

        Stored in the cache so that editing any of it takes effect on the next
        cycle instead of up to DISCOVERY_INTERVAL later.
        """
        parts = ["maxdepth=%d" % self.cfg.DISCOVERY_MAXDEPTH]
        parts += ["n=" + engine.enc(n) for n in self.cfg.input_names()]
        parts += ["x=" + engine.enc(p) for p in self.cfg.EXCLUDE_DIR_PATTERNS]
        return "|".join(parts)

    def _excluded(self, name):
        low = name.lower()
        if self.archive_name and name == self.archive_name:
            return "archive"
        for pat in self.excludes:
            import fnmatch
            if fnmatch.fnmatch(low, pat):
                return "pattern"
        return None

    def walk_for_inputs(self):
        """Locate the input directories, pruning at every match.

        Never descends into a pickup tree, so the large subtrees are not walked.
        """
        names = set(self.cfg.input_names())
        maxdepth = self.cfg.DISCOVERY_MAXDEPTH
        root = self.cfg.SOURCE_DIR
        found = []
        stack = [(root, 0)]
        while stack:
            path, depth = stack.pop()
            try:
                entries = list(os.scandir(path))
            except OSError:
                continue
            for e in entries:
                try:
                    if not e.is_dir(follow_symlinks=False):
                        continue
                except OSError:
                    continue
                if self._excluded(e.name):
                    continue
                if e.name in names:
                    found.append(e.path)          # prune: do not descend
                    continue
                if maxdepth == 0 or depth + 1 < maxdepth:
                    stack.append((e.path, depth + 1))
        found.sort()
        return found

    def load_inputs(self):
        cache = os.path.join(self.state, "inputs.tsv")
        header = "#sig\t" + engine.enc(self.discovery_signature())
        need, reason = False, "cache-fresh"
        if not os.path.exists(cache):
            need, reason = True, "no-cache"
        else:
            first = ""
            try:
                with open(cache, "r", encoding="utf-8") as fh:
                    first = fh.readline().rstrip("\n")
            except OSError:
                first = ""
            if first != header:
                need, reason = True, "config-changed"
            else:
                age = time.time() - os.path.getmtime(cache)
                if self.cfg.DISCOVERY_INTERVAL and age >= self.cfg.DISCOVERY_INTERVAL:
                    need, reason = True, "cache-stale"
        if self.force_rediscover:
            need, reason = True, "forced"

        if not need:
            dirs = []
            try:
                with open(cache, "r", encoding="utf-8") as fh:
                    for n, line in enumerate(fh):
                        if n == 0:
                            continue
                        line = line.rstrip("\n")
                        if line:
                            dirs.append(engine.dec(line))
            except OSError:
                dirs = []
            self.input_dirs = dirs
            self.log("DEBUG", "DISCOVERY_CACHED", input_dirs=len(dirs))
            return

        t0 = time.time()
        self.input_dirs = self.walk_for_inputs()
        self.log("INFO", "DISCOVERY", input_dirs=len(self.input_dirs),
                 dur_s=round(time.time() - t0, 3), src=self.cfg.SOURCE_DIR,
                 input_dir_name=self.cfg.INPUT_DIR_NAME, reason=reason)
        if not self.input_dirs:
            self.log("WARN", "NO_INPUT_DIRS", src=self.cfg.SOURCE_DIR,
                     input_dir_name=self.cfg.INPUT_DIR_NAME,
                     hint="no directory with any of the configured names was found "
                          "under the source")
        if not self.dry:
            tmp = cache + ".tmp"
            try:
                with open(tmp, "w", encoding="utf-8") as fh:
                    fh.write(header + "\n")
                    for d in self.input_dirs:
                        fh.write(engine.enc(d) + "\n")
                os.replace(tmp, cache)
            except OSError:
                self.log("WARN", "CACHE_WRITE_FAILED", cache=cache)

    # ---------------------------------------------------------- leaves cache
    def load_leaves(self):
        """Settled directory mtimes, so an unchanged directory is not listed.

        Versioned: a cache written by an older format is discarded rather than
        misread, which is what stops an upgrade from skipping a whole backlog.
        """
        self.dirlast = {}
        path = os.path.join(self.state, "leaves.tsv")
        try:
            with open(path, "r", encoding="utf-8") as fh:
                for n, line in enumerate(fh):
                    line = line.rstrip("\n")
                    if n == 0:
                        if line != LEAVES_CACHE_VERSION:
                            return
                        continue
                    if not line:
                        continue
                    enc_leaf, _, mt = line.partition("\t")
                    self.dirlast[engine.dec(enc_leaf)] = mt
        except OSError:
            pass

    def save_leaves(self, seen):
        if self.dry:
            return
        path = os.path.join(self.state, "leaves.tsv")
        tmp = path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(LEAVES_CACHE_VERSION + "\n")
                for leaf in seen:
                    if leaf in self.dirlast:
                        fh.write("%s\t%s\n" % (engine.enc(leaf), self.dirlast[leaf]))
            os.replace(tmp, path)
        except OSError:
            self.log("WARN", "CACHE_WRITE_FAILED", cache=path)

    # ------------------------------------------------------- error reporting
    def file_error(self, key, event, **fields):
        """A per-file problem that may well be permanent.

        Logged at WARN once per run per (file, identity), but the directory is
        marked unsettled EVERY time: a file left behind is unfinished work, so
        the directory must never be recorded as done -- otherwise the mtime skip
        would stop looking at it.
        """
        self.n_errors += 1
        if key not in self._warned_files:
            self._warned_files.add(key)
            self.log("WARN", event, **fields)
        elif self.log.debug_on:
            self.log("DEBUG", event, repeat="1", **fields)
        return True   # caller sets unsettled

    # ------------------------------------------------------------ deployment
    def atomic_copy(self, src, dst, digest):
        """Copy to a hidden sibling temp, verify it, and only then rename it in.

        Four separate steps, reported separately, because they fail for very
        different reasons and only two of them are fatal:

          copy-data      the bytes. Fatal.
          copy-metadata  mode and timestamps. BEST EFFORT: a CIFS/SMB share
                         routinely refuses chmod/utime with EPERM while the data
                         copied perfectly, and refusing to deploy over that would
                         be refusing to work at all. Reported, never fatal.
          verify         re-hash what landed. Fatal.
          publish        rename into place. Fatal.

        Verifying before publishing is what guarantees a corrupt or short copy
        never becomes visible and never clobbers a file that was already correct.
        The temp is a sibling, so the rename is same-filesystem and atomic; it is
        dot-prefixed so a consumer globbing the tree cannot pick it up.

        Returns (stage, fields) on failure, (None, None) on success.
        """
        d = os.path.dirname(dst)
        tmp = os.path.join(d, ".%s%s.%d" % (os.path.basename(dst), TMP_SUFFIX,
                                            os.getpid()))
        try:
            shutil.copyfile(src, tmp)
        except OSError as exc:
            self._unlink(tmp)
            return "copy-data", diagnose(exc, "copyfile", tmp, other=src)

        # Mode and timestamps are a nicety, not the payload: the transaction is
        # about content. A CIFS/SMB share routinely refuses them with EPERM, and
        # failing the deployment over that would mean refusing to work at all.
        # Reported once per run, never fatal. PRESERVE_METADATA=no skips it.
        if self.cfg.PRESERVE_METADATA:
            try:
                shutil.copystat(src, tmp)
            except OSError as exc:
                if self.log.debug_on or not self._metadata_warned:
                    self._metadata_warned = True
                    self.log("WARN", "METADATA_NOT_PRESERVED",
                             note="the content is copied and verified; only mode and "
                                  "timestamps could not be carried over. Set "
                                  "PRESERVE_METADATA=no to stop trying.",
                             **diagnose(exc, "copystat", tmp, other=src))

        got = file_digest(tmp, self.cfg.HASH_ALGO)
        if got is None:
            self._unlink(tmp)
            return "verify", {"err": "the copy could not be hashed back",
                              "path": tmp}
        if got != digest:
            self._unlink(tmp)
            return "verify", {"err": "hash mismatch", "expected": digest[:16],
                              "actual": got[:16], "path": tmp}
        try:
            os.replace(tmp, dst)
        except OSError as exc:
            self._unlink(tmp)
            return "publish", diagnose(exc, "rename", dst, other=tmp)
        return None, None

    def _sweep_stale(self, directory, base):
        """Remove leftovers of a run that was killed mid-transaction.

        The only window the two-phase commit cannot close is between draining the
        source and dropping the stashed previous version: a crash there leaves a
        stash behind. It is harmless -- hidden, and the transaction did complete --
        but it would otherwise accumulate one per interruption.
        """
        for suffix in (TMP_SUFFIX, PREV_SUFFIX):
            prefix = ".%s%s." % (base, suffix)
            try:
                with os.scandir(directory) as it:
                    for e in it:
                        if e.name.startswith(prefix):
                            self._unlink(e.path)
                            if self.log.debug_on:
                                self.log("DEBUG", "STALE_SWEPT", path=e.path)
            except OSError:
                pass

    def _note_failure(self, relpath, outcome, reason, src, pickup, mtime, size,
                      digest=""):
        """One place for the failure rows, so they all carry the same fields."""
        self.report_note(relpath, engine.STATUS_FAILED, outcome=outcome,
                         reason=reason, file_date=iso(mtime), size_bytes=size,
                         hash=digest, pickup_dir=pickup, source_path=src)

    def _rollback(self, saved_prev, dpath, published, relpath):
        """Put the deployment tree back exactly as it was.

        Called whenever the transaction cannot be completed. It is what turns
        "deployed but not drained" from a lasting half-state into a cycle that
        simply did nothing, so the next attempt starts from a clean slate.
        """
        if not published and not saved_prev:
            return
        if published:
            self._unlink(dpath)
        if saved_prev:
            try:
                os.replace(saved_prev, dpath)
            except OSError as exc:
                # The one case we cannot undo: say so loudly rather than let it
                # pass as an ordinary failure.
                self.deploy_failed = True
                self.log("ERROR", "ROLLBACK_FAILED", relpath=relpath, dst=dpath,
                         stash=saved_prev,
                         note="the previously deployed version is in the stash file "
                              "named above and must be restored by hand",
                         **diagnose(exc, "rename", dpath, other=saved_prev))
                return
        if self.log.debug_on:
            self.log("DEBUG", "ROLLED_BACK", relpath=relpath, dst=dpath)

    @staticmethod
    def _unlink(path):
        try:
            os.remove(path)
        except OSError:
            pass

    def resolve_deploy(self, dst, digest, mtime):
        """(outcome, path, deployed_digest) for an incoming file.

        Read-only: the dry run calls exactly this, so a rehearsal reports the
        verdict the real run would apply.
        """
        deployed = file_digest(dst, self.cfg.HASH_ALGO) if os.path.isfile(dst) else None
        outcome = engine.conflict_verdict(deployed, digest, self.cfg.ON_CONFLICT)
        path = dst
        if outcome == engine.DEPLOYED_VERSION:
            d, base = os.path.dirname(dst), os.path.basename(dst)
            stamp = engine.stamp_from_epoch(mtime)
            for cand in engine.candidate_names(base, stamp, digest):
                p = os.path.join(d, cand)
                if not os.path.exists(p):
                    path = p
                    break
                if file_digest(p, self.cfg.HASH_ALGO) == digest:
                    # Already deployed under this very name by an earlier attempt.
                    return engine.DEPLOYED_IDENTICAL, p, deployed
            else:
                path = os.path.join(d, engine.candidate_names(base, stamp, digest)[-1])
        return outcome, path, deployed

    # ----------------------------------------------------------- the archive
    def archive_source(self, src, pickup, base, digest, mtime, relpath):
        """Take the file out of the pickup directory by RENAMING it.

        rename(2), not copy-then-delete, and that is the load-bearing decision:
        one atomic irreversible operation instead of two, the archived copy
        cannot be truncated (same inode), the state "archived but not deployed"
        cannot exist, and it costs no second full write over the network.

        The name is resolved by the same rule the deployment tree uses, so an
        identical file already there is reused instead of duplicated -- which is
        what makes a retry after a failure idempotent.
        """
        if not self.archive_name:
            try:
                os.remove(src)
                return ""
            except OSError as exc:
                self.source_stuck = True
                self.n_errors += 1
                self.log("ERROR", "SOURCE_STUCK", stage="source-unlink",
                         relpath=relpath, deployed="rolled-back", source_kept="yes",
                         **diagnose(exc, "unlink", src))
                return None
        adir = os.path.join(pickup, self.archive_name)
        try:
            os.makedirs(adir, exist_ok=True)
        except OSError as exc:
            self.source_stuck = True
            self.n_errors += 1
            self.log("ERROR", "ARCHIVE_DIR_FAILED", relpath=relpath,
                     **diagnose(exc, "makedirs", adir))
            return None

        stamp = engine.stamp_from_epoch(mtime)
        target = None
        for cand in engine.candidate_names(base, stamp, digest):
            p = os.path.join(adir, cand)
            if not os.path.exists(p):
                target = p
                break
            if file_digest(p, self.cfg.HASH_ALGO) == digest:
                target = p          # reuse: same name, same bytes
                if self.log.debug_on:
                    self.log("DEBUG", "ARCHIVE_REUSED", relpath=relpath, archive=p)
                break
        if target is None:
            target = os.path.join(adir, engine.candidate_names(base, stamp, digest)[-1])
        try:
            os.replace(src, target)
        except OSError as exc:
            self.source_stuck = True
            self.n_errors += 1
            self.log("ERROR", "SOURCE_STUCK", stage="archive-rename",
                     relpath=relpath, archive=target, deployed="rolled-back",
                     source_kept="yes",
                     note="the source could not be drained, so the deployment was "
                          "undone: neither tree changed. It will be retried.",
                     **diagnose(exc, "rename", target, other=src))
            return None
        return target

    # -------------------------------------------------------------- one file
    def process_file(self, src, pickup):
        """Returns True when the directory must be considered unsettled."""
        cfg = self.cfg
        relpath = os.path.relpath(src, cfg.SOURCE_DIR)
        st = stat_or_none(src)
        if st is None:
            self.log("WARN", "FILE_VANISHED", relpath=relpath)
            return False
        size, mtime = st.st_size, st.st_mtime
        self.n_scanned += 1

        age = time.time() - mtime
        if age < cfg.MIN_STABLE_AGE:
            if self.log.debug_on:
                self.log("DEBUG", "SKIP_UNSTABLE", relpath=relpath,
                         age_s=int(age), min_stable_age=cfg.MIN_STABLE_AGE)
            self.report_note(relpath, engine.STATUS_PENDING, outcome="SKIP_UNSTABLE",
                             reason="still being written", file_date=iso(mtime),
                             size_bytes=size, pickup_dir=pickup,
                             source_path=src)
            return True

        digest = file_digest(src, cfg.HASH_ALGO)
        if digest is None:
            self.report_note(relpath, engine.STATUS_FAILED, outcome="HASH_FAILED",
                             reason="unreadable", file_date=iso(mtime),
                             size_bytes=size, pickup_dir=pickup, source_path=src)
            return self.file_error("%s|%s|%s" % (relpath, size, mtime),
                                   "HASH_FAILED", relpath=relpath,
                                   hash_algo=cfg.HASH_ALGO)

        base = os.path.basename(src)
        dst = os.path.join(cfg.DEPLOY_DIR, relpath)
        saved_prev = None      # the overwritten version, kept until we commit
        published = False      # whether the new file is already visible in B
        archive_rel = (os.path.join(os.path.relpath(pickup, cfg.SOURCE_DIR),
                                    self.archive_name, base)
                       if self.archive_name else "")

        # Birth time, for the report only, read while the file is still here.
        btime = 0
        if cfg.REPORT_DIR:
            btime = getattr(st, "st_birthtime", 0) or 0

        if self.dry:
            outcome, path, _prev = self.resolve_deploy(dst, digest, mtime)
            self.log("INFO", "WOULD_MOVE", relpath=relpath, size=size,
                     deploy=outcome, on_conflict=cfg.ON_CONFLICT,
                     deployed=("" if path == dst else os.path.relpath(path, cfg.DEPLOY_DIR)),
                     archive=archive_rel, hash=digest[:8] + "…", dry="1")
            self.n_deployed += 1
            return True     # a rehearsal must never settle a directory

        # --- 3. deploy -----------------------------------------------------
        try:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
        except OSError as exc:
            self.n_errors += 1
            self.deploy_failed = True
            self.log("ERROR", "DEPLOY_FAILED", stage="mkdir", relpath=relpath,
                     **diagnose(exc, "makedirs", os.path.dirname(dst)))
            self._note_failure(relpath, "DEPLOY_FAILED", "cannot create the "
                               "destination directory", src, pickup, mtime, size, digest)
            return True

        outcome, dpath, prev = self.resolve_deploy(dst, digest, mtime)

        if outcome == engine.DEPLOY_CONFLICT:
            self.n_conflicts += 1
            self.n_errors += 1
            self.deploy_failed = True
            self.log("ERROR", "DEPLOY_CONFLICT", relpath=relpath, dst=dst,
                     deployed_hash=(prev or "")[:8] + "…", incoming_hash=digest[:8] + "…",
                     on_conflict=cfg.ON_CONFLICT,
                     hint="the source file was kept; resolve the collision or "
                          "change ON_CONFLICT")
            self._note_failure(relpath, "DEPLOY_CONFLICT", "the destination holds "
                               "different content", src, pickup, mtime, size, digest)
            return True

        if outcome == engine.DEPLOY_RETRY:
            # Neither side is touched and the source file stays put, so this is a
            # pending state, not a failure: it clears by itself as soon as the
            # deployed file changes or is consumed.
            self.n_conflicts += 1
            if relpath not in self._warned_conflicts:
                self._warned_conflicts.add(relpath)
                self.log("WARN", "DEPLOY_RETRY", relpath=relpath, dst=dst,
                         deployed_hash=(prev or "")[:8] + "…",
                         incoming_hash=digest[:8] + "…", on_conflict=cfg.ON_CONFLICT,
                         hint="both sides left untouched; the source file is kept "
                              "and retried every cycle")
            elif self.log.debug_on:
                self.log("DEBUG", "DEPLOY_RETRY", relpath=relpath, repeat="1")
            self.report_note(relpath, engine.STATUS_PENDING, outcome="DEPLOY_RETRY",
                             reason="waiting for the destination to clear",
                             file_date=iso(mtime), size_bytes=size, hash=digest,
                             pickup_dir=pickup, source_path=src, destination=dst)
            return True

        if outcome == engine.DEPLOY_SKIPPED:
            self.n_conflicts += 1
            self.log("WARN", "DEPLOY_SKIPPED", relpath=relpath, dst=dst,
                     deployed_hash=(prev or "")[:8] + "…",
                     incoming_hash=digest[:8] + "…", on_conflict=cfg.ON_CONFLICT,
                     hint="the deployment tree was left untouched; the incoming "
                          "file is archived and drained")
        elif outcome != engine.DEPLOYED_IDENTICAL:
            # Two-phase commit. An overwrite destroys what is already deployed, so
            # move it aside first: until the whole transaction succeeds it can be
            # put back, and the cycle then leaves BOTH trees exactly as it found
            # them. Nothing here can produce "the log says it failed but the file
            # went through anyway".
            if outcome == engine.DEPLOYED_OVERWRITE:
                ddir, dbase = os.path.dirname(dpath), os.path.basename(dpath)
                # Dot-prefixed so a consumer globbing the tree cannot see it, and
                # any stash left by a run that was killed is swept first.
                self._sweep_stale(ddir, dbase)
                saved_prev = os.path.join(ddir, ".%s%s.%d"
                                          % (dbase, PREV_SUFFIX, os.getpid()))
                try:
                    os.replace(dpath, saved_prev)
                except OSError as exc:
                    self.n_errors += 1
                    self.deploy_failed = True
                    self.log("ERROR", "DEPLOY_FAILED", stage="stash-previous",
                             relpath=relpath, dst=dpath,
                             **diagnose(exc, "rename", dpath))
                    self._note_failure(relpath, "DEPLOY_FAILED", "cannot stash the "
                                       "version being replaced", src, pickup, mtime,
                                       size, digest)
                    return True
            stage, detail = self.atomic_copy(src, dpath, digest)
            if stage:
                self._rollback(saved_prev, dpath, False, relpath)
                self.n_errors += 1
                self.deploy_failed = True
                self.log("ERROR", "DEPLOY_FAILED", stage=stage, relpath=relpath,
                         dst=dpath, deployed="no", source_kept="yes", **detail)
                self._note_failure(relpath, "DEPLOY_FAILED", detail.get("cause")
                                   or detail.get("err") or stage, src, pickup,
                                   mtime, size, digest)
                return True
            published = True
            if outcome == engine.DEPLOYED_VERSION:
                self.n_conflicts += 1

        # --- 4. the source must not have moved under us --------------------
        st2 = stat_or_none(src)
        if st2 is None:
            self._rollback(saved_prev, dpath, published, relpath)
            self.log("WARN", "FILE_VANISHED", relpath=relpath, stage="post-deploy")
            return False
        if (st2.st_size, st2.st_mtime) != (size, mtime):
            # What we just published is a snapshot of a half-written file. Undo it
            # rather than leave a truncated version in the deployment tree.
            self._rollback(saved_prev, dpath, published, relpath)
            self.log("WARN", "SOURCE_CHANGED_DURING_COPY", relpath=relpath,
                     before="%s/%s" % (size, mtime),
                     after="%s/%s" % (st2.st_size, st2.st_mtime),
                     deployed="no", source_kept="yes",
                     hint="the file was still being written; the deployment was "
                          "rolled back and the source left alone, to be retried")
            self.report_note(relpath, engine.STATUS_PENDING,
                             outcome="SOURCE_CHANGED_DURING_COPY",
                             reason="rewritten while being copied",
                             file_date=iso(mtime), size_bytes=size,
                             pickup_dir=pickup, source_path=src)
            return True

        # --- 5. commit -----------------------------------------------------
        archive_path = self.archive_source(src, pickup, base, digest, mtime, relpath)
        if archive_path is None:
            # The source could not be drained, so the whole cycle is undone: the
            # deployment tree goes back to exactly what it was.
            self._rollback(saved_prev, dpath, published, relpath)
            self._note_failure(relpath, "SOURCE_STUCK", "deployed but the source "
                               "could not be drained; rolled back", src, pickup,
                               mtime, size, digest)
            return True
        # Past this point the transaction is committed on both sides. Dropping the
        # stashed previous version is the only thing left, and losing that to a
        # crash costs nothing but a stale file the next run sweeps away.
        if saved_prev:
            self._unlink(saved_prev)
            saved_prev = None
        self.n_moved += 1

        if not self.deployed_marked:
            self.deployed_marked = True
            try:
                with open(os.path.join(self.state, "deployed"), "a"):
                    pass
            except OSError:
                pass

        arch_rel = (os.path.relpath(archive_path, cfg.SOURCE_DIR)
                    if archive_path else "")
        dep_rel = "" if dpath == dst else os.path.relpath(dpath, cfg.DEPLOY_DIR)
        self.log.audit(outcome, relpath, arch_rel, digest, size, prev or "")
        if outcome == engine.DEPLOYED_OVERWRITE:
            self.log("INFO", outcome, relpath=relpath, size=size,
                     new_hash=digest[:8] + "…", old_hash=(prev or "")[:8] + "…",
                     archive=arch_rel)
            self.n_overwritten += 1
        elif outcome == engine.DEPLOYED_VERSION:
            self.log("INFO", outcome, relpath=relpath, size=size,
                     hash=digest[:8] + "…", deployed=dep_rel,
                     kept_hash=(prev or "")[:8] + "…", archive=arch_rel)
            self.n_deployed += 1
        elif outcome == engine.DEPLOY_SKIPPED:
            pass          # already reported at WARN above
        else:
            self.log("INFO", outcome, relpath=relpath, size=size,
                     hash=digest[:8] + "…", archive=arch_rel)
            self.n_deployed += 1
        self.report_note(relpath, engine.STATUS_SUCCESS, outcome=outcome,
                         reason="", file_date=iso(mtime),
                         destination=("" if outcome == engine.DEPLOY_SKIPPED else dpath),
                         source_path=src, archive_path=archive_path or "",
                         pickup_dir=pickup, size_bytes=size, hash=digest,
                         prev_hash=prev or "",
                         source_created=iso(btime) if btime else "",
                         age_at_pickup_s=int(age))
        return False

    # --------------------------------------------------------- one directory
    def scan_dir(self, leaf, mtime, root_dir, seen):
        """One pickup directory: guards, the mtime skip, then its direct files."""
        name = os.path.basename(leaf)
        if leaf != root_dir:
            why = self._excluded(name)
            if why == "archive":
                if self.log.debug_on:
                    self.log("DEBUG", "LOCAL_ARCHIVE_SKIPPED",
                             dir=os.path.relpath(leaf, self.cfg.SOURCE_DIR))
                return
            if why:
                if self.log.debug_on:
                    self.log("DEBUG", "EXCLUDED_DIR",
                             dir=os.path.relpath(leaf, self.cfg.SOURCE_DIR))
                return
        seen.add(leaf)
        # Files are MOVED out, so reading is not enough: unlinking needs w+x on
        # the parent. Deploying out of a directory we cannot then clean would
        # re-deploy the same files on every cycle, forever.
        if not (os.access(leaf, os.W_OK) and os.access(leaf, os.X_OK)):
            self.source_stuck = True
            self.file_error(leaf, "SOURCE_NOT_WRITABLE",
                            dir=os.path.relpath(leaf, self.cfg.SOURCE_DIR),
                            hint="files are moved out of the source: the pickup "
                                 "directory needs w+x")
            return
        if (self.cfg.USE_DIR_MTIME_SKIP and not self.deep_scan
                and self.dirlast.get(leaf) == repr(mtime)):
            if self.log.debug_on:
                self.log("DEBUG", "SKIP_DIR_UNCHANGED",
                         dir=os.path.relpath(leaf, self.cfg.SOURCE_DIR))
            return
        unsettled = False
        try:
            entries = list(os.scandir(leaf))
        except OSError:
            return
        for e in entries:
            try:
                if not e.is_file(follow_symlinks=False):
                    continue
            except OSError:
                continue
            if self.process_file(e.path, leaf):
                unsettled = True
        if not unsettled:
            self.dirlast[leaf] = repr(mtime)

    # -------------------------------------------------------------- one pass
    def cycle(self):
        cfg = self.cfg
        reason = source_reason(cfg.SOURCE_DIR)
        if reason:
            level = "DEBUG" if self.mount_state == "missing" else "ERROR"
            self.mount_state = "missing"
            self.log(level, "MOUNT_MISSING", src=cfg.SOURCE_DIR, reason=reason,
                     deepest_existing=deepest_existing(cfg.SOURCE_DIR))
            return
        if self.mount_state == "missing":
            self.log("INFO", "MOUNT_OK", src=cfg.SOURCE_DIR)
        self.mount_state = "ok"
        self.source_ok = True

        if not self.check_deploy_root():
            self.n_errors += 1
            self.deploy_failed = True
            return

        # Periodic deep pass: belt and braces against a share that fails to
        # update a directory's mtime when a file is added.
        deep_marker = os.path.join(self.state, "deepscan")
        self.deep_scan = False
        if self.force_rediscover:
            self.deep_scan = True
        elif cfg.DEEP_SCAN_INTERVAL > 0:
            try:
                last = os.path.getmtime(deep_marker)
            except OSError:
                last = 0
            if time.time() - last >= cfg.DEEP_SCAN_INTERVAL:
                self.deep_scan = True
        if self.deep_scan:
            if not self.dry:
                try:
                    with open(deep_marker, "a"):
                        pass
                    os.utime(deep_marker, None)
                except OSError:
                    pass
            if self.log.debug_on:
                self.log("DEBUG", "DEEP_SCAN", interval_s=cfg.DEEP_SCAN_INTERVAL)

        self.load_leaves()
        self.load_inputs()

        seen = set()
        t0 = time.time()
        before = (self.n_deployed, self.n_moved, self.n_errors)
        for inp in self.input_dirs:
            st = stat_or_none(inp)
            if st is None:
                continue
            self.scan_dir(inp, st.st_mtime, inp, seen)
            # ...and its direct subdirectories, never deeper.
            try:
                subs = list(os.scandir(inp))
            except OSError:
                continue
            for e in subs:
                try:
                    if e.is_dir(follow_symlinks=False):
                        self.scan_dir(e.path, e.stat().st_mtime, inp, seen)
                except OSError:
                    continue
        self.save_leaves(seen)
        if self.log.debug_on:
            self.log("DEBUG", "CYCLE_SUMMARY", dirs=len(seen),
                     deployed=self.n_deployed - before[0],
                     moved=self.n_moved - before[1],
                     errors=self.n_errors - before[2],
                     dur_ms=int((time.time() - t0) * 1000))


# ==========================================================================
# CLI
# ==========================================================================
def build_parser():
    p = argparse.ArgumentParser(
        prog="file-deploy",
        description="Move files from 'input' directories under SOURCE_DIR into a "
                    "mirror deployment tree at DEPLOY_DIR, keeping a local archive "
                    "copy behind in the source. One configuration file describes "
                    "one such pair. WARNING: this tool DELETES from the source; "
                    "rehearse with --dry-run first.")
    p.add_argument("--config", "-c", default=None, metavar="FILE",
                   help="configuration file (default: <script dir>/file-deploy.conf)")
    p.add_argument("--dry-run", "-n", action="store_true",
                   help="rehearse: log a WOULD_MOVE line per file with the "
                        "deployment verdict, without writing or deleting anything")
    p.add_argument("--once", action="store_true",
                   help="do a single pass and exit, instead of the timed loop")
    p.add_argument("--check", action="store_true",
                   help="validate the configuration and exit; nothing is scanned")
    p.add_argument("--rediscover", action="store_true",
                   help="drop a marker so the running loop re-walks the source on "
                        "its next cycle, then exit")
    p.add_argument("--debug", action="store_true",
                   help="maximum verbosity, mirrored to the terminal")
    p.add_argument("--verbose", "-v", action="store_true",
                   help="mirror log lines to the terminal without changing the level")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    config_path = args.config or os.path.join(script_dir, "file-deploy.conf")

    cfg = engine.Config().parse(config_path)
    # CLI wins over the file, and is applied after it so a flag can never be
    # overridden by the configuration.
    if args.dry_run:
        cfg.values["DRY_RUN"] = True
    if args.once:
        cfg.values["RUN_DURATION"] = 0
    if args.debug:
        cfg.values["LOG_LEVEL"] = "DEBUG"
        cfg.values["LOG_CONSOLE"] = "always"
    if args.verbose:
        cfg.values["LOG_CONSOLE"] = "always"
    cfg.validate(config_path=config_path, script_dir=script_dir)

    if cfg.errors:
        for e in cfg.errors:
            sys.stderr.write("config: %s\n" % e)
        return EX_CONFIG
    if args.check:
        for w in cfg.warnings:
            sys.stderr.write("warning: %s\n" % w)
        rows = cfg.effective()
        missing = [n for n, _v, seen in rows if not seen]
        sys.stdout.write("configuration OK: %s\n" % config_path)
        if not cfg.found:
            sys.stdout.write("  (file not found -- every value below is a default)\n")
        sys.stdout.write("  %d of %d settings come from the file, %d use their default\n\n"
                         % (len(rows) - len(missing), len(rows), len(missing)))
        # Every setting, so a value that is merely absent is as visible as a
        # wrong one. "default" is not a problem in itself -- it is the answer to
        # "is this setting missing from my file?".
        for name, value, seen in rows:
            sys.stdout.write("  %-22s %-34s %s\n"
                             % (name, value, "" if seen else "(default)"))
        if missing:
            sys.stdout.write("\n  using defaults: %s\n" % ", ".join(missing))
        return EX_OK

    for d in (cfg.STATE_DIR, cfg.LOG_DIR):
        try:
            os.makedirs(d, exist_ok=True)
        except OSError as exc:
            sys.stderr.write("cannot create %s: %s\n" % (d, exc))
            return EX_CONFIG

    console = (cfg.LOG_CONSOLE == "always" or
               (cfg.LOG_CONSOLE == "auto" and sys.stderr.isatty()))
    run_id = "%s-%d" % (time.strftime("%Y%m%d_%H%M%S"), os.getpid())
    log = Log(cfg, run_id, console)

    marker = os.path.join(cfg.STATE_DIR, ".force-rediscover")
    if args.rediscover:
        try:
            with open(marker, "a"):
                pass
        except OSError as exc:
            sys.stderr.write("cannot create marker file: %s\n" % exc)
            return EX_CONFIG
        log("INFO", "FORCE_REDISCOVER_REQUESTED", marker=marker)
        sys.stdout.write("Rediscovery requested; it will be applied on the next "
                         "scan cycle.\n")
        return EX_OK

    # Single-instance lock. The default lock path carries INSTANCE_ID, so two
    # configurations run concurrently instead of silently serialising.
    try:
        lock_fh = open(cfg.LOCK_FILE, "a+")
    except OSError as exc:
        sys.stderr.write("cannot open lock file %s: %s\n" % (cfg.LOCK_FILE, exc))
        return EX_CONFIG
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        # Expected on every cron tick while the loop is already running.
        log("DEBUG", "LOCK_BUSY", lock=cfg.LOCK_FILE)
        return EX_LOCKED

    # A state directory belongs to exactly one instance. The default paths make a
    # clash impossible, but STATE_DIR can be overridden -- and two configurations
    # sharing one would mix their caches and their "deployed here before" marker.
    owner_file = os.path.join(cfg.STATE_DIR, ".instance")
    owner = ""
    try:
        with open(owner_file, "r", encoding="utf-8") as fh:
            owner = fh.readline().strip()
    except OSError:
        owner = ""
    if owner and owner != cfg.INSTANCE_ID:
        log("ERROR", "STATE_DIR_CONFLICT", state_dir=cfg.STATE_DIR, owner=owner,
            instance=cfg.INSTANCE_ID,
            hint="this state directory belongs to another configuration; give each "
                 "one its own INSTANCE_ID or its own STATE_DIR")
        return EX_CONFIG
    if not owner:
        try:
            with open(owner_file, "w", encoding="utf-8") as fh:
                fh.write(cfg.INSTANCE_ID + "\n")
        except OSError:
            pass

    log("INFO", "START", pid=os.getpid(), host=socket.gethostname(),
        python=".".join(str(x) for x in sys.version_info[:3]))
    log("INFO", "PATHS", config=config_path,
        config_found=("yes" if cfg.found else "no"), state_dir=cfg.STATE_DIR,
        log_dir=cfg.LOG_DIR, lock=cfg.LOCK_FILE)
    log("INFO", "CONFIG", source_dir=cfg.SOURCE_DIR, deploy_dir=cfg.DEPLOY_DIR,
        input_dir_name=cfg.INPUT_DIR_NAME, scan_interval=cfg.SCAN_INTERVAL,
        run_duration=cfg.RUN_DURATION, min_stable_age=cfg.MIN_STABLE_AGE,
        on_conflict=cfg.ON_CONFLICT, local_archive_dir=cfg.LOCAL_ARCHIVE_DIR,
        deploy_marker=cfg.DEPLOY_MARKER, hash_algo=cfg.HASH_ALGO,
        dry_run=("yes" if cfg.DRY_RUN else "no"), report_dir=cfg.REPORT_DIR,
        discovery_interval=cfg.DISCOVERY_INTERVAL,
        deep_scan_interval=cfg.DEEP_SCAN_INTERVAL,
        exclude_patterns=",".join(cfg.EXCLUDE_DIR_PATTERNS),
        log_level=cfg.LOG_LEVEL, log_format=cfg.LOG_FORMAT)
    if not cfg.found:
        log("WARN", "CONFIG_NOT_FOUND", config=config_path,
            hint="config file not found; running with built-in defaults")
    for w in cfg.warnings:
        log("WARN", "CONFIG_WARNING", detail=w)
    if cfg.DRY_RUN:
        # A rehearsal left switched on looks exactly like a healthy run that
        # never delivers anything, so say it loudly enough to show in monitoring.
        log("WARN", "DRY_RUN_ACTIVE",
            source="--dry-run" if args.dry_run else "config",
            hint="nothing will be written or deleted; unset DRY_RUN to deliver")

    if cfg.REPORT_DIR:
        try:
            os.makedirs(cfg.REPORT_DIR, exist_ok=True)
        except OSError as exc:
            log("ERROR", "REPORT_DIR_UNUSABLE", dir=cfg.REPORT_DIR, err=str(exc),
                hint="cannot create the CSV report directory; reporting is "
                     "disabled for this run")
            cfg.values["REPORT_DIR"] = ""

    runner = Runner(cfg, log, cfg.DRY_RUN)
    runner.report_load()
    started = time.time()
    cycle = 0
    last_hb = 0.0
    while True:
        cycle += 1
        log.cycle = cycle
        if os.path.exists(marker):
            runner.force_rediscover = True
            try:
                os.remove(marker)
            except OSError:
                pass
            log("INFO", "FORCE_REDISCOVER", cycle=cycle)
        else:
            runner.force_rediscover = False
        runner.cycle()
        now = time.time()
        if cfg.HEARTBEAT_INTERVAL > 0 and now - last_hb >= cfg.HEARTBEAT_INTERVAL:
            last_hb = now
            log("INFO", "HEARTBEAT", cycle=cycle, elapsed_s=int(now - started),
                moved=runner.n_moved, errors=runner.n_errors,
                mount=runner.mount_state or "unknown")
        if now - started >= cfg.RUN_DURATION:
            break
        time.sleep(max(1, cfg.SCAN_INTERVAL))
    log.cycle = None
    runner.report_save()

    log("INFO", "RUN_SUMMARY", cycles=cycle, scanned=runner.n_scanned,
        deployed=runner.n_deployed, overwritten=runner.n_overwritten,
        conflicts=runner.n_conflicts, moved=runner.n_moved,
        errors=runner.n_errors, mount=runner.mount_state or "unknown")
    log("INFO", "END")

    # Undelivered data outranks delivered-but-not-drained.
    if not runner.source_ok:
        return EX_NOSOURCE
    if runner.deploy_failed:
        return EX_DEPLOY
    if runner.source_stuck:
        return EX_SOURCE
    return EX_OK


def _guarded():
    """Never let an unexpected exception reach cron as a bare traceback.

    A stack trace on stderr becomes an unreadable mail and is lost from the log
    that everything else is in. Record it where the rest of the run is, then
    exit with the configuration code so the failure is still loud.
    """
    try:
        return main()
    except KeyboardInterrupt:
        return EX_OK
    except Exception:
        import traceback
        detail = traceback.format_exc()
        sys.stderr.write(detail)
        for path in (_LAST_LOG[0],):
            if not path:
                continue
            try:
                with open(path, "a", encoding="utf-8") as fh:
                    fh.write("%s ERROR event=UNEXPECTED_ERROR detail=\"%s\"\n"
                             % (datetime.now().astimezone().strftime(
                                 "%Y-%m-%dT%H:%M:%S%z"), engine.enc(detail)))
            except OSError:
                pass
        return EX_CONFIG


if __name__ == "__main__":
    sys.exit(_guarded())
