#!/usr/bin/env python3
"""
file-deploy engine: the pure core (a library, no side effects on the tree).

deploy.py (the orchestrator) imports this module. Everything that can be decided
without touching the filesystem lives here, where it is easy to read and to
unit-test (see tests/test_engine.py):

  - Config.parse / .validate      the KEY = value configuration file
  - conflict_verdict()            what to do about an existing destination
  - candidate_names()             the naming rule shared by the deployment tree
                                  and the local archive
  - enc() / esc_glob()            the small encoders the logs use
  - REPORT_COLUMNS               the report schema, shared with file-dispatch

The one rule that shapes this file: a decision that must survive a crash cannot
depend on the wall clock or on anything the previous run happened to remember.
So candidate_names() is a pure function of (name, source mtime, content hash),
and conflict_verdict() is a pure function of the two digests plus the policy.
That is what makes every retry land on exactly the same path.

Standard library only. Requires Python 3.9 or newer.
"""

import os
import re
import time

# --------------------------------------------------------------------------
# Outcomes. These names are also the event names in the log and the values of
# the CSV report's `outcome` column, so they are part of the interface.
# --------------------------------------------------------------------------
DEPLOYED = "DEPLOYED"
DEPLOYED_IDENTICAL = "DEPLOYED_IDENTICAL"
DEPLOYED_OVERWRITE = "DEPLOYED_OVERWRITE"
DEPLOYED_VERSION = "DEPLOYED_VERSION"
DEPLOY_SKIPPED = "DEPLOY_SKIPPED"
DEPLOY_RETRY = "DEPLOY_RETRY"
DEPLOY_CONFLICT = "DEPLOY_CONFLICT"

CONFLICT_POLICIES = ("overwrite", "version", "skip", "retry", "fail")

IDENT_RE = re.compile(r"^[A-Za-z0-9._-]+$")


# --------------------------------------------------------------------------
# Small encoders
# --------------------------------------------------------------------------
def enc(value):
    """Make an arbitrary string safe for one key="value" log field.

    Percent first, so decoding in the reverse order is unambiguous: a literal
    "%09" in a path encodes to "%2509" and comes back as "%09", not a tab.
    """
    s = str(value)
    s = s.replace("%", "%25")
    s = s.replace("\t", "%09").replace("\n", "%0A").replace("\r", "%0D")
    return s


def dec(value):
    """Inverse of enc()."""
    s = str(value)
    s = s.replace("%09", "\t").replace("%0A", "\n").replace("%0D", "\r")
    return s.replace("%25", "%")


def esc_glob(name):
    """Escape the glob metacharacters, so a configured name matches literally.

    Without this a directory really called "input[1]" would never be found, and
    "input*" would silently match "input_old" and drain an unintended tree.
    """
    out = []
    for ch in name:
        if ch in "*?[]\\":
            out.append("[" + ch + "]" if ch != "\\" else "[\\\\]")
        else:
            out.append(ch)
    return "".join(out)


def split_list(value):
    """Split a comma-separated setting into its items.

    Commas only: a value may contain spaces (NAS shares routinely have them),
    and splitting on whitespace would silently make those unusable.
    """
    items = []
    for part in str(value).replace("\n", ",").split(","):
        part = part.strip()
        if part:
            items.append(part)
    return items


def stamp_from_epoch(epoch):
    """YYYYMMDD_HHMMSS for a file's mtime.

    Derived from the file rather than from the wall clock, so the name a retry
    computes is the name the first attempt computed.
    """
    try:
        return time.strftime("%Y%m%d_%H%M%S", time.localtime(float(epoch)))
    except (ValueError, OSError, OverflowError):
        return "00000000_000000"


def split_ext(base):
    """('report', '.xml') for 'report.xml'; ('.hidden', '') for a dotfile."""
    stem, dot, ext = base.rpartition(".")
    if not dot or not stem:
        return base, ""
    return stem, "." + ext


