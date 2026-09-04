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
#   - Several targets (project x environment) are described in targets.tsv.
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
readonly EX_CONFIG=1    # configuration error (config / targets unreadable)
readonly EX_NOTARGET=2  # no usable target (all sources missing/unreadable)
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
EXTRA_DIRS=()          # explicit "label<TAB>source<TAB>destination<TAB>depth" rules (see file-deploy.conf.example)

# Resolve the script directory portably (no readlink -f).
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

# Path defaults derived from the script directory (may be overridden in config).
TARGETS_FILE="$SCRIPT_DIR/targets.tsv"
STATE_DIR="$SCRIPT_DIR/state"
LOG_DIR="$SCRIPT_DIR/logs"
LOCK_FILE="$SCRIPT_DIR/run.lock"

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

# Current target context (set by scan_target, empty at orchestration level).
CUR_PROJECT=""
CUR_ENV=""
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
        if (( withctx )) && [[ -n $CUR_PROJECT ]]; then
            line+=",\"project\":\"$(json_esc "$CUR_PROJECT")\",\"env\":\"$(json_esc "$CUR_ENV")\""
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
        if (( withctx )) && [[ -n $CUR_PROJECT ]]; then
            line+=" project=$CUR_PROJECT env=$CUR_ENV"
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
# Targets
# ---------------------------------------------------------------------------
declare -a T_PROJECT=() T_ENV=() T_SRC=() T_DEP=() T_IDN=() T_SCAN=() T_KEY=() T_LAST=()
declare -a T_MODE=() T_DEPTH=()   # per-target: mode "input"|"fixed"; depth (fixed only, -1=unlimited)
declare -A _seen_target=()
declare -A T_MOUNT_STATE=()   # key -> "ok" | "missing" (for state-change logging)
declare -A DEPLOY_CHECKED=()  # key -> 1 once the deployment root has been validated
declare -A DEPLOYED_ONCE=()   # key -> 1 once the "we have deployed here" file exists

# load_targets: parse targets.tsv into the T_* arrays. Returns EX_CONFIG on a
# fatal read error.
load_targets() {
    if [[ ! -f $TARGETS_FILE || ! -r $TARGETS_FILE ]]; then
        log_run ERROR TARGETS_UNREADABLE file="$(enc "$TARGETS_FILE")"
        return $EX_CONFIG
    fi
    local raw c1 c2 c3 c4 c5 c6 c7 rest
    local project env src arc idn scan enabled key
    local lineno=0
    while IFS= read -r raw || [[ -n $raw ]]; do
        (( lineno++ ))
        # Skip blank and comment lines.
        local t; t=$(trim "$raw")
        [[ -z $t ]] && continue
        [[ $t == \#* ]] && continue
        # Tab-separated when a tab is present (paths may contain spaces),
        # otherwise fall back to whitespace-separated for convenience.
        if [[ $raw == *$'\t'* ]]; then
            IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 c7 rest <<< "$raw"
        else
            read -r c1 c2 c3 c4 c5 c6 c7 rest <<< "$raw"
        fi
        project=$(trim "${c1:-}"); env=$(trim "${c2:-}")
        src=$(trim "${c3:-}");     arc=$(trim "${c4:-}")
        idn=$(trim "${c5:-}");     scan=$(trim "${c6:-}"); enabled=$(trim "${c7:-}")

        if [[ -z $project || -z $env || -z $src || -z $arc ]]; then
            log_run WARN TARGET_MALFORMED line_no="$lineno" line="$(enc "$t")"
            continue
        fi
        # Resolve optional columns / defaults.
        [[ -z $idn || $idn == - ]] && idn=$INPUT_DIR_NAME
        [[ -z $scan || $scan == - ]] && scan=$SCAN_INTERVAL
        [[ -z $enabled || $enabled == - ]] && enabled=true
        # Extra columns almost always mean the line was split on whitespace
        # because it has no tab, so every column after a value containing a
        # space is shifted -- which used to disable the target in silence.
        if [[ -n ${rest:-} ]]; then
            log_run WARN TARGET_EXTRA_FIELDS project="$project" env="$env" line_no="$lineno" \
                extra="$(enc "$rest")" hint="more than 7 columns; are the columns TAB-separated?"
        fi
        if ! is_uint "$scan"; then
            log_run WARN TARGET_BAD_INTERVAL project="$project" env="$env" scan_interval="$(enc "$scan")"
            scan=$SCAN_INTERVAL
        fi
        (( scan < 1 )) && scan=1

        key="$(sanitize "$project")__$(sanitize "$env")"
        if [[ -n ${_seen_target[$key]:-} ]]; then
            log_run ERROR TARGET_DUPLICATE project="$project" env="$env" line_no="$lineno"
            continue
        fi
        _seen_target[$key]=1

        case ${enabled,,} in
            true|yes|on|1)  enabled=true ;;
            false|no|off|0)
                log_run DEBUG TARGET_DISABLED project="$project" env="$env" enabled="$(enc "$enabled")"
                continue ;;
            *)  # Never drop a target on an unparsable flag without saying so.
                log_run WARN TARGET_BAD_ENABLED project="$project" env="$env" line_no="$lineno" \
                    enabled="$(enc "$enabled")" \
                    hint="last column must be true/false; target skipped. Are the columns TAB-separated?"
                continue ;;
        esac
        T_PROJECT+=("$project"); T_ENV+=("$env")
        T_SRC+=("$src");         T_DEP+=("$arc")
        T_IDN+=("$idn");         T_SCAN+=("$scan")
        T_KEY+=("$key");         T_LAST+=(0)
        T_MODE+=("input");       T_DEPTH+=("-")
    done < "$TARGETS_FILE"
    return 0
}

