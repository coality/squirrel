#!/usr/bin/env bash
#
# file-deploy.sh — MOVE files dropped into "input" directories on a mounted NAS
# share into a mirror deployment tree, keeping a local archive copy behind.
#
# Design invariants and behaviour are documented in README.md. Key points:
#   - The source tree IS MODIFIED: every file that is successfully deployed is
#     removed from it. This tool deletes data; every decision below exists to
#     make that safe.
#   - THE invariant: a file never leaves the source unless it is durably
#     present, hash-verified, in BOTH the local archive and the deployment
#     tree. Order per file: archive locally (same filesystem, last-resort
#     copy) -> deploy -> re-check the source did not change under us -> unlink.
#     Any interruption leaves the file in place, and the retry is idempotent.
#   - The local archive lives next to the file it came from, in a
#     $LOCAL_ARCHIVE_DIR directory. That directory sits inside a scanned tree,
#     so it is pruned everywhere: without that, file-deploy would re-deploy and
#     then delete its own archive.
#   - The deployment tree mirrors the source and holds the CURRENT state: a
#     redeployment overwrites (and says so). Timestamped versions accumulate in
#     the local archive, not in the deployment tree.
#   - One configuration = one source root and one deployment root. To handle
#     another pair, write another configuration file and give it its own run.
#   - Per-target logging (operations + audit); orchestration events go to _run.log.
#   - Minimal disk I/O: input directory locations are cached and only rediscovered
#     periodically; unchanged directories (same mtime) are skipped without listing.
#
# Diagnostics: when run in a console every log line is mirrored to the terminal
# (LOG_CONSOLE=auto). `--debug` turns on maximum verbosity, `--once` does a single
# pass and exits. MOUNT_MISSING logs the exact reason and the deepest existing
# ancestor so an unmounted share or a wrong path is obvious immediately.
# Run with --dry-run first on a real share: it logs every WOULD_MOVE without
# writing or deleting anything.
#
# Portability: POSIX-ish bash (>=4) plus GNU coreutils / findutils / util-linux,
# available on every mainstream Linux distribution. No distro-specific paths or
# tools, no systemd. Tools are resolved through PATH.
#
# NOTE: we deliberately do NOT use `set -e`. This is a resilient scanner: a
# transient failure on one file or one target must never abort the whole run.
# Errors are handled explicitly and logged.

set -uo pipefail

# ---------------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------------
readonly EX_OK=0        # success
readonly EX_CONFIG=1    # configuration error (bad or incomplete configuration)
readonly EX_NOSOURCE=2  # the source directory is missing, unreadable or not writable
readonly EX_LOCKED=3    # another instance holds the lock (non-fatal)
readonly EX_DEPLOY=4    # at least one deploy/archive write failed (destination broken)
readonly EX_SOURCE=5    # at least one source file could not be removed (source fills up)

# Field separator used for in-memory associative-array keys. 0x1f (unit
# separator) never appears in real paths.
readonly SEP=$'\x1f'

# ---------------------------------------------------------------------------
# Defaults (overridable by the config file)
# ---------------------------------------------------------------------------
INPUT_DIR_NAME="input"
SCAN_INTERVAL=10
RUN_DURATION=55
MIN_STABLE_AGE=5
HASH_CMD="sha256sum"
DRY_RUN=false
DISCOVERY_INTERVAL=1800
DISCOVERY_MAXDEPTH=0    # cap the discovery walk depth (0 = unlimited)
USE_DIR_MTIME_SKIP=true
# Seconds between "deep" passes that ignore USE_DIR_MTIME_SKIP. A directory's
# mtime only changes when an entry is added/removed/renamed, never when an
# existing file's content is rewritten in place, so the mtime skip alone can
# never see an in-place edit. A periodic deep pass closes that hole cheaply:
# a drained pickup directory is the steady state, so a deep pass is cheap.
# 0 = off: a share that never updates directory mtimes then hides new files.
DEEP_SCAN_INTERVAL=300
# Name of the local archive directory created next to each file that is moved
# out: <pickup dir>/$LOCAL_ARCHIVE_DIR/<name>. It is matched EXACTLY (not a
# glob, case-sensitive) and pruned from every walk, so a directory of that name
# is never deployed. "" disables the local archive entirely -- which means
# moved files exist only in the deployment tree.
LOCAL_ARCHIVE_DIR="archive"
# What to do when the deployment tree already holds this file with DIFFERENT
# content. Identical content is never a conflict: nothing is rewritten and the
# source file is drained either way. See file-deploy.conf.example.
#   overwrite  replace it; the previous version survives in the local archive
#   version    deploy alongside as <name>_<stamp><ext>, keep the deployed one
#   skip       leave the deployment tree alone; still archive and drain the source
#   retry      leave both alone and try again next cycle, until the collision clears
#   fail       refuse: keep the source file, log an error, exit 4
ON_CONFLICT="overwrite"
# Directory receiving a machine-readable CSV of every file that moved, one row
# per file, for BI tools. "" disables it. See file-deploy.conf.example.
REPORT_DIR=""
REPORT_DELIMITER=","
# Sentinel file expected at the root of every deploy_root. It is what tells an
# unmounted deployment share apart from an empty one; see check_deploy_root.
# "" disables the check (not recommended on a mounted share).
DEPLOY_MARKER=".file-deploy-root"
LOG_LEVEL="INFO"
LOG_FORMAT="text"
LOG_ROTATE_MAX_BYTES=10485760
LOG_ROTATE_KEEP=7
AUDIT_LOG=true
LOG_CONSOLE="auto"      # auto (mirror to terminal when interactive) | always | never
HEARTBEAT_INTERVAL=60   # seconds between periodic "still alive" summaries (0 = off)
EXCLUDE_DIR_PATTERNS=() # case-insensitive glob patterns of directory names to ignore (empty = none)

# The pair this configuration drains. One configuration = one source root and
# one deployment root, mirroring each other. To handle another pair, write
# another configuration file and give it its own run.
SOURCE_DIR=""
DEPLOY_DIR=""
# Identifier for this configuration. It names the instance in the logs and in
# the CSV report, AND it is what the state, log and lock paths are derived from,
# so two configurations can never share them by accident. Defaults to the
# configuration file's base name; [A-Za-z0-9._-] only.
INSTANCE_ID=""

# Resolve the script directory portably (no readlink -f).
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

# Path defaults derived from the script directory (may be overridden in config).
# Left empty on purpose: resolved from INSTANCE_ID after the config is read, so
# that setting them is optional and never accidental. Override in the config to
# put them elsewhere.
STATE_DIR=""
LOG_DIR=""
LOCK_FILE=""

CONFIG_FILE="$SCRIPT_DIR/file-deploy.conf"

ACTION="run"           # run | rediscover
FORCE_REDISCOVER=0     # set per-cycle when a manual rediscovery is requested
FORCE_MARKER=""        # marker file path, set in main once STATE_DIR is known
FORCE_DEBUG=0          # --debug: max verbosity + console
FORCE_CONSOLE=""       # --verbose: applied AFTER the config file so the flag wins
FORCE_DRY=0            # --dry-run: rehearse without editing the config file
ONCE=0                 # --once: single pass then exit
CONSOLE_ON=0           # whether log lines are mirrored to the terminal
CONFIG_STATUS="none"   # none | loaded | missing

# ---------------------------------------------------------------------------
# Small portable helpers
# ---------------------------------------------------------------------------

# now_epoch: current time in seconds. Uses the bash printf builtin when
# available (>=4.2) to avoid forking, falls back to date(1).
now_epoch() {
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )); then
        printf '%(%s)T' -1
    else
        date +%s
    fi
}

ts_iso() {  # ISO-8601 timestamp with timezone
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )); then
        printf '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    else
        date +%Y-%m-%dT%H:%M:%S%z
    fi
}

ts_compact() {  # YYYYMMDD_HHMMSS, used to name new versions
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )); then
        printf '%(%Y%m%d_%H%M%S)T' -1
    else
        date +%Y%m%d_%H%M%S
    fi
}

# file_size: byte size of a file, portable (stat -c, fallback wc -c).
file_size() {
    local p=$1 out
    if out=$(stat -c '%s' -- "$p" 2>/dev/null); then
        printf '%s' "$out"
    else
        # The braces matter: a failing "< $p" redirection is reported by the
        # shell itself, before wc runs, so wc's own 2>/dev/null would not
        # silence it and every first-touch of a not-yet-created log file would
        # leak an error to stderr (cron mail on every fresh deployment).
        { wc -c < "$p" | tr -d ' '; } 2>/dev/null
    fi
}

# get_meta: prints "<size> <mtime_epoch>" for a file, portable.
get_meta() {
    local p=$1 out sz mt
    if out=$(stat -c '%s %Y' -- "$p" 2>/dev/null); then
        printf '%s' "$out"
        return 0
    fi
    sz=$( { wc -c < "$p" | tr -d ' '; } 2>/dev/null ) || return 1
    mt=$(date -r "$p" +%s 2>/dev/null) || return 1
    printf '%s %s' "$sz" "$mt"
}

# get_mtime: mtime (epoch) of a path (file or directory), portable.
get_mtime() {
    local p=$1 out
    if out=$(stat -c '%Y' -- "$p" 2>/dev/null); then
        printf '%s' "$out"
    else
        date -r "$p" +%s 2>/dev/null
    fi
}

# hash_file: content hash of a file (first field of $HASH_CMD output).
hash_file() {
    local p=$1 out
    out=$("$HASH_CMD" -- "$p" 2>/dev/null) || return 1
    printf '%s' "${out%% *}"
}