def candidate_names(base, stamp, digest):
    """The three names a file may take, in order, at a given destination.

    Same rule for the deployment tree (ON_CONFLICT="version") and for the local
    archive, so both behave identically and both are idempotent:

        report.xml
        report_<stamp>.xml                 same name, different content
        report_<stamp>_<hash8>.xml         same name, same second, still different

    The third can only ever collide with identical content, which is why the
    walk terminates.
    """
    stem, ext = split_ext(base)
    return [
        base,
        "%s_%s%s" % (stem, stamp, ext),
        "%s_%s_%s%s" % (stem, stamp, str(digest)[:8], ext),
    ]


# --------------------------------------------------------------------------
# The conflict policy
# --------------------------------------------------------------------------
def conflict_verdict(deployed_digest, incoming_digest, policy):
    """Decide what an incoming file does against what is already deployed.

    `deployed_digest` is None when nothing is there. Returns one of the outcome
    constants. Identical content is never a conflict, whatever the policy: the
    destination is already right, and the source file still has to be archived
    and drained -- skipping it would leave it in the pickup directory forever.
    """
    if deployed_digest is None:
        return DEPLOYED
    if deployed_digest == incoming_digest:
        return DEPLOYED_IDENTICAL
    return {
        "overwrite": DEPLOYED_OVERWRITE,
        "version": DEPLOYED_VERSION,
        "skip": DEPLOY_SKIPPED,
        "retry": DEPLOY_RETRY,
        "fail": DEPLOY_CONFLICT,
    }[policy]


# --------------------------------------------------------------------------
# The CSV report
# --------------------------------------------------------------------------
# The first eight are the core file-dispatch also publishes, in the same order
# and with the same meaning, so the two reports read the same way. What follows
# is what only a move can say.
REPORT_COLUMNS = (
    "filename", "first_seen", "file_date", "destination", "moved_at",
    "status", "retries", "reason",
    "relpath", "instance", "run_id", "host", "outcome",
    "source_path", "archive_path", "pickup_dir",
    "size_bytes", "hash", "prev_hash", "source_created", "age_at_pickup_s",
)

# A row's coarse state, shared with file-dispatch. `outcome` refines it with the
# deployment verdict; these three are what a dashboard filters on.
STATUS_SUCCESS = "success"
STATUS_PENDING = "pending"      # waiting: unstable, or a collision not yet clear
STATUS_FAILED = "failed"        # attempted and refused




# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
class Setting(object):
    def __init__(self, name, kind, default, choices=None, minimum=None):
        self.name = name
        self.kind = kind          # str | int | bool | list | enum | path
        self.default = default
        self.choices = choices
        self.minimum = minimum