# load_extra_dirs: append the EXTRA_DIRS rules as "fixed" targets. Each rule
# (label<TAB>source<TAB>destination<TAB>depth) archives one specific source
# directory to one specific destination — no "input" discovery, a mirror rooted
# at <destination>: <source>/sub/f -> <destination>/sub/f. Its <label> is its
# identity: its state and logs live under "<label>__extra", exactly like a
# (project, env) target, so the whole engine is reused unchanged.
#   depth: 0 = files directly in <source> only; N = N sub-levels deep;
#          -1 / "unlimited" = the whole subtree. Empty/"-" defaults to 1.
load_extra_dirs() {
    local entry label src dst depth key san n=0
    for entry in "${EXTRA_DIRS[@]:-}"; do
        [[ -z $entry ]] && continue
        (( n++ ))
        IFS=$'\t' read -r label src dst depth <<< "$entry"
        label=$(trim "${label:-}"); src=$(trim "${src:-}")
        dst=$(trim "${dst:-}");     depth=$(trim "${depth:-}")
        # Trailing slashes would break the relative-path computation.
        while [[ $src == */ ]]; do src=${src%/}; done
        while [[ $dst == */ ]]; do dst=${dst%/}; done
        if [[ -z $label || -z $src || -z $dst ]]; then
            log_run WARN EXTRA_MALFORMED index="$n" entry="$(enc "$entry")" \
                hint="expected label<TAB>source<TAB>destination<TAB>depth"
            continue
        fi
        case ${depth,,} in
            ''|-) depth=1 ;;
            unlimited|inf|all|-1) depth=-1 ;;
            *) if ! is_uint "$depth"; then
                   log_run WARN EXTRA_BAD_DEPTH label="$(enc "$label")" depth="$(enc "$depth")" \
                       hint="depth must be 0, a positive integer, or -1/unlimited; using 1"
                   depth=1
               fi ;;
        esac
        san=$(sanitize "$label"); key="${san}__extra"
        if [[ -n ${_seen_target[$key]:-} ]]; then
            log_run ERROR EXTRA_DUPLICATE label="$(enc "$label")" key="$key" index="$n"
            continue
        fi
        _seen_target[$key]=1
        T_PROJECT+=("$label"); T_ENV+=("extra")
        T_SRC+=("$src");       T_DEP+=("$dst")
        T_IDN+=("");           T_SCAN+=("$SCAN_INTERVAL")
        T_KEY+=("$key");       T_LAST+=(0)
        T_MODE+=("fixed");     T_DEPTH+=("$depth")
    done
    return 0
}

# ---------------------------------------------------------------------------
# Discovery (locate input dirs) + per-leaf settled mtimes
#   STATE_DIR/<key>.inputs.tsv  -> one enc(input_dir) per line (governs rediscovery)
#   STATE_DIR/<key>.leaves.tsv  -> "<enc(leaf)>\t<settled_mtime>" (per-leaf skip state)
# ---------------------------------------------------------------------------

