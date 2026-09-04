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
TMP_SUFFIX = ".file-deploy-tmp"


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


def iso(epoch):
    try:
        return datetime.fromtimestamp(float(epoch)).astimezone().strftime(
            "%Y-%m-%dT%H:%M:%S%z")
    except (ValueError, OSError, OverflowError):
        return ""


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
        self._report_started = set()

        self.state = cfg.STATE_DIR
        self.archive_name = cfg.LOCAL_ARCHIVE_DIR
        self.excludes = [p.lower() for p in cfg.EXCLUDE_DIR_PATTERNS if p]

    # ---------------------------------------------------------------- report
    def report(self, outcome, src_path, deploy_path, archive_path, relpath,
               size, digest, prev_hash, mtime, btime, age, pickup_dir):
        if not self.cfg.REPORT_DIR or self.dry:
            return
        day = datetime.now().strftime("%Y-%m-%d")
        path = os.path.join(self.cfg.REPORT_DIR, "file-deploy-%s.csv" % day)
        delim = self.cfg.REPORT_DELIMITER
        try:
            if path not in self._report_started:
                self._report_started.add(path)
                os.makedirs(self.cfg.REPORT_DIR, exist_ok=True)
                if not os.path.exists(path) or os.path.getsize(path) == 0:
                    with open(path, "a", encoding="utf-8") as fh:
                        fh.write(engine.csv_header(delim) + "\n")
            row = {
                "run_id": self.log.run_id,
                "deployed_at": iso(time.time()),
                "instance": self.cfg.INSTANCE_ID,
                "outcome": outcome,
                "file_name": os.path.basename(src_path),
                "relpath": relpath,
                "source_path": src_path,
                "deploy_path": deploy_path or "",
                "archive_path": archive_path or "",
                "size_bytes": size,
                "hash": digest,
                "prev_hash": prev_hash or "",
                "source_modified": iso(mtime),
                "source_created": iso(btime) if btime else "",
                "age_at_pickup_s": age,
                "pickup_dir": pickup_dir,
                "host": self.host,
            }
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(engine.csv_row(row, delim) + "\n")
        except OSError:
            pass

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
        """Copy to a hidden sibling temp, verify it, and only then rename in.

        Verifying before the rename is what guarantees a corrupt or short copy
        never becomes visible at the destination and never clobbers a file that
        was already correct. The temp is a sibling, so the rename is
        same-filesystem and therefore atomic; it is dot-prefixed so a downstream
        consumer globbing the tree cannot pick it up.
        """
        d = os.path.dirname(dst)
        tmp = os.path.join(d, ".%s%s.%d" % (os.path.basename(dst), TMP_SUFFIX,
                                            os.getpid()))
        try:
            shutil.copy2(src, tmp)
        except OSError as exc:
            self._unlink(tmp)
            return "copy", str(exc)
        got = file_digest(tmp, self.cfg.HASH_ALGO)
        if got is None:
            self._unlink(tmp)
            return "verify", "the copy could not be hashed back"
        if got != digest:
            self._unlink(tmp)
            return "verify", "hash mismatch: expected %s got %s" % (digest[:12], got[:12])
        try:
            os.replace(tmp, dst)
        except OSError as exc:
            self._unlink(tmp)
            return "rename", str(exc)
        return None, None

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
                self.log("ERROR", "SOURCE_STUCK", relpath=relpath, err=str(exc),
                         hint="the file is deployed but could not be removed; "
                              "it will be retried")
                return None
        adir = os.path.join(pickup, self.archive_name)
        try:
            os.makedirs(adir, exist_ok=True)
        except OSError as exc:
            self.source_stuck = True
            self.n_errors += 1
            self.log("ERROR", "ARCHIVE_DIR_FAILED", relpath=relpath, dir=adir,
                     err=str(exc))
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
            self.log("ERROR", "SOURCE_STUCK", relpath=relpath, archive=target,
                     err=str(exc),
                     hint="the file is deployed but could not be moved out of the "
                          "pickup directory; it will be retried")
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
            return True

        digest = file_digest(src, cfg.HASH_ALGO)
        if digest is None:
            return self.file_error("%s|%s|%s" % (relpath, size, mtime),
                                   "HASH_FAILED", relpath=relpath,
                                   hash_algo=cfg.HASH_ALGO)

        base = os.path.basename(src)
        dst = os.path.join(cfg.DEPLOY_DIR, relpath)
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
                     dst_dir=os.path.dirname(dst), err=str(exc))
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
            return True

        if outcome == engine.DEPLOY_SKIPPED:
            self.n_conflicts += 1
            self.log("WARN", "DEPLOY_SKIPPED", relpath=relpath, dst=dst,
                     deployed_hash=(prev or "")[:8] + "…",
                     incoming_hash=digest[:8] + "…", on_conflict=cfg.ON_CONFLICT,
                     hint="the deployment tree was left untouched; the incoming "
                          "file is archived and drained")
        elif outcome != engine.DEPLOYED_IDENTICAL:
            stage, err = self.atomic_copy(src, dpath, digest)
            if stage:
                self.n_errors += 1
                self.deploy_failed = True
                self.log("ERROR", "DEPLOY_FAILED", stage=stage, relpath=relpath,
                         dst=dpath, err=err)
                return True
            if outcome == engine.DEPLOYED_VERSION:
                self.n_conflicts += 1

        # --- 4. the source must not have moved under us --------------------
        st2 = stat_or_none(src)
        if st2 is None:
            self.log("WARN", "FILE_VANISHED", relpath=relpath, stage="post-deploy")
            return False
        if (st2.st_size, st2.st_mtime) != (size, mtime):
            self.log("WARN", "SOURCE_CHANGED_DURING_COPY", relpath=relpath,
                     before="%s/%s" % (size, mtime),
                     after="%s/%s" % (st2.st_size, st2.st_mtime),
                     hint="the file was still being written; it was NOT moved and "
                          "will be retried")
            return True

        # --- 5. commit -----------------------------------------------------
        archive_path = self.archive_source(src, pickup, base, digest, mtime, relpath)
        if archive_path is None:
            return True
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
        self.report(outcome, src, ("" if outcome == engine.DEPLOY_SKIPPED else dpath),
                    archive_path or "", relpath, size, digest, prev or "",
                    mtime, btime, int(age), pickup)
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
        sys.stdout.write("configuration OK: %s\n" % config_path)
        sys.stdout.write("  instance   %s\n" % cfg.INSTANCE_ID)
        sys.stdout.write("  source     %s\n" % cfg.SOURCE_DIR)
        sys.stdout.write("  deploy     %s\n" % cfg.DEPLOY_DIR)
        sys.stdout.write("  state      %s\n" % cfg.STATE_DIR)
        sys.stdout.write("  logs       %s\n" % cfg.LOG_DIR)
        sys.stdout.write("  lock       %s\n" % cfg.LOCK_FILE)
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


if __name__ == "__main__":
    sys.exit(main())