SETTINGS = [
    # identity and the pair -- the only two that have no default
    Setting("INSTANCE_ID", "str", ""),
    Setting("SOURCE_DIR", "path", ""),
    Setting("DEPLOY_DIR", "path", ""),
    Setting("INPUT_DIR_NAME", "str", "input"),
    # safety
    Setting("MIN_STABLE_AGE", "int", 5, minimum=0),
    Setting("DRY_RUN", "bool", False),
    Setting("DEPLOY_MARKER", "str", ".file-deploy-root"),
    Setting("LOCAL_ARCHIVE_DIR", "str", "archive"),
    Setting("HASH_ALGO", "str", "sha256"),
    Setting("PRESERVE_METADATA", "bool", True),
    Setting("ON_CONFLICT", "enum", "overwrite", choices=CONFLICT_POLICIES),
    # scanning
    Setting("SCAN_INTERVAL", "int", 10, minimum=1),
    Setting("RUN_DURATION", "int", 55, minimum=0),
    Setting("DISCOVERY_INTERVAL", "int", 1800, minimum=0),
    Setting("DISCOVERY_MAXDEPTH", "int", 0, minimum=0),
    Setting("USE_DIR_MTIME_SKIP", "bool", True),
    Setting("DEEP_SCAN_INTERVAL", "int", 300, minimum=0),
    Setting("EXCLUDE_DIR_PATTERNS", "list", []),
    # report
    Setting("REPORT_DIR", "path", ""),
    Setting("REPORT_DELIMITER", "str", ","),
    Setting("REPORT_SPLIT", "enum", "none", choices=("none", "daily", "monthly")),
    Setting("REPORT_KEEP_DAYS", "int", 90, minimum=0),
    # logging
    Setting("LOG_LEVEL", "enum", "INFO", choices=("DEBUG", "INFO", "WARN", "ERROR")),
    Setting("LOG_FORMAT", "enum", "text", choices=("text", "json")),
    Setting("LOG_CONSOLE", "enum", "auto", choices=("auto", "always", "never")),
    Setting("LOG_MAX_BYTES", "int", 10485760, minimum=0),
    Setting("LOG_KEEP", "int", 7, minimum=0),
    Setting("AUDIT_LOG", "bool", True),
    Setting("HEARTBEAT_INTERVAL", "int", 60, minimum=0),
    # paths, all derived from INSTANCE_ID unless given
    Setting("STATE_DIR", "path", ""),
    Setting("LOG_DIR", "path", ""),
    Setting("LOCK_FILE", "path", ""),
]
BY_NAME = dict((s.name, s) for s in SETTINGS)

_TRUE = ("yes", "true", "on", "1")
_FALSE = ("no", "false", "off", "0")


def strip_inline_comment(line):
    """Drop a trailing # comment, unless it is inside quotes."""
    out, quote = [], None
    for ch in line:
        if quote:
            if ch == quote:
                quote = None
            out.append(ch)
        elif ch in "\"'":
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    return "".join(out)


def unquote(value):
    v = value.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