# discover_or_load_dirs <key> <src> <idn> <inputs_cache> <leaves_cache>
# Populates INPUT_DIRS (the input directories) and DIRLAST (leaf -> settled mtime).
# The full-tree walk (rediscovery) only LOCATES input dirs: it prunes AT each input
# (never descends into them) and honours DISCOVERY_MAXDEPTH / EXCLUDE_DIR_PATTERNS,
# so it does not walk the (large) subtrees. Sub-directories are enumerated cheaply
# per cycle in scan_target (one bulk readdir per input).
declare -a INPUT_DIRS=()
declare -A DIRLAST=()
declare -a IDNAMES=()

# split_idn <list>: split the configured input directory names into IDNAMES.
# ONLY commas (and newlines) separate. A whitespace split would silently make
# every name containing a space unusable -- and NAS shares routinely have them,
# which is also why targets.tsv is tab-separated in the first place.
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
    local key=$1 src=$2 idn=$3 inputs_cache=$4 leaves_cache=$5
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
ANY_TARGET_OK=0
ANY_DEPLOY_FAILED=0   # something could not be written to the deployment tree -> exit 4
ANY_SOURCE_STUCK=0    # something was deployed but could not leave the source -> exit 5
declare -A RUN_DEPLOYED=() RUN_OVERWRITTEN=() RUN_MOVED=() RUN_ERRORS=() RUN_SCANNED=()

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