# deepest_existing: longest existing prefix of a path (diagnostic for a missing
# source: shows how far the path resolves before it breaks).
deepest_existing() {
    local p=$1
    [[ -e $p ]] && { printf '%s' "$p"; return; }
    while [[ $p == */* ]]; do
        p=${p%/*}; [[ -z $p ]] && p=/
        [[ -e $p ]] && { printf '%s' "$p"; return; }
    done
    printf '/'
}

# mount_reason: why a source cannot be scanned ("ok" if it can).
mount_reason() {
    local s=$1
    if   [[ ! -e $s ]]; then printf 'path does not exist'
    elif [[ ! -d $s ]]; then printf 'exists but is not a directory'
    elif [[ ! -r $s ]]; then printf 'directory not readable (permissions)'
    elif [[ ! -x $s ]]; then printf 'directory not searchable (need +x to list)'
    elif [[ ! -w $s ]]; then printf 'directory not writable (files are moved out, so +w is required)'
    else printf 'ok'
    fi
}

# enc: make an arbitrary string safe for a single TSV/log field by escaping
# percent, tab, newline and carriage return. Reversible with dec_r.
enc() {
    local s=$1
    s=${s//'%'/%25}
    s=${s//$'\t'/%09}
    s=${s//$'\n'/%0A}
    s=${s//$'\r'/%0D}
    printf '%s' "$s"
}

# enc_r / dec_r: fork-free variants that store the result in REPLY (no command
# substitution), for the cache read/write loops where $() would fork per line.
enc_r() {
    local s=$1
    s=${s//'%'/%25}; s=${s//$'\t'/%09}; s=${s//$'\n'/%0A}; s=${s//$'\r'/%0D}
    REPLY=$s
}
dec_r() {
    local s=$1
    s=${s//%09/$'\t'}; s=${s//%0A/$'\n'}; s=${s//%0D/$'\r'}; s=${s//%25/'%'}
    REPLY=$s
}

# json_esc: escape backslash and double quote for JSON string values. enc()
# has already removed control characters, so this is sufficient.
json_esc() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# trim: strip leading/trailing whitespace.
trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# sanitize: keep only filesystem-safe characters (for log/state file names).
sanitize() {
    local s=$1
    s=${s//[^A-Za-z0-9._-]/_}
    printf '%s' "$s"
}

# is_uint: true if the argument is a non-empty string of digits.
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

# is_int: true for an integer, negative allowed. Used for mtimes: a file dated
# before 1970 has a negative epoch and is perfectly valid, so is_uint would
# wrongly report it as unreadable metadata and keep its directory unsettled.
is_int() { [[ $1 =~ ^-?[0-9]+$ ]]; }

# esc_glob: escape the glob metacharacters find(1) interprets in -name, so a
# configured directory name is matched literally, as documented. Without this a
# directory really named "input[1]" never matches, and "input*" silently
# matches "input_old" and archives an unintended tree.
esc_glob() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\*/\\*}; s=${s//\?/\\?}; s=${s//[/\\[}
    printf '%s' "$s"
}

# is_excluded_dirname: true if a directory basename matches any EXCLUDE_DIR_PATTERNS
# entry. Case-insensitive glob (both sides lowercased; RHS unquoted = glob).
is_excluded_dirname() {
    local name=${1,,} pat
    for pat in "${EXCLUDE_DIR_PATTERNS[@]:-}"; do
        [[ -z $pat ]] && continue
        [[ $name == ${pat,,} ]] && return 0
    done
    return 1
}

# build_prune_expr: fill PRUNE_EXPR with the find(1) expression that prunes
# both the EXCLUDE_DIR_PATTERNS directories (case-insensitive globs) and the
# local archive directories (exact name, case-sensitive).
#
# Pruning $LOCAL_ARCHIVE_DIR is not an optimisation, it is a correctness
# requirement: the local archive is created INSIDE a scanned tree, so without
# this every archived file would be picked up again on the next cycle under a
# different relative path, deployed a second time, and then deleted from the
# source -- destroying the archive this tool exists to keep.
declare -a PRUNE_EXPR=()
build_prune_expr() {
    PRUNE_EXPR=()
    local pat first=1
    for pat in "${EXCLUDE_DIR_PATTERNS[@]:-}"; do
        [[ -z $pat ]] && continue
        if (( first )); then PRUNE_EXPR+=( '(' -type d '(' -iname "$pat" ); first=0
        else PRUNE_EXPR+=( -o -iname "$pat" ); fi
    done
    if [[ -n $LOCAL_ARCHIVE_DIR ]]; then
        if (( first )); then PRUNE_EXPR+=( '(' -type d '(' -name "$(esc_glob "$LOCAL_ARCHIVE_DIR")" ); first=0
        else PRUNE_EXPR+=( -o -name "$(esc_glob "$LOCAL_ARCHIVE_DIR")" ); fi
    fi
    (( first )) || PRUNE_EXPR+=( ')' -prune ')' -o )
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# Numeric log levels (fork-free lookup).
declare -A LVLNUM=( [DEBUG]=10 [INFO]=20 [WARN]=30 [ERROR]=40 )
LOG_LEVEL_NUM=20         # recomputed from LOG_LEVEL after config load
DEBUG_ON=0              # 1 when LOG_LEVEL is DEBUG (used to gate hot-path debug logs)
declare -A LOG_BYTES=() # per-file running size, to rotate without a stat per line

# _rotate_file: shift <file> -> <file>.1 .. .N (no size check; the caller decides).
_rotate_file() {
    local f=$1 keep=$LOG_ROTATE_KEEP i
    [[ -f "$f.$keep" ]] && rm -f -- "$f.$keep"
    for (( i = keep - 1; i >= 1; i-- )); do
        [[ -f "$f.$i" ]] && mv -f -- "$f.$i" "$f.$((i + 1))"
    done
    [[ -f $f ]] && mv -f -- "$f" "$f.1"
    : > "$f"
}

# Instance context: one configuration = one instance, named by INSTANCE_ID.
CUR_INSTANCE=""
CUR_CYCLE=""
CUR_OPLOG=""
CUR_AUDIT=""
RUN_ID=""

# _emit_file <file> <withctx 0|1> <level> <event> [k=v ...]
# Writes one structured line to the log file, and mirrors it to the terminal
# (stderr) when CONSOLE_ON is set.
_emit_file() {
    local file=$1 withctx=$2 level=$3 event=$4
    shift 4
    (( ${LVLNUM[$level]:-20} >= LOG_LEVEL_NUM )) || return 0
    local ts line kv k v
    # Fork-free timestamp (printf builtin on bash >= 4.2).
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )); then
        printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    else
        ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    fi
    if [[ $LOG_FORMAT == json ]]; then
        line="{\"ts\":\"$ts\",\"level\":\"$level\",\"run\":\"$(json_esc "$RUN_ID")\""
        if (( withctx )) && [[ -n $CUR_INSTANCE ]]; then
            line+=",\"instance\":\"$(json_esc "$CUR_INSTANCE")\""
            [[ -n $CUR_CYCLE ]] && line+=",\"cycle\":$CUR_CYCLE"
        fi
        line+=",\"event\":\"$event\""
        for kv in "$@"; do
            k=${kv%%=*}; v=${kv#*=}
            line+=",\"$(json_esc "$k")\":\"$(json_esc "$v")\""
        done
        line+="}"
    else
        line="$ts $level run=$RUN_ID"
        if (( withctx )) && [[ -n $CUR_INSTANCE ]]; then
            line+=" instance=$CUR_INSTANCE"
            [[ -n $CUR_CYCLE ]] && line+=" cycle=$CUR_CYCLE"
        fi
        line+=" event=$event"
        for kv in "$@"; do
            k=${kv%%=*}; v=${kv#*=}
            line+=" $k=\"$v\""
        done
    fi
    _append_rotating "$file" "$line"
    (( CONSOLE_ON )) && printf '%s\n' "$line" >&2
    return 0
}

# _append_rotating <file> <line>: append one line, rotating the file first when
# it has grown past LOG_ROTATE_MAX_BYTES. Byte-counter rotation: no stat per
# line, the size is read once per file per run (first touch) then tracked in
# memory. Every append goes through here — the audit log included, otherwise it
# would grow without bound while the docs promise rotation.
_append_rotating() {
    local file=$1 line=$2
    if (( LOG_ROTATE_MAX_BYTES > 0 )); then
        if [[ -z ${LOG_BYTES[$file]+x} ]]; then
            LOG_BYTES[$file]=$(file_size "$file"); is_uint "${LOG_BYTES[$file]}" || LOG_BYTES[$file]=0
        fi
        if (( LOG_BYTES[$file] >= LOG_ROTATE_MAX_BYTES )); then
            _rotate_file "$file"; LOG_BYTES[$file]=0
        fi
        LOG_BYTES[$file]=$(( LOG_BYTES[$file] + ${#line} + 1 ))
    fi
    printf '%s\n' "$line" >> "$file"
}

# ---------------------------------------------------------------------------
# CSV report (optional): one row per file that moved, for BI tools.
#
# Written to $REPORT_DIR/file-deploy-YYYY-MM-DD.csv -- one file per day, every
# target in it, so a BI tool can point at the directory and append the lot. The
# header is written when the file is created. RFC 4180 quoting: text fields are
# always quoted and inner quotes doubled, so paths containing the delimiter, a
# quote or a newline survive. Numeric and timestamp fields are left bare so they
# type cleanly on import.
#
# Nothing is written during a rehearsal: --dry-run stays inert.
# ---------------------------------------------------------------------------
REPORT_FILE=""
declare -A REPORT_STARTED=()

csv_q() {  # quote one text field
    local v=$1
    v=${v//\"/\"\"}
    printf '"%s"' "$v"
}

# report_row <outcome> <src_path> <deploy_path> <archive_path> <relpath>
#            <size> <hash> <prev_hash> <mtime_epoch> <btime_epoch> <age_s> <pickup_dir>
report_row() {
    [[ -n $REPORT_DIR ]] || return 0
    [[ $DRY_RUN == true ]] && return 0
    local d=$REPORT_DELIMITER day
    printf -v day '%(%Y-%m-%d)T' -1 2>/dev/null || day=$(date +%Y-%m-%d)
    REPORT_FILE="$REPORT_DIR/file-deploy-$day.csv"
    if [[ -z ${REPORT_STARTED[$REPORT_FILE]:-} ]]; then
        REPORT_STARTED[$REPORT_FILE]=1
        mkdir -p -- "$REPORT_DIR" 2>/dev/null
        if [[ ! -s $REPORT_FILE ]]; then
            printf '%s\n' "run_id${d}deployed_at${d}instance${d}outcome${d}file_name${d}relpath${d}source_path${d}deploy_path${d}archive_path${d}size_bytes${d}hash${d}prev_hash${d}source_modified${d}source_created${d}age_at_pickup_s${d}pickup_dir${d}host" \
                >> "$REPORT_FILE" 2>/dev/null
        fi
    fi
    local created=""
    (( ${10} > 0 )) && created=$(epoch_iso "${10}")
    printf '%s\n' "$(csv_q "$RUN_ID")$d$(epoch_iso "$(now_epoch)")$d$(csv_q "$CUR_INSTANCE")$d$(csv_q "$1")$d$(csv_q "${2##*/}")$d$(csv_q "$5")$d$(csv_q "$2")$d$(csv_q "$3")$d$(csv_q "$4")$d${6}$d$(csv_q "$7")$d$(csv_q "$8")$d$(epoch_iso "$9")$d${created}$d${11}$d$(csv_q "${12}")$d$(csv_q "${HOSTNAME:-}")" \
        >> "$REPORT_FILE" 2>/dev/null
    return 0
}

# epoch_iso <epoch>: ISO-8601 with timezone, the form BI tools parse directly.
epoch_iso() {
    local e=$1 out
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )) && (( e >= 0 )); then
        printf '%(%Y-%m-%dT%H:%M:%S%z)T' "$e"; return 0
    fi
    out=$(date -d "@$e" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) || out=""
    printf '%s' "$out"
}

log_run() { local lvl=$1 ev=$2; shift 2; _emit_file "$RUN_LOG" 0 "$lvl" "$ev" "$@"; }
log_tgt() { local lvl=$1 ev=$2; shift 2; _emit_file "$CUR_OPLOG" 1 "$lvl" "$ev" "$@"; }

# audit_write <action> <encrel> <encarchive> <hash> <size> [prev_hash]
# The per-target provenance record: one line per file that actually moved.
#
# There is deliberately no separate "target" field: the deployment tree mirrors
# the source, so the relative path is identical on both sides by construction,
# and the two roots are logged once per run in the TARGET line. <action> carries
# the outcome (DEPLOYED / DEPLOYED_OVERWRITE / DEPLOYED_IDENTICAL) rather than a
# constant, and prev_hash records what an overwrite replaced.
audit_write() {
    [[ $AUDIT_LOG == true ]] || return 0
    local line="ts=$(ts_iso) run=$RUN_ID action=$1 relpath=\"$2\" archive=\"$3\" hash=$4 size=$5"
    [[ -n ${6:-} ]] && line+=" prev_hash=$6"
    _append_rotating "$CUR_AUDIT" "$line"
}

# ---------------------------------------------------------------------------
# Discovery (locate input dirs) + per-leaf settled mtimes
#   STATE_DIR/<key>.inputs.tsv  -> one enc(input_dir) per line (governs rediscovery)
#   STATE_DIR/<key>.leaves.tsv  -> "<enc(leaf)>\t<settled_mtime>" (per-leaf skip state)
# ---------------------------------------------------------------------------

# discover_or_load_dirs <src> <idn> <inputs_cache> <leaves_cache>
# Populates INPUT_DIRS (the input directories) and DIRLAST (leaf -> settled mtime).
# The full-tree walk (rediscovery) only LOCATES input dirs: it prunes AT each input
# (never descends into them) and honours DISCOVERY_MAXDEPTH / EXCLUDE_DIR_PATTERNS,
# so it does not walk the (large) subtrees. Sub-directories are enumerated cheaply
# per cycle in scan_cycle (one bulk readdir per input).
declare -a INPUT_DIRS=()
declare -A DIRLAST=()
declare -a IDNAMES=()

# split_idn <list>: split the configured input directory names into IDNAMES.
# ONLY commas (and newlines) separate. A whitespace split would silently make
# every name containing a space unusable -- and NAS shares routinely have them,
# which is why the comma is the only separator.
split_idn() {
    local rest=${1//$'\n'/,} nm
    IDNAMES=()
    while : ; do
        nm=$(trim "${rest%%,*}")
        [[ -n $nm ]] && IDNAMES+=("$nm")
        [[ $rest == *,* ]] || break
        rest=${rest#*,}
    done
}

# discovery_signature: everything that changes WHICH directories a discovery
# walk would find. Stored in the inputs cache so that editing any of it takes
# effect on the next cycle instead of up to DISCOVERY_INTERVAL later.
discovery_signature() {
    local sig="maxdepth=$DISCOVERY_MAXDEPTH" nm pat
    for nm in "${IDNAMES[@]:-}";               do [[ -n $nm ]] && sig+="|n=$(enc "$nm")"; done
    for pat in "${EXCLUDE_DIR_PATTERNS[@]:-}"; do sig+="|x=$(enc "$pat")"; done
    printf '%s' "$sig"
}

# load_leaves_cache <leaves_cache>: (re)populate DIRLAST from the per-leaf settled
# mtime cache on local disk (cheap). Shared by input discovery and fixed scanning.
# Bumped whenever the meaning of a settled mtime changes. On a mismatch the
# cache is discarded, so every directory is rescanned once. Without this, the
# first move-mode run of an upgraded deployment would find every pickup
# directory "unchanged" since the last copy-mode run and skip the whole backlog.
readonly LEAVES_CACHE_VERSION="#v2-move"
load_leaves_cache() {
    local leaves_cache=$1 encleaf lastm n=0
    DIRLAST=()
    [[ -f $leaves_cache ]] || return 0
    while IFS=$'\t' read -r encleaf lastm || [[ -n $encleaf ]]; do
        (( n++ ))
        if (( n == 1 )); then
            [[ $encleaf == "$LEAVES_CACHE_VERSION" ]] || { DIRLAST=(); return 0; }
            continue
        fi
        [[ -z $encleaf ]] && continue
        dec_r "$encleaf"; DIRLAST["$REPLY"]=$lastm
    done < "$leaves_cache"
}

discover_or_load_dirs() {
    local src=$1 idn=$2 inputs_cache=$3 leaves_cache=$4
    INPUT_DIRS=()

    # Load persisted per-leaf settled mtimes (local disk, cheap).
    load_leaves_cache "$leaves_cache"

    # Resolve the names once; the cache is only reusable while the settings that
    # shape the walk are unchanged (recorded as a header line in the cache).
    split_idn "$idn"
    local header; header="#sig"$'\t'"$(enc "$(discovery_signature)")"

    # Decide whether to re-locate the input dirs (the expensive full-tree walk).
    local need_discovery=0 now cache_mt age reason="cache-fresh" first_line=""
    now=$(now_epoch)
    if [[ ! -f $inputs_cache ]]; then need_discovery=1; reason="no-cache"
    else
        IFS= read -r first_line < "$inputs_cache" || first_line=""
        if [[ $first_line != "$header" ]]; then
            need_discovery=1; reason="config-changed"
        else
            cache_mt=$(get_mtime "$inputs_cache"); is_uint "$cache_mt" || cache_mt=0
            age=$(( now - cache_mt )); (( age >= DISCOVERY_INTERVAL )) && { need_discovery=1; reason="cache-stale"; }
        fi
    fi
    (( FORCE_REDISCOVER )) && { need_discovery=1; reason="forced"; }

    if (( need_discovery )); then
        local t0 t1 d
        t0=$(now_epoch)
        log_tgt DEBUG DISCOVERY_BEGIN src="$(enc "$src")" input_dir_name="$idn" reason="$reason"
        # Optional depth cap.
        local -a dexpr=(); (( DISCOVERY_MAXDEPTH > 0 )) && dexpr=( -maxdepth "$DISCOVERY_MAXDEPTH" )
        # Prune expression from the exclude patterns (case-insensitive).
        local -a fexpr=(); build_prune_expr; fexpr=( ${PRUNE_EXPR[@]+"${PRUNE_EXPR[@]}"} )
        # Match ANY of the configured input dir names, literally: the names are
        # glob-escaped so "exact, case-sensitive, no globs" is actually true.
        local -a nexpr=(); local nm firstn=1
        for nm in "${IDNAMES[@]:-}"; do
            [[ -z $nm ]] && continue
            if (( firstn )); then nexpr+=( '(' -name "$(esc_glob "$nm")" ); firstn=0
            else nexpr+=( -o -name "$(esc_glob "$nm")" ); fi
        done
        if (( firstn )); then
            log_tgt WARN NO_INPUT_DIR_NAME input_dir_name="$(enc "$idn")" \
                hint="input_dir_name resolved to an empty list of names; nothing can be discovered"
            write_inputs_cache "$inputs_cache" "$header"
            return 0
        fi
        nexpr+=( ')' )
        local -a newinputs=()
        # -print0 -prune: print each input dir and DO NOT descend into it.
        while IFS= read -r -d '' d; do
            newinputs+=("$d")
            (( DEBUG_ON )) && log_tgt DEBUG FOUND_INPUT_DIR dir="$(enc "${d#"$src"/}")"
        done < <(find "$src" ${dexpr[@]+"${dexpr[@]}"} ${fexpr[@]+"${fexpr[@]}"} \
                      -type d ${nexpr[@]+"${nexpr[@]}"} -print0 -prune 2>/dev/null)
        INPUT_DIRS=(); (( ${#newinputs[@]} )) && INPUT_DIRS=("${newinputs[@]}")
        write_inputs_cache "$inputs_cache" "$header"
        t1=$(now_epoch)
        log_tgt INFO DISCOVERY input_dirs="${#newinputs[@]}" dur_s="$(( t1 - t0 ))" \
            src="$(enc "$src")" input_dir_name="$idn" reason="$reason"
        if (( ${#newinputs[@]} == 0 )); then
            log_tgt WARN NO_INPUT_DIRS src="$(enc "$src")" input_dir_name="$idn" \
                hint="no directory named '$idn' (any of the listed names) found under the source"
        fi
    else
        local encd n=0
        while IFS= read -r encd || [[ -n $encd ]]; do
            (( n++ )); (( n == 1 )) && continue   # signature header
            [[ -z $encd ]] && continue
            dec_r "$encd"; INPUT_DIRS+=("$REPLY")
        done < "$inputs_cache"
        log_tgt DEBUG DISCOVERY_CACHED input_dirs="${#INPUT_DIRS[@]}"
    fi
}

write_inputs_cache() {  # cache header
    local cache=$1 header=$2 d tmp="$1.tmp.$$"
    if ! : > "$tmp" 2>/dev/null; then
        log_tgt WARN CACHE_WRITE_FAILED cache="$(enc "$cache")" stage="create"
        return 1
    fi
    {
        printf '%s\n' "$header"
        for d in "${INPUT_DIRS[@]:-}"; do
            [[ -z $d ]] && continue
            enc_r "$d"; printf '%s\n' "$REPLY"
        done
    } >> "$tmp"
    if ! mv -f -- "$tmp" "$cache" 2>/dev/null; then
        log_tgt WARN CACHE_WRITE_FAILED cache="$(enc "$cache")" stage="rename"
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Per-run accumulators
# ---------------------------------------------------------------------------
SOURCE_OK=0           # 1 once the source has been scannable at least once
MOUNT_STATE=""        # "" | ok | missing, so a change of state is logged once
DEPLOY_CHECKED=0      # 1 once the deployment root has been validated this run
DEPLOYED_ONCE=0       # 1 once the "we have deployed here" state file exists
ANY_DEPLOY_FAILED=0   # something could not be written to the deployment tree -> exit 4
ANY_SOURCE_STUCK=0    # something was deployed but could not leave the source -> exit 5
RUN_DEPLOYED=0 RUN_OVERWRITTEN=0 RUN_CONFLICTS=0 RUN_MOVED=0 RUN_ERRORS=0 RUN_SCANNED=0

# _file_error <errkey> <event> [k=v ...]
# Report a per-file error that may well be permanent (unreadable file, bogus
# metadata, undrainable directory). The LOG is deduplicated to once per run per
# (file, identity) so a single bad file cannot emit one WARN per cycle
# (~8 600/day at SCAN_INTERVAL=10), but DIR_UNSETTLED is set EVERY time.
#
# That asymmetry is deliberate and is specific to move mode: a file left behind
# in a pickup directory is an unfinished job, so the directory must never be
# recorded as settled -- otherwise the mtime skip would stop looking at it and
# the file would only ever be retried by the periodic deep pass. The steady
# state of a pickup directory is empty, so this costs nothing in practice.
declare -A ERR_SEEN=()
_file_error() {
    local ek=$1 ev=$2; shift 2
    (( CYC_ERRORS++ ))
    DIR_UNSETTLED=1
    if [[ -z ${ERR_SEEN[$ek]:-} ]]; then
        ERR_SEEN[$ek]=1
        log_tgt WARN "$ev" "$@"
    else
        (( DEBUG_ON )) && log_tgt DEBUG "$ev" "$@" repeat="1"
    fi
    return 0
}

# atomic_copy <src> <dst> <expected_hash>
# Copy to a hidden sibling temporary name, verify the copy's hash, and only
# then rename it into place. Verifying BEFORE the rename means a corrupt or
# short copy never becomes visible at the destination, and never clobbers the
# good file that was already deployed there. The temp is a sibling of <dst>, so
# the rename is same-filesystem and therefore atomic; it is dot-prefixed so a
# downstream consumer globbing the deployment tree cannot pick it up.
COPY_STAGE=""
COPY_ERR=""
INFLIGHT_TMP=""
atomic_copy() {
    local src=$1 dst=$2 want=$3 dir=${2%/*} base=${2##*/} tmp err got
    tmp="$dir/.$base.file-deploy-tmp.$$"
    COPY_STAGE=""; COPY_ERR=""
    INFLIGHT_TMP=$tmp
    if ! err=$(cp -p -- "$src" "$tmp" 2>&1); then
        COPY_STAGE=cp; COPY_ERR=$err; rm -f -- "$tmp" 2>/dev/null; INFLIGHT_TMP=""; return 1
    fi
    if ! got=$(hash_file "$tmp"); then
        COPY_STAGE=verify; COPY_ERR="the copy could not be hashed back"
        rm -f -- "$tmp" 2>/dev/null; INFLIGHT_TMP=""; return 1
    fi
    if [[ $got != "$want" ]]; then
        COPY_STAGE=verify; COPY_ERR="hash mismatch: expected ${want:0:12} got ${got:0:12}"
        rm -f -- "$tmp" 2>/dev/null; INFLIGHT_TMP=""; return 1
    fi
    if ! err=$(mv -f -- "$tmp" "$dst" 2>&1); then
        COPY_STAGE=mv; COPY_ERR=$err; rm -f -- "$tmp" 2>/dev/null; INFLIGHT_TMP=""; return 1
    fi
    INFLIGHT_TMP=""
    return 0
}

# A hard kill must not leave a partial file behind in a tree someone deploys
# from. The temp is hidden and pid-unique, so this only ever removes our own.
cleanup_inflight() { [[ -n $INFLIGHT_TMP ]] && rm -f -- "$INFLIGHT_TMP" 2>/dev/null; }
trap cleanup_inflight EXIT INT TERM

# conflict_verdict <dst> <hash> <mtime>
# Decide what a file would do against the current deployment tree, WITHOUT
# writing anything: sets VERDICT, VERDICT_DST and VERDICT_OLD_HASH. Shared by
# deploy_file and the dry run, so a rehearsal reports exactly what would happen.
#   nothing there            -> DEPLOYED
#   identical content        -> DEPLOYED_IDENTICAL (never a conflict)
#   different content        -> per $ON_CONFLICT
VERDICT=""
VERDICT_DST=""
VERDICT_OLD_HASH=""
conflict_verdict() {
    local dst=$1 h=$2 mtime=$3 old
    VERDICT=DEPLOYED; VERDICT_DST=$dst; VERDICT_OLD_HASH=""
    [[ -f $dst ]] || return 0
    old=$(hash_file "$dst" 2>/dev/null) || old=""
    if [[ -n $old && $old == "$h" ]]; then VERDICT=DEPLOYED_IDENTICAL; return 0; fi
    VERDICT_OLD_HASH=$old
    case $ON_CONFLICT in
        overwrite) VERDICT=DEPLOYED_OVERWRITE ;;
        skip)      VERDICT=DEPLOY_SKIPPED ;;
        retry)     VERDICT=DEPLOY_RETRY ;;
        fail)      VERDICT=DEPLOY_CONFLICT ;;
        version)
            pick_free_path "${dst%/*}" "${dst##*/}" "$(stamp_from_epoch "$mtime")" "$h"
            VERDICT_DST=$PICKED
            (( PICKED_EXISTS )) && VERDICT=DEPLOYED_IDENTICAL || VERDICT=DEPLOYED_VERSION ;;
    esac
    return 0
}

# deploy_file <src> <dst> <hash> <mtime> <encrel>
# Put the file in the deployment tree according to $ON_CONFLICT. Sets
# DEPLOY_ACTION and, on a real write, DEPLOY_DST. Returns 1 (and logs) on
# failure, always leaving whatever was already deployed untouched.
DEPLOY_ACTION=""
DEPLOY_OLD_HASH=""
DEPLOY_DST=""
declare -A CONFLICT_SEEN=()   # key SEP relpath -> 1 once a pending conflict was reported
deploy_file() {
    local src=$1 dst=$2 h=$3 mtime=$4 encrel=$5 err dst_dir=${2%/*}
    DEPLOY_ACTION=DEPLOYED; DEPLOY_OLD_HASH=""; DEPLOY_DST=$dst
    if ! err=$(mkdir -p -- "$dst_dir" 2>&1); then
        log_tgt ERROR DEPLOY_FAILED stage="mkdir" relpath="$encrel" \
            dst_dir="$(enc "$dst_dir")" err="$(enc "$err")"
        (( CYC_ERRORS++ )); ANY_DEPLOY_FAILED=1
        return 1
    fi
    conflict_verdict "$dst" "$h" "$mtime"
    DEPLOY_ACTION=$VERDICT; DEPLOY_OLD_HASH=$VERDICT_OLD_HASH; DEPLOY_DST=$VERDICT_DST

    case $DEPLOY_ACTION in
        DEPLOYED_IDENTICAL)
            # Already there byte for byte. Nothing to write -- but the source
            # file is still archived and drained, so this is NOT a skip.
            return 0 ;;
        DEPLOY_SKIPPED)
            # The deployment tree is authoritative: leave it alone. The source
            # file is still archived, so its content is not lost, and it is
            # drained so it cannot pile up in the pickup directory.
            (( CYC_CONFLICTS++ ))
            log_tgt WARN DEPLOY_SKIPPED relpath="$encrel" dst="$(enc "$dst")" \
                deployed_hash="${DEPLOY_OLD_HASH:0:8}…" incoming_hash="${h:0:8}…" \
                on_conflict="$ON_CONFLICT" \
                hint="the deployment tree was left untouched; the incoming file is archived and drained"
            return 0 ;;
        DEPLOY_RETRY)
            # Neither side is touched and the source file stays put, so the
            # collision is re-evaluated every cycle: this is a pending state,
            # not a failure, hence WARN once per run and exit 0. It clears by
            # itself as soon as the deployed file changes or goes away.
            (( CYC_CONFLICTS++ ))
            if [[ -z ${CONFLICT_SEEN["$encrel"]:-} ]]; then
                CONFLICT_SEEN["$encrel"]=1
                log_tgt WARN DEPLOY_RETRY relpath="$encrel" dst="$(enc "$dst")" \
                    deployed_hash="${DEPLOY_OLD_HASH:0:8}…" incoming_hash="${h:0:8}…" \
                    on_conflict="$ON_CONFLICT" \
                    hint="both sides left untouched; the source file is kept and retried every cycle"
            elif (( DEBUG_ON )); then
                log_tgt DEBUG DEPLOY_RETRY relpath="$encrel" repeat="1"
            fi
            return 1 ;;
        DEPLOY_CONFLICT)
            (( CYC_CONFLICTS++ )); (( CYC_ERRORS++ )); ANY_DEPLOY_FAILED=1
            log_tgt ERROR DEPLOY_CONFLICT relpath="$encrel" dst="$(enc "$dst")" \
                deployed_hash="${DEPLOY_OLD_HASH:0:8}…" incoming_hash="${h:0:8}…" \
                on_conflict="$ON_CONFLICT" \
                hint="the source file was kept; resolve the collision or change ON_CONFLICT"
            return 1 ;;
        DEPLOYED_VERSION) (( CYC_CONFLICTS++ )) ;;
    esac

    if ! atomic_copy "$src" "$DEPLOY_DST" "$h"; then
        log_tgt ERROR DEPLOY_FAILED stage="$COPY_STAGE" relpath="$encrel" \
            dst="$(enc "$DEPLOY_DST")" err="$(enc "$COPY_ERR")"
        (( CYC_ERRORS++ )); ANY_DEPLOY_FAILED=1
        return 1
    fi
    return 0
}

# archive_source <src> <archive_dir> <base> <hash> <mtime> <encrel>
# Remove the file from its pickup directory by RENAMING it into the local
# archive. Sets ARC_PATH. Returns 1 (and logs) on failure.
#
# rename(2), not copy-then-delete, and that is the load-bearing decision:
#   - it is ONE atomic, irreversible operation instead of two, so it is the
#     single commit point at which the source tree changes;
#   - the archived copy cannot be truncated or corrupt -- it is the same inode,
#     so there is nothing to verify and nothing to reconcile after a crash;
#   - the state "archived but not deployed" cannot exist, because the archive
#     step happens last;
#   - it costs no I/O on the source share (a second full write of every file
#     over CIFS is not free) and it preserves mtime, mode and owner exactly.
# The archive directory is a child of the pickup directory, hence the same
# filesystem. If someone bind-mounts it elsewhere, mv(1) degrades to
# copy+unlink: still lossless, just no longer atomic.
#
# Naming is a pure function of (basename, source mtime, content hash), so every
# retry of a stuck file targets exactly the same path and no duplicate can
# accumulate:
#   - name free                       -> use it
#   - taken, identical content        -> reuse it (the file was re-dropped
#                                        unchanged, or a previous run got this
#                                        far); the source is still consumed
#   - taken, different content        -> <stem>_<mtime stamp><ext>, then
#                                        <stem>_<mtime stamp>_<hash8><ext>
ARC_PATH=""
archive_source() {
    local src=$1 la=$2 base=$3 h=$4 mtime=$5 encrel=$6
    local err cand
    ARC_PATH=""
    if ! err=$(mkdir -p -- "$la" 2>&1); then
        log_tgt ERROR ARCHIVE_DIR_FAILED relpath="$encrel" dir="$(enc "$la")" err="$(enc "$err")"
        (( CYC_ERRORS++ )); ANY_SOURCE_STUCK=1
        return 1
    fi
    pick_free_path "$la" "$base" "$(stamp_from_epoch "$mtime")" "$h"
    cand=$PICKED

    if ! err=$(mv -f -- "$src" "$cand" 2>&1); then
        log_tgt ERROR SOURCE_STUCK relpath="$encrel" archive="$(enc "$cand")" err="$(enc "$err")" \
            hint="the file is deployed but could not be moved out of the pickup directory; it will be retried"
        (( CYC_ERRORS++ )); ANY_SOURCE_STUCK=1
        return 1
    fi
    ARC_PATH=$cand
    return 0
}

# pick_free_path <dir> <base> <stamp> <hash>
# Resolve <dir>/<base> to a path that is either free or already holds exactly
# this content, so the answer is a pure function of (base, stamp, hash) and every
# retry lands on the same place. Sets PICKED, and PICKED_EXISTS=1 when the chosen
# path already holds the content (nothing left to write).
PICKED=""
PICKED_EXISTS=0
pick_free_path() {
    local dir=$1 base=$2 stamp=$3 h=$4 stem ext cand
    PICKED=""; PICKED_EXISTS=0
    if [[ $base == ?*.* ]]; then stem=${base%.*}; ext=".${base##*.}"
    else stem=$base; ext=""; fi
    for cand in "$dir/$base" "$dir/${stem}_${stamp}${ext}" "$dir/${stem}_${stamp}_${h:0:8}${ext}"; do
        if [[ ! -e $cand ]]; then PICKED=$cand; return 0; fi
        if same_content "$cand" "$h"; then PICKED=$cand; PICKED_EXISTS=1; return 0; fi
    done
    # All three are taken by other content: fall back to the most specific one,
    # which by construction can only collide with identical content.
    PICKED="$dir/${stem}_${stamp}_${h:0:8}${ext}"
    return 0
}

# same_content <path> <hash>: true when <path> already holds exactly this content.
same_content() {
    local got
    got=$(hash_file "$1" 2>/dev/null) || return 1
    [[ $got == "$2" ]]
}

# stamp_from_epoch <epoch>: YYYYMMDD_HHMMSS for an mtime. Derived from the file
# rather than from the wall clock so an archive name is stable across retries.
stamp_from_epoch() {
    local e=$1 out
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )) && (( e >= 0 )); then
        printf '%(%Y%m%d_%H%M%S)T' "$e"
        return 0
    fi
    out=$(date -d "@$e" +%Y%m%d_%H%M%S 2>/dev/null) || out=$(ts_compact)
    printf '%s' "$out"
}

# process_file <src_root> <dep_root> <src_path>
# Move one source file: deploy it, then take it out of the pickup directory.
# Sets DIR_UNSETTLED=1 whenever the file could not be finalised, so the
# directory is rescanned next cycle.
#
# Ordering is the whole safety argument:
#   1. stability + hash   -- never touch a file that is still being written or
#                            that cannot be read back
#   2. deploy, verified   -- the remote/flaky side first, while the source is
#                            still intact and can be retried from
#   3. re-stat the source -- if it moved under us, what we deployed is a
#                            snapshot of a half-written file: keep the original
#   4. rename into the local archive -- the ONE irreversible step, and the last
# An interruption at any point leaves the file in the pickup directory, and the
# retry is a provable no-op in the deployment tree (identical bytes, identical
# name) followed by another rename attempt.
DIR_UNSETTLED=0
DEEP_SCAN=0        # 1 when this cycle ignores the directory-mtime skip
process_file() {
    local src_root=$1 dep_root=$2 src=$3
    local relpath encrel meta meta2 size mtime now age h err

    relpath=${src#"$src_root"/}
    encrel=$(enc "$relpath")

    meta=$(get_meta "$src") || {
        # File vanished between listing and stat.
        log_tgt WARN FILE_VANISHED relpath="$encrel"
        return 0
    }
    size=${meta%% *}; mtime=${meta##* }
    if ! is_uint "$size" || ! is_int "$mtime"; then
        _file_error "$encrel" META_UNREADABLE relpath="$encrel" meta="$(enc "$meta")"
        return 0
    fi

    (( CYC_SCANNED++ ))

    # Stability. With files written IN PLACE this is the upstream guard against
    # deploying, then moving away, a truncated file: while a writer is
    # appending, the mtime keeps moving and the age stays under the threshold.
    printf -v now '%(%s)T' -1 2>/dev/null || now=$(now_epoch); age=$(( now - mtime ))
    if (( age < MIN_STABLE_AGE )); then
        (( DEBUG_ON )) && log_tgt DEBUG SKIP_UNSTABLE relpath="$encrel" age_s="$age" min_stable_age="$MIN_STABLE_AGE"
        DIR_UNSETTLED=1
        return 0
    fi

    # Never consume what could not be read back.
    h=$(hash_file "$src") || {
        _file_error "$encrel$SEP$size$SEP$mtime" HASH_FAILED \
            relpath="$encrel" hash_cmd="$HASH_CMD"
        return 0
    }

    local base=${src##*/} pickup=${src%/*} la="" dst
    [[ -n $LOCAL_ARCHIVE_DIR ]] && la="$pickup/$LOCAL_ARCHIVE_DIR"
    dst="$dep_root/$relpath"

    if [[ $DRY_RUN == true ]]; then
        conflict_verdict "$dst" "$h" "$mtime"
        local wdep=""; [[ $VERDICT_DST != "$dst" ]] && wdep=$(enc "${VERDICT_DST#"$dep_root"/}")
        log_tgt INFO WOULD_MOVE relpath="$encrel" size="$size" \
            deploy="$VERDICT" deployed="$wdep" on_conflict="$ON_CONFLICT" \
            archive="$(enc "${la:+${la#"$src_root"/}/$base}")" \
            hash="${h:0:8}…" dry="1"
        (( CYC_DEPLOYED++ ))
        # The file has NOT been handled, so the directory still has work to do.
        # Without this the rehearsal would settle the directory, and the real
        # run right after would skip it on an unchanged mtime -- silently
        # deploying nothing, which is exactly the workflow the docs prescribe.
        DIR_UNSETTLED=1
        return 0
    fi

    # Birth time, for the report only: read it while the file is still here, and
    # accept that most filesystems (CIFS in particular) simply do not have one.
    local btime=0
    [[ -n $REPORT_DIR ]] && { btime=$(stat -c '%W' -- "$src" 2>/dev/null) || btime=0; }
    is_uint "$btime" || btime=0

    # 2. Deploy first: the source is still there to retry from if this fails.
    deploy_file "$src" "$dst" "$h" "$mtime" "$encrel" || { DIR_UNSETTLED=1; return 0; }

    # 3. The source must not have moved under us while we were copying. If it
    #    did, what we just deployed is a snapshot of a half-written file: leave
    #    the original in place and let the next cycle redo the whole thing.
    meta2=$(get_meta "$src") || {
        log_tgt WARN FILE_VANISHED relpath="$encrel" stage="post-deploy"
        return 0
    }
    if [[ $meta2 != "$meta" ]]; then
        log_tgt WARN SOURCE_CHANGED_DURING_COPY relpath="$encrel" \
            before="$(enc "$meta")" after="$(enc "$meta2")" \
            hint="the file was still being written; it was NOT moved and will be retried"
        DIR_UNSETTLED=1
        return 0
    fi

    # 4. The commit point: take the file out of the pickup directory.
    ARC_PATH=""
    if [[ -n $la ]]; then
        archive_source "$src" "$la" "$base" "$h" "$mtime" "$encrel" || { DIR_UNSETTLED=1; return 0; }
    else
        if ! err=$(rm -f -- "$src" 2>&1); then
            log_tgt ERROR SOURCE_STUCK relpath="$encrel" err="$(enc "$err")" \
                hint="the file is deployed but could not be removed; it will be retried"
            (( CYC_ERRORS++ )); ANY_SOURCE_STUCK=1; DIR_UNSETTLED=1
            return 0
        fi
    fi
    (( CYC_MOVED++ ))

    # Remember that this target has really written to its deployment root, so a
    # later run can tell "first deployment" from "the share vanished".
    if (( DEPLOYED_ONCE == 0 )); then
        DEPLOYED_ONCE=1
        : > "$STATE_DIR/deployed" 2>/dev/null
    fi

    local encarc=""; [[ -n $ARC_PATH ]] && encarc=$(enc "${ARC_PATH#"$src_root"/}")
    # Only name the deployed path when the policy made it differ from the mirror.
    local encdep=""; [[ $DEPLOY_DST != "$dst" ]] && encdep=$(enc "${DEPLOY_DST#"$dep_root"/}")
    case $DEPLOY_ACTION in
        DEPLOYED_OVERWRITE)
            audit_write "$DEPLOY_ACTION" "$encrel" "$encarc" "$h" "$size" "$DEPLOY_OLD_HASH"
            log_tgt INFO DEPLOYED_OVERWRITE relpath="$encrel" size="$size" \
                new_hash="${h:0:8}…" old_hash="${DEPLOY_OLD_HASH:0:8}…" archive="$encarc"
            report_row DEPLOYED_OVERWRITE "$src" "$DEPLOY_DST" "$ARC_PATH" "$relpath" \
                "$size" "$h" "$DEPLOY_OLD_HASH" "$mtime" "$btime" "$age" "$pickup"
            (( CYC_OVERWRITTEN++ )) ;;
        DEPLOYED_VERSION)
            audit_write "$DEPLOY_ACTION" "$encrel" "$encarc" "$h" "$size" "$DEPLOY_OLD_HASH"
            log_tgt INFO DEPLOYED_VERSION relpath="$encrel" size="$size" \
                hash="${h:0:8}…" deployed="$encdep" kept_hash="${DEPLOY_OLD_HASH:0:8}…" \
                archive="$encarc"
            report_row DEPLOYED_VERSION "$src" "$DEPLOY_DST" "$ARC_PATH" "$relpath" \
                "$size" "$h" "$DEPLOY_OLD_HASH" "$mtime" "$btime" "$age" "$pickup"
            (( CYC_DEPLOYED++ )) ;;
        DEPLOY_SKIPPED)
            # deploy_file already reported the collision at WARN; record that the
            # source was still drained.
            audit_write "$DEPLOY_ACTION" "$encrel" "$encarc" "$h" "$size" "$DEPLOY_OLD_HASH"
            report_row DEPLOY_SKIPPED "$src" "" "$ARC_PATH" "$relpath" \
                "$size" "$h" "$DEPLOY_OLD_HASH" "$mtime" "$btime" "$age" "$pickup" ;;
        *)
            audit_write "$DEPLOY_ACTION" "$encrel" "$encarc" "$h" "$size"
            log_tgt INFO "$DEPLOY_ACTION" relpath="$encrel" size="$size" \
                hash="${h:0:8}…" archive="$encarc"
            report_row "$DEPLOY_ACTION" "$src" "$DEPLOY_DST" "$ARC_PATH" "$relpath" \
                "$size" "$h" "" "$mtime" "$btime" "$age" "$pickup"
            (( CYC_DEPLOYED++ )) ;;
    esac
    (( CYC_BYTES += size ))
}

# scan_one_dir <leaf> <mt> <src_root> <dep_root> <root_dir>
# Process one directory: skip the local archive directory and anything matching
# EXCLUDE_DIR_PATTERNS (never the <root_dir> itself), skip it when its mtime is
# unchanged, otherwise move each file directly inside it (never deeper —
# recursion comes from the caller enumerating the dirs). Relative paths are
# computed against <src_root> and mirrored under <dep_root>. Uses the caller's
# locals (seen / scan_dirs / rescanned / cache_dirty) by dynamic scope.
scan_one_dir() {
    local leaf=$1 mt=$2 src_root=$3 dep_root=$4 root_dir=$5
    local base=${leaf##*/} f
    if [[ $leaf != "$root_dir" ]]; then
        # The local archive is our own output, never an input. Exact,
        # case-sensitive match so a directory called "archived" stays deployable.
        if [[ -n $LOCAL_ARCHIVE_DIR && $base == "$LOCAL_ARCHIVE_DIR" ]]; then
            (( DEBUG_ON )) && log_tgt DEBUG LOCAL_ARCHIVE_SKIPPED dir="$(enc "${leaf#"$src_root"/}")"
            return 0
        fi
        if is_excluded_dirname "$base"; then
            (( DEBUG_ON )) && log_tgt DEBUG EXCLUDED_DIR dir="$(enc "${leaf#"$src_root"/}")"
            return 0
        fi
    fi
    seen["$leaf"]=1
    (( scan_dirs++ ))
    # Files are MOVED out, so reading the directory is not enough: unlinking a
    # file needs w+x on its parent. Deploying from a directory we cannot then
    # clean would re-deploy the same files on every cycle, forever — so we skip
    # the whole directory rather than start something we cannot finish.
    if [[ ! -w $leaf || ! -x $leaf ]]; then
        # A directory that can never be drained needs an operator, not a retry:
        # it gets its own exit code so it cannot hide behind a green run.
        ANY_SOURCE_STUCK=1
        _file_error "$leaf" SOURCE_NOT_WRITABLE dir="$(enc "${leaf#"$src_root"/}")" \
            hint="files are moved out of the source: the pickup directory needs w+x"
        return 0
    fi
    if [[ $USE_DIR_MTIME_SKIP == true ]] && (( DEEP_SCAN == 0 )) && [[ ${DIRLAST["$leaf"]:-} == "$mt" ]]; then
        (( DEBUG_ON )) && log_tgt DEBUG SKIP_DIR_UNCHANGED dir="$(enc "${leaf#"$src_root"/}")" mtime="$mt"
        return 0
    fi
    (( rescanned++ ))
    (( DEBUG_ON )) && log_tgt DEBUG DIR_RESCAN dir="$(enc "${leaf#"$src_root"/}")" mtime="$mt" last="${DIRLAST["$leaf"]:-}"
    DIR_UNSETTLED=0
    while IFS= read -r -d '' f; do
        [[ -f $f ]] || continue
        process_file "$src_root" "$dep_root" "$f"
    done < <(find "$leaf" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
    # Settle (cache the mtime) only if everything finalised; otherwise leave the
    # previous value so the leaf is rescanned next cycle.
    if (( DIR_UNSETTLED == 0 )); then DIRLAST["$leaf"]=$mt; cache_dirty=1; fi
    return 0
}

# check_deploy_root <dep> <key>
# Make sure the deployment root is really there before anything is written to
# it -- and, above all, before anything is REMOVED from the source because of
# it. An unmounted deployment share is this tool's worst failure mode: mkdir -p
# happily populates the local mount point, every file is then moved out of the
# source, and when the share comes back the tree is empty and the sources are
# gone.
#
# The guard is a sentinel file at the deployment root ($DEPLOY_MARKER), which
# the script provisions itself so there is no manual step:
#
#   marker present                             -> ok
#   never deployed here yet                    -> bootstrap: create the marker
#   deployed before, root non-empty            -> adopt a pre-existing tree
#   deployed before, root missing or empty     -> REFUSE (the share is gone)
#
# "Deployed here before" is recorded by a per-target state file, written on the
# first successful move. Returns 0 (ok) or 1 (refuse).
check_deploy_root() {
    local dep=$1
    [[ -z $DEPLOY_MARKER ]] && return 0
    (( DEPLOY_CHECKED )) && return 0
    local marker="$dep/$DEPLOY_MARKER"
    if [[ -e $marker ]]; then DEPLOY_CHECKED=1; return 0; fi

    local deployed_before=0 nonempty=0 probe
    [[ -e "$STATE_DIR/deployed" ]] && deployed_before=1
    if [[ -d $dep ]]; then
        probe=$(find "$dep" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)
        [[ -n $probe ]] && nonempty=1
    fi

    if (( deployed_before && nonempty == 0 )); then
        log_tgt ERROR DEPLOY_UNAVAILABLE dep="$(enc "$dep")" marker="$(enc "$DEPLOY_MARKER")" \
            reason="marker missing and the deployment root is absent or empty, although this target has deployed here before" \
            hint="the share looks unmounted -- nothing was written and nothing was removed from the source. Mount it, or recreate the marker file if the tree really was emptied or moved."
        return 1
    fi

    if [[ $DRY_RUN == true ]]; then
        log_tgt INFO DEPLOY_MARKER_MISSING dep="$(enc "$dep")" dry="1"
        DEPLOY_CHECKED=1
        return 0
    fi
    if ! mkdir -p -- "$dep" 2>/dev/null || ! { : > "$marker"; } 2>/dev/null; then
        log_tgt ERROR DEPLOY_UNAVAILABLE dep="$(enc "$dep")" marker="$(enc "$DEPLOY_MARKER")" \
            reason="cannot create the marker file at the deployment root" \
            hint="check that the deployment root exists and is writable"
        return 1
    fi
    if (( deployed_before )); then
        log_tgt WARN DEPLOY_MARKER_ADOPTED dep="$(enc "$dep")" marker="$(enc "$DEPLOY_MARKER")" \
            hint="pre-existing tree adopted; the marker now guards it against an unmounted share"
    else
        log_tgt INFO DEPLOY_MARKER_CREATED dep="$(enc "$dep")" marker="$(enc "$DEPLOY_MARKER")"
    fi
    DEPLOY_CHECKED=1
    return 0
}

# ---------------------------------------------------------------------------
# scan_cycle <idx>: one cycle over a single target.
# ---------------------------------------------------------------------------
CYC_SCANNED=0 CYC_DEPLOYED=0 CYC_OVERWRITTEN=0 CYC_CONFLICTS=0 CYC_MOVED=0 CYC_ERRORS=0 CYC_BYTES=0
scan_cycle() {
    local src=$SOURCE_DIR dep=$DEPLOY_DIR idn=$INPUT_DIR_NAME
    local inputs_cache="$STATE_DIR/inputs.tsv"
    local leaves_cache="$STATE_DIR/leaves.tsv"

    log_tgt DEBUG CYCLE_BEGIN src="$(enc "$src")" deploy="$(enc "$dep")" input_dir_name="$idn"

    # Guard: the source must be an existing, readable, searchable, writable
    # directory. A precise reason plus the deepest existing ancestor makes an
    # unmounted share or a wrong path immediately obvious.
    local mreason; mreason=$(mount_reason "$src")
    if [[ $mreason != ok ]]; then
        local anc; anc=$(deepest_existing "$src")
        local lvl=DEBUG; [[ $MOUNT_STATE != missing ]] && lvl=ERROR  # loud on change
        MOUNT_STATE=missing
        _emit_file "$CUR_OPLOG" 1 "$lvl" MOUNT_MISSING \
            "src=$(enc "$src")" "reason=$mreason" "deepest_existing=$(enc "$anc")"
        return 0
    fi
    [[ $MOUNT_STATE == missing ]] && log_tgt INFO MOUNT_OK src="$(enc "$src")"
    MOUNT_STATE=ok
    SOURCE_OK=1

    # The deployment tree must really be mounted before a single byte is
    # written -- and, above all, before a single file is taken out of the source
    # because of it.
    if ! check_deploy_root "$dep"; then
        RUN_ERRORS=$(( RUN_ERRORS + 1 ))
        ANY_DEPLOY_FAILED=1
        return 0
    fi

    # Periodic deep pass: ignore the directory-mtime skip every
    # DEEP_SCAN_INTERVAL seconds. This is belt-and-braces -- a processed file no
    # longer exists, and any file left behind already keeps its directory
    # unsettled (see _file_error) -- but it still recovers a directory whose
    # mtime the share failed to update. The timestamp lives in a state file so
    # cron re-invocations do not each force a deep pass.
    local deep_marker="$STATE_DIR/deepscan" nowd dmt
    nowd=$(now_epoch)
    DEEP_SCAN=0
    if (( FORCE_REDISCOVER )); then
        DEEP_SCAN=1
    elif (( DEEP_SCAN_INTERVAL > 0 )); then
        dmt=0
        if [[ -f $deep_marker ]]; then dmt=$(get_mtime "$deep_marker"); is_uint "$dmt" || dmt=0; fi
        (( nowd - dmt >= DEEP_SCAN_INTERVAL )) && DEEP_SCAN=1
    fi
    if (( DEEP_SCAN )); then
        [[ $DRY_RUN == true ]] || : > "$deep_marker" 2>/dev/null
        (( DEBUG_ON )) && log_tgt DEBUG DEEP_SCAN interval_s="$DEEP_SCAN_INTERVAL"
    fi

    discover_or_load_dirs "$src" "$idn" "$inputs_cache" "$leaves_cache"

    CYC_SCANNED=0 CYC_DEPLOYED=0 CYC_OVERWRITTEN=0 CYC_CONFLICTS=0 CYC_MOVED=0 CYC_ERRORS=0 CYC_BYTES=0
    local -A seen=()
    local input mt leaf dir_reads=0 scan_dirs=0 rescanned=0 cache_dirty=0
    local t_start; t_start=$(date +%s%N 2>/dev/null)

    # One bulk readdir per input dir returns the input AND each of its direct
    # subdirs with their mtime in a single directory read (~1 CIFS round-trip),
    # instead of one stat per directory. We then scan the input's direct files and
    # each direct subdir's direct files (never deeper).
    for input in "${INPUT_DIRS[@]:-}"; do
        [[ -z $input ]] && continue
        (( dir_reads++ ))
        while IFS=$'\t' read -r -d '' mt leaf; do
            [[ -z $leaf ]] && continue
            scan_one_dir "$leaf" "$mt" "$src" "$dep" "$input"
        done < <(find "$input" -mindepth 0 -maxdepth 1 -type d -printf '%T@\t%p\0' 2>/dev/null)
    done

    # Persist settled mtimes for the leaves seen this cycle (only when something
    # changed; this also drops leaves that disappeared).
    local tmp="$leaves_cache.tmp.$$" lf
    if (( cache_dirty )) && [[ $DRY_RUN != true ]] &&
       printf '%s\n' "$LEAVES_CACHE_VERSION" > "$tmp" 2>/dev/null; then
        for lf in "${!seen[@]}"; do
            [[ -n ${DIRLAST["$lf"]:-} ]] || continue
            enc_r "$lf"; printf '%s\t%s\n' "$REPLY" "${DIRLAST["$lf"]}" >> "$tmp"
        done
        mv -f -- "$tmp" "$leaves_cache"
    fi

    RUN_DEPLOYED=$(( RUN_DEPLOYED + CYC_DEPLOYED ))
    RUN_OVERWRITTEN=$(( RUN_OVERWRITTEN + CYC_OVERWRITTEN ))
    RUN_CONFLICTS=$(( RUN_CONFLICTS + CYC_CONFLICTS ))
    RUN_MOVED=$(( RUN_MOVED + CYC_MOVED ))
    RUN_ERRORS=$(( RUN_ERRORS + CYC_ERRORS ))
    RUN_SCANNED=$(( RUN_SCANNED + CYC_SCANNED ))

    # Per-cycle detail is DEBUG (it happens every SCAN_INTERVAL); INFO summaries
    # come from HEARTBEAT and the final RUN_SUMMARY.
    local t_end dur_ms=0; t_end=$(date +%s%N 2>/dev/null)
    [[ $t_start =~ ^[0-9]+$ && $t_end =~ ^[0-9]+$ ]] && dur_ms=$(( (t_end - t_start) / 1000000 ))
    log_tgt DEBUG CYCLE_SUMMARY dir_reads="$dir_reads" scan_dirs="$scan_dirs" rescanned="$rescanned" \
        scanned="$CYC_SCANNED" deployed="$CYC_DEPLOYED" overwritten="$CYC_OVERWRITTEN" \
        conflicts="$CYC_CONFLICTS" moved="$CYC_MOVED" errors="$CYC_ERRORS" \
        bytes_deployed="$CYC_BYTES" dur_ms="$dur_ms"
}

# ---------------------------------------------------------------------------
# Config / CLI
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: file-deploy.sh [--config FILE] [--dry-run] [--once] [--debug] [--verbose]
                      [--rediscover] [--help]

Moves files from "input" directories under SOURCE_DIR into a mirror deployment
tree at DEPLOY_DIR, keeping a local archive copy behind in the source. One
configuration file describes one such pair; run it once per pair. See README.md.

WARNING: this tool DELETES from the source. Rehearse with --dry-run first.

  --config FILE  Use this configuration file (default: <script dir>/file-deploy.conf).
                 Its INSTANCE_ID is what the state, log and lock paths hang off,
                 so two configurations never collide.
  --rediscover   Request an immediate rediscovery of the input directories:
                 drops a marker the running scanner picks up next cycle. Exits
                 right away without scanning.
  --debug        Maximum verbosity: LOG_LEVEL=DEBUG and mirror every line to the
                 terminal. Great for finding why nothing is being deployed.
  --once         Do a single scan pass and exit (RUN_DURATION=0), instead of the
                 continuous loop. Combine with --debug to diagnose quickly.
  --dry-run, -n  Rehearse: log a WOULD_MOVE line per file with the deployment
                 verdict and the archive path, without writing or deleting
                 anything. Same as DRY_RUN=true, but without editing the config
                 (and without the risk of leaving it on afterwards).
  --verbose      Mirror log lines to the terminal (without changing the level).
  --help         Show this help.
EOF
}

parse_args() {
    while (( $# )); do
        case $1 in
            --config)
                if (( $# < 2 )); then
                    printf 'Missing value for --config\n' >&2; usage >&2; exit $EX_CONFIG
                fi
                CONFIG_FILE=$2; shift 2 ;;
            --config=*) CONFIG_FILE=${1#*=}; shift ;;
            --rediscover) ACTION="rediscover"; shift ;;
            --debug) FORCE_DEBUG=1; shift ;;
            --once) ONCE=1; shift ;;
            --dry-run|-n) FORCE_DRY=1; shift ;;
            --verbose|-v) FORCE_CONSOLE="always"; shift ;;
            -h|--help) usage; exit $EX_OK ;;
            *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit $EX_CONFIG ;;
        esac
    done
}

load_config() {
    CONFIG_STATUS="none"
    if [[ -n $CONFIG_FILE ]]; then
        if [[ -f $CONFIG_FILE ]]; then
            if [[ ! -r $CONFIG_FILE ]]; then
                printf 'Config file not readable: %s\n' "$CONFIG_FILE" >&2
                exit $EX_CONFIG
            fi
            # shellcheck disable=SC1090
            source "$CONFIG_FILE"
            CONFIG_STATUS="loaded"
        else
            CONFIG_STATUS="missing"
        fi
    fi
    # CLI overrides applied last so they always win. --verbose goes through
    # FORCE_CONSOLE for exactly that reason: setting LOG_CONSOLE in parse_args
    # let a config file silently override the flag.
    if (( FORCE_DEBUG )); then LOG_LEVEL="DEBUG"; LOG_CONSOLE="always"; fi
    if (( ONCE )); then RUN_DURATION=0; fi
    if (( FORCE_DRY )); then DRY_RUN=true; fi
    case ${ON_CONFLICT,,} in
        overwrite|version|skip|retry|fail) ON_CONFLICT=${ON_CONFLICT,,} ;;
        *) printf 'Invalid ON_CONFLICT: %s (expected overwrite, version, skip, retry or fail)\n' \
               "$ON_CONFLICT" >&2
           exit $EX_CONFIG ;;
    esac
    [[ -n $FORCE_CONSOLE ]] && LOG_CONSOLE=$FORCE_CONSOLE
    # The identity comes first: the state, log and lock paths hang off it, which
    # is what makes it impossible for two configurations to share them.
    if [[ -z $INSTANCE_ID ]]; then
        INSTANCE_ID=${CONFIG_FILE##*/}
        INSTANCE_ID=${INSTANCE_ID%.conf}
        [[ -z $INSTANCE_ID ]] && INSTANCE_ID="file-deploy"
    fi
    if [[ ! $INSTANCE_ID =~ ^[A-Za-z0-9._-]+$ ]]; then
        printf 'Invalid INSTANCE_ID: %s (allowed: letters, digits, . _ -)\n' "$INSTANCE_ID" >&2
        exit $EX_CONFIG
    fi
    [[ -z $STATE_DIR ]] && STATE_DIR="$SCRIPT_DIR/state/$INSTANCE_ID"
    [[ -z $LOG_DIR   ]] && LOG_DIR="$SCRIPT_DIR/logs/$INSTANCE_ID"
    [[ -z $LOCK_FILE ]] && LOCK_FILE="$SCRIPT_DIR/run-$INSTANCE_ID.lock"

    if [[ -z $SOURCE_DIR || -z $DEPLOY_DIR ]]; then
        printf 'SOURCE_DIR and DEPLOY_DIR must both be set in %s\n' "$CONFIG_FILE" >&2
        exit $EX_CONFIG
    fi
    # Trailing slashes would break every relative-path computation.
    while [[ $SOURCE_DIR == */ && ${#SOURCE_DIR} -gt 1 ]]; do SOURCE_DIR=${SOURCE_DIR%/}; done
    while [[ $DEPLOY_DIR == */ && ${#DEPLOY_DIR} -gt 1 ]]; do DEPLOY_DIR=${DEPLOY_DIR%/}; done

    LOG_LEVEL_NUM=${LVLNUM[$LOG_LEVEL]:-20}
    (( LOG_LEVEL_NUM <= 10 )) && DEBUG_ON=1 || DEBUG_ON=0
    case ${LOG_CONSOLE,,} in
        always|1|true|yes|on) CONSOLE_ON=1 ;;
        never|0|false|no|off) CONSOLE_ON=0 ;;
        *) [[ -t 2 ]] && CONSOLE_ON=1 || CONSOLE_ON=0 ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    load_config

    mkdir -p -- "$STATE_DIR" "$LOG_DIR" 2>/dev/null
    # One configuration, one instance: orchestration and per-file events share a
    # single log. There is no second target to keep them apart from.
    RUN_LOG="$LOG_DIR/file-deploy.log"
    CUR_OPLOG=$RUN_LOG
    CUR_AUDIT="$LOG_DIR/audit.log"
    CUR_INSTANCE=$INSTANCE_ID
    RUN_ID="$(ts_compact)-$$"
    FORCE_MARKER="$STATE_DIR/.force-rediscover"

    # --rediscover: just drop the marker and exit; the running scanner (or the
    # next cron run) forces a full-tree rediscovery on its next cycle.
    if [[ $ACTION == rediscover ]]; then
        if : > "$FORCE_MARKER" 2>/dev/null; then
            log_run INFO FORCE_REDISCOVER_REQUESTED marker="$(enc "$FORCE_MARKER")"
            printf 'Rediscovery requested; it will be applied on the next scan cycle.\n'
            exit $EX_OK
        fi
        printf 'Cannot create marker file: %s\n' "$FORCE_MARKER" >&2
        exit $EX_CONFIG
    fi

    # Single-instance lock. The default lock path carries INSTANCE_ID, so two
    # configurations run concurrently instead of silently serialising.
    exec 9> "$LOCK_FILE" || { printf 'Cannot open lock file: %s\n' "$LOCK_FILE" >&2; exit $EX_CONFIG; }
    if ! flock -n 9; then
        # Expected every minute in continuous mode (the cron watchdog finds the
        # loop already running), so log at DEBUG to avoid noise.
        log_run DEBUG LOCK_BUSY lock="$(enc "$LOCK_FILE")"
        exit $EX_LOCKED
    fi

    # A state directory belongs to exactly one instance. The default paths make
    # a clash impossible, but STATE_DIR can be overridden -- and two
    # configurations sharing one would silently mix their caches and their
    # "already deployed here" marker, so refuse instead.
    local owner_file="$STATE_DIR/.instance" owner=""
    [[ -f $owner_file ]] && IFS= read -r owner < "$owner_file"
    if [[ -n $owner && $owner != "$INSTANCE_ID" ]]; then
        log_run ERROR STATE_DIR_CONFLICT state_dir="$(enc "$STATE_DIR")" \
            owner="$(enc "$owner")" instance="$(enc "$INSTANCE_ID")" \
            hint="this state directory belongs to another configuration; give each one its own INSTANCE_ID or its own STATE_DIR"
        exit $EX_CONFIG
    fi
    [[ -n $owner ]] || printf '%s\n' "$INSTANCE_ID" > "$owner_file" 2>/dev/null

    # --- Startup banner (shown on the console when interactive) ---
    log_run INFO START pid="$$" host="${HOSTNAME:-$(uname -n 2>/dev/null)}" \
        user="$(id -un 2>/dev/null)" bash="$BASH_VERSION" instance="$INSTANCE_ID"
    log_run INFO PATHS script_dir="$(enc "$SCRIPT_DIR")" config="$(enc "$CONFIG_FILE")" \
        config_status="$CONFIG_STATUS" state_dir="$(enc "$STATE_DIR")" \
        log_dir="$(enc "$LOG_DIR")" lock="$(enc "$LOCK_FILE")"
    log_run INFO CONFIG source_dir="$(enc "$SOURCE_DIR")" deploy_dir="$(enc "$DEPLOY_DIR")" \
        input_dir_name="$INPUT_DIR_NAME" scan_interval="$SCAN_INTERVAL" \
        run_duration="$RUN_DURATION" min_stable_age="$MIN_STABLE_AGE" \
        discovery_interval="$DISCOVERY_INTERVAL" discovery_maxdepth="$DISCOVERY_MAXDEPTH" \
        use_dir_mtime_skip="$USE_DIR_MTIME_SKIP" deep_scan_interval="$DEEP_SCAN_INTERVAL" \
        deploy_marker="$(enc "$DEPLOY_MARKER")" local_archive_dir="$(enc "$LOCAL_ARCHIVE_DIR")" \
        hash_cmd="$HASH_CMD" dry_run="$DRY_RUN" on_conflict="$ON_CONFLICT" \
        report_dir="$(enc "$REPORT_DIR")" \
        exclude_patterns="$(enc "${EXCLUDE_DIR_PATTERNS[*]:-}")" \
        log_format="$LOG_FORMAT" log_level="$LOG_LEVEL" console="$LOG_CONSOLE"
    [[ $CONFIG_STATUS == missing ]] && log_run WARN CONFIG_NOT_FOUND config="$(enc "$CONFIG_FILE")" \
        hint="config file not found; running with built-in defaults"
    # A rehearsal left switched on looks exactly like a healthy run that never
    # delivers anything, so say it loudly enough to show up in monitoring.
    [[ $DRY_RUN == true ]] && log_run WARN DRY_RUN_ACTIVE \
        source="$( (( FORCE_DRY )) && printf -- '--dry-run' || printf 'config' )" \
        hint="nothing will be written or deleted; unset DRY_RUN to deliver"

    if [[ -n $REPORT_DIR ]] && ! mkdir -p -- "$REPORT_DIR" 2>/dev/null; then
        log_run ERROR REPORT_DIR_UNUSABLE dir="$(enc "$REPORT_DIR")" \
            hint="cannot create the CSV report directory; reporting is disabled for this run"
        REPORT_DIR=""
    fi

    local tick=$SCAN_INTERVAL; (( tick < 1 )) && tick=1
    local cycle=0 first=1 now last_hb=0
    while (( first || SECONDS < RUN_DURATION )); do
        first=0
        (( cycle++ ))
        CUR_CYCLE=$cycle
        # Manual rediscovery request (marker dropped by `--rediscover`).
        if [[ -e $FORCE_MARKER ]]; then
            FORCE_REDISCOVER=1
            rm -f -- "$FORCE_MARKER" 2>/dev/null
            log_run INFO FORCE_REDISCOVER cycle="$cycle"
        else
            FORCE_REDISCOVER=0
        fi
        now=$(now_epoch)
        scan_cycle

        # Periodic heartbeat: proves the loop is alive and shows, at a glance,
        # whether it is delivering or stuck.
        if (( HEARTBEAT_INTERVAL > 0 )) && (( now - last_hb >= HEARTBEAT_INTERVAL )); then
            last_hb=$now
            log_run INFO HEARTBEAT cycle="$cycle" elapsed_s="$SECONDS" \
                moved="$RUN_MOVED" errors="$RUN_ERRORS" mount="${MOUNT_STATE:-unknown}"
        fi

        (( SECONDS < RUN_DURATION )) || break
        sleep "$tick"
    done
    CUR_CYCLE=""

    log_run INFO RUN_SUMMARY cycles="$cycle" scanned="$RUN_SCANNED" \
        deployed="$RUN_DEPLOYED" overwritten="$RUN_OVERWRITTEN" conflicts="$RUN_CONFLICTS" \
        moved="$RUN_MOVED" errors="$RUN_ERRORS" mount="${MOUNT_STATE:-unknown}"
    log_run INFO END

    # Exit code precedence: unusable source > deploy failure > source stuck.
    # Undelivered data outranks delivered-but-not-drained.
    if (( SOURCE_OK == 0 )); then
        exit $EX_NOSOURCE
    elif (( ANY_DEPLOY_FAILED )); then
        exit $EX_DEPLOY
    elif (( ANY_SOURCE_STUCK )); then
        exit $EX_SOURCE
    fi
    exit $EX_OK
}

main "$@"