class Config(object):
    """The configuration file: KEY = value, # comments, one pair per file.

    Nothing stops at the first problem -- everything wrong is collected so a
    single --check reports the lot.
    """

    def __init__(self):
        self.values = dict((s.name, s.default) for s in SETTINGS)
        self.errors = []
        self.warnings = []
        self.path = None
        self.found = False
        # Which names the file actually set, so --check can tell a value that was
        # chosen from one that is merely the default.
        self.seen = set()

    def __getattr__(self, name):
        # Settings are read as attributes: cfg.SOURCE_DIR
        try:
            return self.__dict__["values"][name]
        except KeyError:
            raise AttributeError(name)

    def parse(self, path):
        self.path = path
        try:
            fh = open(path, "r", encoding="utf-8")
        except OSError:
            # Not an error: the built-in defaults are a valid configuration for
            # everything except the pair, which validate() then complains about.
            return self
        self.found = True
        with fh:
            for lineno, raw in enumerate(fh, 1):
                line = strip_inline_comment(raw.rstrip("\n")).strip()
                if not line:
                    continue
                name, sep, value = line.partition("=")
                if not sep:
                    self.errors.append("line %d: expected NAME = value: %s" % (lineno, line))
                    continue
                name = name.strip()
                if name not in BY_NAME:
                    self.errors.append("line %d: unknown setting '%s'" % (lineno, name))
                    continue
                self.seen.add(name)
                self._assign(name, unquote(value), lineno)
        return self

    def _assign(self, name, value, lineno):
        spec = BY_NAME[name]
        if spec.kind == "bool":
            low = value.strip().lower()
            if low in _TRUE:
                self.values[name] = True
            elif low in _FALSE:
                self.values[name] = False
            else:
                self.errors.append("line %d: %s expects yes/no, got '%s'" % (lineno, name, value))
        elif spec.kind == "int":
            try:
                n = int(value.strip())
            except ValueError:
                self.errors.append("line %d: %s expects a whole number, got '%s'"
                                   % (lineno, name, value))
                return
            if spec.minimum is not None and n < spec.minimum:
                self.errors.append("line %d: %s must be >= %d, got %d"
                                   % (lineno, name, spec.minimum, n))
                return
            self.values[name] = n
        elif spec.kind == "enum":
            low = value.strip().lower()
            # Log levels are conventionally upper case; accept either.
            if name == "LOG_LEVEL":
                low = low.upper()
            if low not in spec.choices:
                self.errors.append("line %d: %s must be one of %s, got '%s'"
                                   % (lineno, name, "/".join(spec.choices), value))
                return
            self.values[name] = low
        elif spec.kind == "list":
            self.values[name] = split_list(value)
        elif spec.kind == "path":
            self.values[name] = value.rstrip("/") or value
        else:
            self.values[name] = value

    def validate(self, config_path=None, script_dir=None):
        """Fill in what is derived, then check what cannot be derived."""
        # Identity first: every path below hangs off it, which is what makes two
        # configurations structurally unable to share state.
        if not self.values["INSTANCE_ID"]:
            base = os.path.basename(config_path or self.path or "")
            if base.endswith(".conf"):
                base = base[:-5]
            self.values["INSTANCE_ID"] = base or "file-deploy"
        inst = self.values["INSTANCE_ID"]
        if not IDENT_RE.match(inst):
            self.errors.append(
                "INSTANCE_ID '%s' is not usable: letters, digits, . _ - only" % inst)

        base_dir = script_dir or os.getcwd()
        if not self.values["STATE_DIR"]:
            self.values["STATE_DIR"] = os.path.join(base_dir, "state", inst)
        if not self.values["LOG_DIR"]:
            self.values["LOG_DIR"] = os.path.join(base_dir, "logs", inst)
        if not self.values["LOCK_FILE"]:
            self.values["LOCK_FILE"] = os.path.join(base_dir, "run-%s.lock" % inst)

        for key in ("SOURCE_DIR", "DEPLOY_DIR"):
            if not self.values[key]:
                self.errors.append("%s is required" % key)
            elif not os.path.isabs(self.values[key]):
                self.errors.append("%s must be an absolute path: %s"
                                   % (key, self.values[key]))
        if (self.values["SOURCE_DIR"] and
                self.values["SOURCE_DIR"] == self.values["DEPLOY_DIR"]):
            self.errors.append("SOURCE_DIR and DEPLOY_DIR must differ")

        if not split_list(self.values["INPUT_DIR_NAME"]):
            self.errors.append("INPUT_DIR_NAME resolves to no name at all")

        try:
            import hashlib
            hashlib.new(self.values["HASH_ALGO"])
        except Exception:
            self.errors.append("unknown HASH_ALGO: %s" % self.values["HASH_ALGO"])

        if self.values["MIN_STABLE_AGE"] == 0:
            self.warnings.append(
                "MIN_STABLE_AGE=0 is only safe if every producer writes elsewhere "
                "and renames into place; otherwise a half-written file can be "
                "deployed and then moved out of the source")
        if not self.values["DEPLOY_MARKER"]:
            self.warnings.append(
                "DEPLOY_MARKER is empty: an unmounted deployment share can no "
                "longer be told apart from an empty one")
        if not self.values["LOCAL_ARCHIVE_DIR"]:
            self.warnings.append(
                "LOCAL_ARCHIVE_DIR is empty: moved files are deleted from the "
                "source instead of being archived beside it")
        return self

    def effective(self):
        """[(name, value, from_file)] in declaration order, for --check."""
        out = []
        for spec in SETTINGS:
            v = self.values[spec.name]
            if spec.kind == "bool":
                shown = "yes" if v else "no"
            elif spec.kind == "list":
                shown = ", ".join(v) if v else "(none)"
            else:
                shown = str(v) if str(v) != "" else "(none)"
            out.append((spec.name, shown, spec.name in self.seen))
        return out

    def input_names(self):
        return split_list(self.values["INPUT_DIR_NAME"])