# deploy_file <src> <dst> <hash> <encrel>
# Put the file in the deployment tree. Sets DEPLOY_ACTION to DEPLOYED,
# DEPLOYED_OVERWRITE (with DEPLOY_OLD_HASH) or DEPLOYED_IDENTICAL. The
# deployment tree holds the CURRENT state, so changed content overwrites in
# place -- history lives in the local archive, not here. Returns 1 (and logs)
# on failure, always leaving whatever was already deployed untouched.
DEPLOY_ACTION=""
DEPLOY_OLD_HASH=""
deploy_file() {
    local src=$1 dst=$2 h=$3 encrel=$4 err old dst_dir=${2%/*}
    DEPLOY_ACTION=DEPLOYED; DEPLOY_OLD_HASH=""
    if ! err=$(mkdir -p -- "$dst_dir" 2>&1); then
        log_tgt ERROR DEPLOY_FAILED stage="mkdir" relpath="$encrel" \
            dst_dir="$(enc "$dst_dir")" err="$(enc "$err")"
        (( CYC_ERRORS++ )); ANY_DEPLOY_FAILED=1
        return 1
    fi
    if [[ -f $dst ]]; then
        old=$(hash_file "$dst" 2>/dev/null) || old=""
        if [[ -n $old && $old == "$h" ]]; then
            # Already deployed byte for byte. Nothing to write -- but the source
            # file must still be archived and removed, so this is NOT a skip.
            DEPLOY_ACTION=DEPLOYED_IDENTICAL
            return 0
        fi
        DEPLOY_ACTION=DEPLOYED_OVERWRITE; DEPLOY_OLD_HASH=$old
    fi
    if ! atomic_copy "$src" "$dst" "$h"; then
        log_tgt ERROR DEPLOY_FAILED stage="$COPY_STAGE" relpath="$encrel" \
            dst="$(enc "$dst")" err="$(enc "$COPY_ERR")"
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
    local err existing stamp stem ext cand
    ARC_PATH=""
    if ! err=$(mkdir -p -- "$la" 2>&1); then
        log_tgt ERROR ARCHIVE_DIR_FAILED relpath="$encrel" dir="$(enc "$la")" err="$(enc "$err")"
        (( CYC_ERRORS++ )); ANY_SOURCE_STUCK=1
        return 1
    fi
    if [[ $base == ?*.* ]]; then stem=${base%.*}; ext=".${base##*.}"
    else stem=$base; ext=""; fi
    stamp=$(stamp_from_epoch "$mtime")

    cand="$la/$base"
    if [[ -e $cand ]] && ! same_content "$cand" "$h"; then
        cand="$la/${stem}_${stamp}${ext}"
        if [[ -e $cand ]] && ! same_content "$cand" "$h"; then
            cand="$la/${stem}_${stamp}_${h:0:8}${ext}"
        fi
    fi

    if ! err=$(mv -f -- "$src" "$cand" 2>&1); then
        log_tgt ERROR SOURCE_STUCK relpath="$encrel" archive="$(enc "$cand")" err="$(enc "$err")" \
            hint="the file is deployed but could not be moved out of the pickup directory; it will be retried"
        (( CYC_ERRORS++ )); ANY_SOURCE_STUCK=1
        return 1
    fi
    ARC_PATH=$cand
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

# process_file <key> <src_root> <dep_root> <src_path>
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
    local key=$1 src_root=$2 dep_root=$3 src=$4
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
        _file_error "$key$SEP$encrel" META_UNREADABLE relpath="$encrel" meta="$(enc "$meta")"
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
        _file_error "$key$SEP$encrel$SEP$size$SEP$mtime" HASH_FAILED \
            relpath="$encrel" hash_cmd="$HASH_CMD"
        return 0
    }

    local base=${src##*/} pickup=${src%/*} la="" dst
    [[ -n $LOCAL_ARCHIVE_DIR ]] && la="$pickup/$LOCAL_ARCHIVE_DIR"
    dst="$dep_root/$relpath"

    if [[ $DRY_RUN == true ]]; then
        local would=DEPLOYED
        if [[ -f $dst ]]; then
            if same_content "$dst" "$h"; then would=DEPLOYED_IDENTICAL; else would=DEPLOYED_OVERWRITE; fi
        fi
        log_tgt INFO WOULD_MOVE relpath="$encrel" size="$size" \
            deploy="$would" archive="$(enc "${la:+${la#"$src_root"/}/$base}")" \
            hash="${h:0:8}…" dry="1"
        (( CYC_DEPLOYED++ ))
        # The file has NOT been handled, so the directory still has work to do.
        # Without this the rehearsal would settle the directory, and the real
        # run right after would skip it on an unchanged mtime -- silently
        # deploying nothing, which is exactly the workflow the docs prescribe.
        DIR_UNSETTLED=1
        return 0
    fi

    # 2. Deploy first: the source is still there to retry from if this fails.
    deploy_file "$src" "$dst" "$h" "$encrel" || { DIR_UNSETTLED=1; return 0; }

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
    if [[ -z ${DEPLOYED_ONCE[$key]:-} ]]; then
        DEPLOYED_ONCE[$key]=1
        : > "$STATE_DIR/$key.deployed" 2>/dev/null
    fi

    local encarc=""; [[ -n $ARC_PATH ]] && encarc=$(enc "${ARC_PATH#"$src_root"/}")
    if [[ $DEPLOY_ACTION == DEPLOYED_OVERWRITE ]]; then
        audit_write "$DEPLOY_ACTION" "$encrel" "$encarc" "$h" "$size" "$DEPLOY_OLD_HASH"
        log_tgt INFO DEPLOYED_OVERWRITE relpath="$encrel" size="$size" \
            new_hash="${h:0:8}…" old_hash="${DEPLOY_OLD_HASH:0:8}…" archive="$encarc"
        (( CYC_OVERWRITTEN++ ))
    else
        audit_write "$DEPLOY_ACTION" "$encrel" "$encarc" "$h" "$size"
        log_tgt INFO "$DEPLOY_ACTION" relpath="$encrel" size="$size" \
            hash="${h:0:8}…" archive="$encarc"
        (( CYC_DEPLOYED++ ))
    fi
    (( CYC_BYTES += size ))
}

# scan_one_dir <leaf> <mt> <src_root> <dep_root> <key> <root_dir>
# Process one directory: skip the local archive directory and anything matching
# EXCLUDE_DIR_PATTERNS (never the <root_dir> itself), skip it when its mtime is
# unchanged, otherwise move each file directly inside it (never deeper —
# recursion comes from the caller enumerating the dirs). Relative paths are
# computed against <src_root> and mirrored under <dep_root>. Uses the caller's
# locals (seen / scan_dirs / rescanned / cache_dirty) by dynamic scope.
scan_one_dir() {
    local leaf=$1 mt=$2 src_root=$3 dep_root=$4 key=$5 root_dir=$6
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
        _file_error "$key$SEP$leaf" SOURCE_NOT_WRITABLE dir="$(enc "${leaf#"$src_root"/}")" \
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
        process_file "$key" "$src_root" "$dep_root" "$f"
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
    local dep=$1 key=$2
    [[ -z $DEPLOY_MARKER ]] && return 0
    [[ -n ${DEPLOY_CHECKED[$key]:-} ]] && return 0
    local marker="$dep/$DEPLOY_MARKER"
    if [[ -e $marker ]]; then DEPLOY_CHECKED[$key]=1; return 0; fi

    local deployed_before=0 nonempty=0 probe
    [[ -e "$STATE_DIR/$key.deployed" ]] && deployed_before=1
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
        DEPLOY_CHECKED[$key]=1
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
    DEPLOY_CHECKED[$key]=1
    return 0
}

# ---------------------------------------------------------------------------
# scan_target <idx>: one cycle over a single target.
# ---------------------------------------------------------------------------
CYC_SCANNED=0 CYC_DEPLOYED=0 CYC_OVERWRITTEN=0 CYC_MOVED=0 CYC_ERRORS=0 CYC_BYTES=0
scan_target() {
    local idx=$1
    CUR_PROJECT=${T_PROJECT[$idx]}
    CUR_ENV=${T_ENV[$idx]}
    local src=${T_SRC[$idx]} dep=${T_DEP[$idx]} idn=${T_IDN[$idx]} key=${T_KEY[$idx]}
    local mode=${T_MODE[$idx]} depth=${T_DEPTH[$idx]}

    local tdir="$LOG_DIR/$key"
    mkdir -p -- "$tdir" 2>/dev/null
    CUR_OPLOG="$tdir/operations.log"
    CUR_AUDIT="$tdir/audit.log"
    local inputs_cache="$STATE_DIR/$key.inputs.tsv"
    local leaves_cache="$STATE_DIR/$key.leaves.tsv"

    log_tgt DEBUG TARGET_BEGIN mode="$mode" src="$(enc "$src")" deploy="$(enc "$dep")" \
        input_dir_name="$idn" depth="$depth"

    # Guard: the source must be an existing, readable, searchable directory.
    # A precise reason plus the deepest existing ancestor makes an unmounted
    # share or a wrong path immediately obvious.
    local mreason; mreason=$(mount_reason "$src")
    if [[ $mreason != ok ]]; then
        local prev=${T_MOUNT_STATE[$key]:-} anc; anc=$(deepest_existing "$src")
        local lvl=DEBUG; [[ $prev != missing ]] && lvl=ERROR   # loud on change, quiet on repeat
        T_MOUNT_STATE[$key]=missing
        _emit_file "$CUR_OPLOG" 1 "$lvl" MOUNT_MISSING \
            "src=$(enc "$src")" "reason=$mreason" "deepest_existing=$(enc "$anc")"
        return 0
    fi
    if [[ ${T_MOUNT_STATE[$key]:-} == missing ]]; then
        log_tgt INFO MOUNT_OK src="$(enc "$src")"
    fi
    T_MOUNT_STATE[$key]=ok
    ANY_TARGET_OK=1

    # The deployment tree must really be mounted before a single byte is
    # written -- and, above all, before a single file is taken out of the source
    # because of it.
    if ! check_deploy_root "$dep" "$key"; then
        RUN_ERRORS[$key]=$(( ${RUN_ERRORS[$key]:-0} + 1 ))
        ANY_DEPLOY_FAILED=1
        return 0
    fi

    # Periodic deep pass: ignore the directory-mtime skip every
    # DEEP_SCAN_INTERVAL seconds. In move mode this is belt-and-braces rather
    # than load-bearing -- a processed file no longer exists, and any file left
    # behind already keeps its directory unsettled (see _file_error) -- but it
    # still recovers a directory whose mtime the share failed to update. The
    # timestamp lives in a state file so cron re-invocations do not each force
    # a deep pass.
    local deep_marker="$STATE_DIR/$key.deepscan" nowd dmt
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

    if [[ $mode == fixed ]]; then
        load_leaves_cache "$leaves_cache"
    else
        discover_or_load_dirs "$key" "$src" "$idn" "$inputs_cache" "$leaves_cache"
    fi

    CYC_SCANNED=0 CYC_DEPLOYED=0 CYC_OVERWRITTEN=0 CYC_MOVED=0 CYC_ERRORS=0 CYC_BYTES=0
    local -A seen=()
    local input mt leaf dir_reads=0 scan_dirs=0 rescanned=0 cache_dirty=0
    local t_start; t_start=$(date +%s%N 2>/dev/null)

    if [[ $mode == fixed ]]; then
        # Explicit rule: one bulk readdir of the fixed source down to <depth>
        # sub-levels returns every directory to scan with its mtime in a single
        # walk. Excluded dirs are pruned (never descended). Files mirror under the
        # destination: <src>/sub/f -> <arc>/sub/f. depth -1 = the whole subtree.
        (( dir_reads++ ))
        local -a dexpr=(); (( depth >= 0 )) && dexpr=( -maxdepth "$depth" )
        local -a fexpr=(); build_prune_expr; fexpr=( ${PRUNE_EXPR[@]+"${PRUNE_EXPR[@]}"} )
        while IFS=$'\t' read -r -d '' mt leaf; do
            [[ -z $leaf ]] && continue
            scan_one_dir "$leaf" "$mt" "$src" "$dep" "$key" "$src"
        done < <(find "$src" -mindepth 0 ${dexpr[@]+"${dexpr[@]}"} ${fexpr[@]+"${fexpr[@]}"} \
                      -type d -printf '%T@\t%p\0' 2>/dev/null)
    else
        # One bulk readdir per input dir returns the input AND each of its direct
        # subdirs with their mtime in a single directory read (~1 CIFS round-trip),
        # instead of one stat per directory. We then scan the input's direct files and
        # each direct subdir's direct files (never deeper).
        for input in "${INPUT_DIRS[@]:-}"; do
            [[ -z $input ]] && continue
            (( dir_reads++ ))
            while IFS=$'\t' read -r -d '' mt leaf; do
                [[ -z $leaf ]] && continue
                scan_one_dir "$leaf" "$mt" "$src" "$dep" "$key" "$input"
            done < <(find "$input" -mindepth 0 -maxdepth 1 -type d -printf '%T@\t%p\0' 2>/dev/null)
        done
    fi

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

    RUN_DEPLOYED[$key]=$(( ${RUN_DEPLOYED[$key]:-0} + CYC_DEPLOYED ))
    RUN_OVERWRITTEN[$key]=$(( ${RUN_OVERWRITTEN[$key]:-0} + CYC_OVERWRITTEN ))
    RUN_MOVED[$key]=$(( ${RUN_MOVED[$key]:-0} + CYC_MOVED ))
    RUN_ERRORS[$key]=$(( ${RUN_ERRORS[$key]:-0} + CYC_ERRORS ))
    RUN_SCANNED[$key]=$(( ${RUN_SCANNED[$key]:-0} + CYC_SCANNED ))

    # Per-cycle detail is DEBUG (it happens every SCAN_INTERVAL); INFO summaries
    # come from HEARTBEAT and the final TARGET_SUMMARY.
    local t_end dur_ms=0; t_end=$(date +%s%N 2>/dev/null)
    [[ $t_start =~ ^[0-9]+$ && $t_end =~ ^[0-9]+$ ]] && dur_ms=$(( (t_end - t_start) / 1000000 ))
    log_tgt DEBUG CYCLE_SUMMARY dir_reads="$dir_reads" scan_dirs="$scan_dirs" rescanned="$rescanned" \
        scanned="$CYC_SCANNED" deployed="$CYC_DEPLOYED" overwritten="$CYC_OVERWRITTEN" \
        moved="$CYC_MOVED" errors="$CYC_ERRORS" \
        bytes_deployed="$CYC_BYTES" dur_ms="$dur_ms"
}

# ---------------------------------------------------------------------------
# Config / CLI
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: file-deploy.sh [--config FILE] [--dry-run] [--once] [--debug] [--verbose]
                      [--rediscover] [--help]

Moves files from "input" directories on a mounted NAS share into a mirror
deployment tree, keeping a local archive copy behind in the source. Targets are
described in targets.tsv. See README.md for details.

WARNING: this tool DELETES from the source. Rehearse with --dry-run first.

  --config FILE  Use this configuration file (default: <script dir>/file-deploy.conf).
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
    [[ -n $FORCE_CONSOLE ]] && LOG_CONSOLE=$FORCE_CONSOLE
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
    RUN_LOG="$LOG_DIR/_run.log"
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

    # Single-instance lock (self-managed; nothing hard-coded in the crontab).
    exec 9> "$LOCK_FILE" || { printf 'Cannot open lock file: %s\n' "$LOCK_FILE" >&2; exit $EX_CONFIG; }
    if ! flock -n 9; then
        # Expected every minute in continuous mode (the cron watchdog finds the
        # loop already running), so log at DEBUG to avoid noise.
        log_run DEBUG LOCK_BUSY lock="$(enc "$LOCK_FILE")"
        exit $EX_LOCKED
    fi

    # --- Startup banner (shown on the console when interactive) ---
    log_run INFO START pid="$$" host="${HOSTNAME:-$(uname -n 2>/dev/null)}" \
        user="$(id -un 2>/dev/null)" bash="$BASH_VERSION"
    log_run INFO PATHS script_dir="$(enc "$SCRIPT_DIR")" config="$(enc "$CONFIG_FILE")" \
        config_status="$CONFIG_STATUS" targets="$(enc "$TARGETS_FILE")" \
        state_dir="$(enc "$STATE_DIR")" log_dir="$(enc "$LOG_DIR")" lock="$(enc "$LOCK_FILE")"
    log_run INFO CONFIG input_dir_name="$INPUT_DIR_NAME" scan_interval="$SCAN_INTERVAL" \
        run_duration="$RUN_DURATION" min_stable_age="$MIN_STABLE_AGE" \
        discovery_interval="$DISCOVERY_INTERVAL" discovery_maxdepth="$DISCOVERY_MAXDEPTH" \
        use_dir_mtime_skip="$USE_DIR_MTIME_SKIP" deep_scan_interval="$DEEP_SCAN_INTERVAL" \
        deploy_marker="$(enc "$DEPLOY_MARKER")" local_archive_dir="$(enc "$LOCAL_ARCHIVE_DIR")" \
        hash_cmd="$HASH_CMD" dry_run="$DRY_RUN" \
        exclude_patterns="$(enc "${EXCLUDE_DIR_PATTERNS[*]:-}")" extra_dirs="${#EXTRA_DIRS[@]}" \
        log_format="$LOG_FORMAT" log_level="$LOG_LEVEL" console="$LOG_CONSOLE"
    [[ $CONFIG_STATUS == missing ]] && log_run WARN CONFIG_NOT_FOUND config="$(enc "$CONFIG_FILE")" \
        hint="config file not found; running with built-in defaults"
    # A rehearsal left switched on looks exactly like a healthy run that never
    # delivers anything, so say it loudly enough to show up in monitoring.
    [[ $DRY_RUN == true ]] && log_run WARN DRY_RUN_ACTIVE \
        source="$( (( FORCE_DRY )) && printf -- '--dry-run' || printf 'config' )" \
        hint="nothing will be written or deleted; unset DRY_RUN to deliver"

    if ! load_targets; then
        exit $EX_CONFIG
    fi
    load_extra_dirs   # append EXTRA_DIRS rules as "fixed" targets
    local ntargets=${#T_KEY[@]} i n_input=0 n_fixed=0
    for (( i = 0; i < ntargets; i++ )); do
        if [[ ${T_MODE[i]} == fixed ]]; then (( n_fixed++ )); else (( n_input++ )); fi
    done
    log_run INFO TARGETS_LOADED count="$ntargets" input="$n_input" extra="$n_fixed"
    if (( ntargets == 0 )); then
        log_run WARN NO_TARGETS hint="no enabled target in $TARGETS_FILE and no EXTRA_DIRS rule"
        log_run INFO END
        exit $EX_OK
    fi

    # Log every resolved target so a wrong source/archive path is obvious.
    for (( i = 0; i < ntargets; i++ )); do
        log_run INFO TARGET project="${T_PROJECT[i]}" env="${T_ENV[i]}" mode="${T_MODE[i]}" \
            source="$(enc "${T_SRC[i]}")" deploy="$(enc "${T_DEP[i]}")" \
            input_dir_name="${T_IDN[i]}" depth="${T_DEPTH[i]}" scan_interval="${T_SCAN[i]}"
    done

    # Poll granularity = smallest per-target scan interval.
    local tick=$SCAN_INTERVAL
    for (( i = 0; i < ntargets; i++ )); do
        (( T_SCAN[i] < tick )) && tick=${T_SCAN[i]}
    done
    (( tick < 1 )) && tick=1

    local cycle=0 first=1 now last_hb=0
    while (( first || SECONDS < RUN_DURATION )); do
        first=0
        (( cycle++ ))
        CUR_CYCLE=$cycle
        # Manual rediscovery request (marker dropped by `--rediscover`): force a
        # full-tree rediscovery for every target this cycle.
        if [[ -e $FORCE_MARKER ]]; then
            FORCE_REDISCOVER=1
            rm -f -- "$FORCE_MARKER" 2>/dev/null
            for (( i = 0; i < ntargets; i++ )); do T_LAST[i]=0; done
            log_run INFO FORCE_REDISCOVER cycle="$cycle"
        else
            FORCE_REDISCOVER=0
        fi
        now=$(now_epoch)
        for (( i = 0; i < ntargets; i++ )); do
            if (( now - T_LAST[i] >= T_SCAN[i] )); then
                T_LAST[i]=$now
                scan_target "$i"
            fi
        done
        CUR_PROJECT="" CUR_ENV="" CUR_CYCLE=""

        # Periodic heartbeat: proves the loop is alive and shows, at a glance,
        # whether it is archiving or stuck (e.g. every target MOUNT_MISSING).
        if (( HEARTBEAT_INTERVAL > 0 )) && (( now - last_hb >= HEARTBEAT_INTERVAL )); then
            last_hb=$now
            local hb_moved=0 hb_err=0 hb_missing=0 kk
            for kk in "${T_KEY[@]}"; do
                hb_moved=$(( hb_moved + ${RUN_MOVED[$kk]:-0} ))
                hb_err=$(( hb_err + ${RUN_ERRORS[$kk]:-0} ))
                [[ ${T_MOUNT_STATE[$kk]:-} == missing ]] && (( hb_missing++ ))
            done
            log_run INFO HEARTBEAT cycle="$cycle" elapsed_s="$SECONDS" targets="$ntargets" \
                moved="$hb_moved" errors="$hb_err" mount_missing="$hb_missing"
        fi

        (( SECONDS < RUN_DURATION )) || break
        sleep "$tick"
    done

    # Aggregated run summary (orchestration log).
    local tot_deployed=0 tot_overwritten=0 tot_moved=0 tot_errors=0 k
    for k in "${T_KEY[@]}"; do
        tot_deployed=$(( tot_deployed + ${RUN_DEPLOYED[$k]:-0} ))
        tot_overwritten=$(( tot_overwritten + ${RUN_OVERWRITTEN[$k]:-0} ))
        tot_moved=$(( tot_moved + ${RUN_MOVED[$k]:-0} ))
        tot_errors=$(( tot_errors + ${RUN_ERRORS[$k]:-0} ))
    done

    # Emit a TARGET_SUMMARY into each target's own operations log.
    for (( i = 0; i < ntargets; i++ )); do
        k=${T_KEY[i]}
        CUR_PROJECT=${T_PROJECT[i]}; CUR_ENV=${T_ENV[i]}
        CUR_OPLOG="$LOG_DIR/$k/operations.log"
        [[ -d "$LOG_DIR/$k" ]] && log_tgt INFO TARGET_SUMMARY \
            deployed="${RUN_DEPLOYED[$k]:-0}" overwritten="${RUN_OVERWRITTEN[$k]:-0}" \
            moved="${RUN_MOVED[$k]:-0}" errors="${RUN_ERRORS[$k]:-0}" \
            scanned="${RUN_SCANNED[$k]:-0}" mount="${T_MOUNT_STATE[$k]:-unknown}" cycles="$cycle"
    done
    CUR_PROJECT="" CUR_ENV="" CUR_CYCLE=""

    log_run INFO RUN_SUMMARY targets="$ntargets" cycles="$cycle" \
        deployed="$tot_deployed" overwritten="$tot_overwritten" moved="$tot_moved" errors="$tot_errors"
    log_run INFO END

    # Exit code precedence: no usable target > deploy failure > source stuck.
    # Undelivered data outranks delivered-but-not-drained.
    if (( ANY_TARGET_OK == 0 )); then
        exit $EX_NOTARGET
    elif (( ANY_DEPLOY_FAILED )); then
        exit $EX_DEPLOY
    elif (( ANY_SOURCE_STUCK )); then
        exit $EX_SOURCE
    fi
    exit $EX_OK
}

main "$@"
