#!/usr/bin/env bash
#
# squirrel.sh — copy files dropped into "input" directories on a mounted NAS
# share into a mirror archive tree, exactly once, with content-hash deduplication.
#
# Design invariants and behaviour are documented in README.md. Key points:
#   - The source ("input") tree is READ-ONLY: the script only reads and copies,
#     it never modifies or deletes a source file.
#   - Idempotent copy: a given (relative path, content hash) is archived once.
#     Same name + different content -> archived as name_YYYYMMDD_HHMMSS.ext.
#   - Several targets (project x environment) are described in targets.tsv.
#   - Per-target logging (operations + audit); orchestration events go to _run.log.
#   - Minimal disk I/O: input directory locations are cached and only rediscovered
#     periodically; unchanged directories (same mtime) are skipped without listing.
#
# Diagnostics: when run in a console every log line is mirrored to the terminal
# (LOG_CONSOLE=auto). `--debug` turns on maximum verbosity, `--once` does a single
# pass and exits. MOUNT_MISSING logs the exact reason and the deepest existing
# ancestor so an unmounted share or a wrong path is obvious immediately.
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
readonly EX_ARCHIVE=4   # at least one archive copy failed

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
REQUIRE_MOUNT=true
HASH_CMD="sha256sum"
DRY_RUN=false
DISCOVERY_INTERVAL=1800
DISCOVERY_MAXDEPTH=0    # cap the discovery walk depth (0 = unlimited)
USE_DIR_MTIME_SKIP=true
LOG_LEVEL="INFO"
LOG_FORMAT="text"
LOG_ROTATE_MAX_BYTES=10485760
LOG_ROTATE_KEEP=7
AUDIT_LOG=true
LOG_CONSOLE="auto"      # auto (mirror to terminal when interactive) | always | never
HEARTBEAT_INTERVAL=60   # seconds between periodic "still alive" summaries (0 = off)
EXCLUDE_DIR_PATTERNS=() # case-insensitive glob patterns of directory names to ignore (empty = none)

# Resolve the script directory portably (no readlink -f).
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

# Path defaults derived from the script directory (may be overridden in config).
TARGETS_FILE="$SCRIPT_DIR/targets.tsv"
STATE_DIR="$SCRIPT_DIR/state"
LOG_DIR="$SCRIPT_DIR/logs"
LOCK_FILE="$SCRIPT_DIR/run.lock"

CONFIG_FILE="$SCRIPT_DIR/squirrel.conf"

ACTION="run"           # run | rediscover
FORCE_REDISCOVER=0     # set per-cycle when a manual rediscovery is requested
FORCE_MARKER=""        # marker file path, set in main once STATE_DIR is known
FORCE_DEBUG=0          # --debug: max verbosity + console
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
        wc -c < "$p" 2>/dev/null | tr -d ' '
    fi
}

# get_meta: prints "<size> <mtime_epoch>" for a file, portable.
get_meta() {
    local p=$1 out sz mt
    if out=$(stat -c '%s %Y' -- "$p" 2>/dev/null); then
        printf '%s' "$out"
        return 0
    fi
    sz=$(wc -c < "$p" 2>/dev/null | tr -d ' ') || return 1
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
    else printf 'ok'
    fi
}

# enc / dec: make an arbitrary string safe for a single TSV/log field by
# escaping percent, tab, newline and carriage return. Reversible with dec.
enc() {
    local s=$1
    s=${s//'%'/%25}
    s=${s//$'\t'/%09}
    s=${s//$'\n'/%0A}
    s=${s//$'\r'/%0D}
    printf '%s' "$s"
}
dec() {
    local s=$1
    s=${s//%09/$'\t'}
    s=${s//%0A/$'\n'}
    s=${s//%0D/$'\r'}
    s=${s//%25/'%'}
    printf '%s' "$s"
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

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_LEVEL_NUM=20  # recomputed from LOG_LEVEL after config load

_lvlnum() {
    case $1 in
        DEBUG) printf '10' ;;
        INFO)  printf '20' ;;
        WARN)  printf '30' ;;
        ERROR) printf '40' ;;
        *)     printf '20' ;;
    esac
}

# rotate_if_needed: size-based rotation of a single log file (no external tool).
rotate_if_needed() {
    local f=$1 sz keep i
    (( LOG_ROTATE_MAX_BYTES > 0 )) || return 0
    [[ -f $f ]] || return 0
    sz=$(file_size "$f")
    is_uint "$sz" || return 0
    (( sz >= LOG_ROTATE_MAX_BYTES )) || return 0
    keep=$LOG_ROTATE_KEEP
    [[ -f "$f.$keep" ]] && rm -f -- "$f.$keep"
    for (( i = keep - 1; i >= 1; i-- )); do
        [[ -f "$f.$i" ]] && mv -f -- "$f.$i" "$f.$((i + 1))"
    done
    mv -f -- "$f" "$f.1"
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
    (( $(_lvlnum "$level") >= LOG_LEVEL_NUM )) || return 0
    rotate_if_needed "$file"
    local ts line kv k v
    ts=$(ts_iso)
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
    printf '%s\n' "$line" >> "$file"
    (( CONSOLE_ON )) && printf '%s\n' "$line" >&2
    return 0
}

log_run() { local lvl=$1 ev=$2; shift 2; _emit_file "$RUN_LOG" 0 "$lvl" "$ev" "$@"; }
log_tgt() { local lvl=$1 ev=$2; shift 2; _emit_file "$CUR_OPLOG" 1 "$lvl" "$ev" "$@"; }

audit_write() {  # action encrel enctarget hash size
    [[ $AUDIT_LOG == true ]] || return 0
    printf '%s\n' "ts=$(ts_iso) run=$RUN_ID action=$1 source=\"$2\" target=\"$3\" hash=$4 size=$5" \
        >> "$CUR_AUDIT"
}

# ---------------------------------------------------------------------------
# Ledger (per target), loaded lazily into memory and kept for the whole run.
#   LED_SMT[key SEP encrel SEP size SEP mtime] = 1  -> exact version already seen
#   LED_RH [key SEP encrel SEP hash]           = 1  -> content already archived
#   LED_HASREL[key SEP encrel]                 = 1  -> relpath has >=1 version
# ---------------------------------------------------------------------------
declare -A LED_SMT=() LED_RH=() LED_HASREL=() LED_LOADED=()

# ensure_ledger_loaded <key> <ledger_file>
# Returns 2 if the ledger looks corrupted.
ensure_ledger_loaded() {
    local key=$1 ledger=$2
    [[ -n ${LED_LOADED[$key]:-} ]] && return 0
    LED_LOADED[$key]=1
    [[ -f $ledger ]] || return 0
    local encrel size mtime hash tgt at
    while IFS=$'\t' read -r encrel size mtime hash tgt at || [[ -n $encrel ]]; do
        [[ -z $encrel ]] && continue
        if ! is_uint "$size" || ! is_uint "$mtime" || [[ -z $hash ]]; then
            return 2
        fi
        LED_SMT["$key$SEP$encrel$SEP$size$SEP$mtime"]=1
        LED_RH["$key$SEP$encrel$SEP$hash"]=1
        LED_HASREL["$key$SEP$encrel"]=1
    done < "$ledger"
    return 0
}

ledger_append() {  # key ledger encrel size mtime hash enctgt at
    local key=$1 ledger=$2 encrel=$3 size=$4 mtime=$5 hash=$6 enctgt=$7 at=$8
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$encrel" "$size" "$mtime" "$hash" "$enctgt" "$at" >> "$ledger"
    LED_SMT["$key$SEP$encrel$SEP$size$SEP$mtime"]=1
    LED_RH["$key$SEP$encrel$SEP$hash"]=1
    LED_HASREL["$key$SEP$encrel"]=1
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------
declare -a T_PROJECT=() T_ENV=() T_SRC=() T_ARC=() T_IDN=() T_SCAN=() T_KEY=() T_LAST=()
declare -A _seen_target=()
declare -A T_MOUNT_STATE=()   # key -> "ok" | "missing" (for state-change logging)

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

        if [[ $enabled != true ]]; then
            log_run DEBUG TARGET_DISABLED project="$project" env="$env" enabled="$(enc "$enabled")"
            continue
        fi
        T_PROJECT+=("$project"); T_ENV+=("$env")
        T_SRC+=("$src");         T_ARC+=("$arc")
        T_IDN+=("$idn");         T_SCAN+=("$scan")
        T_KEY+=("$key");         T_LAST+=(0)
    done < "$TARGETS_FILE"
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
discover_or_load_dirs() {
    local key=$1 src=$2 idn=$3 inputs_cache=$4 leaves_cache=$5
    INPUT_DIRS=(); DIRLAST=()

    # Load persisted per-leaf settled mtimes (local disk, cheap).
    local encleaf lastm
    if [[ -f $leaves_cache ]]; then
        while IFS=$'\t' read -r encleaf lastm || [[ -n $encleaf ]]; do
            [[ -z $encleaf ]] && continue
            DIRLAST["$(dec "$encleaf")"]=$lastm
        done < "$leaves_cache"
    fi

    # Decide whether to re-locate the input dirs (the expensive full-tree walk).
    local need_discovery=0 now cache_mt age reason="cache-fresh"
    now=$(now_epoch)
    if [[ ! -f $inputs_cache ]]; then need_discovery=1; reason="no-cache"
    else
        cache_mt=$(get_mtime "$inputs_cache"); is_uint "$cache_mt" || cache_mt=0
        age=$(( now - cache_mt )); (( age >= DISCOVERY_INTERVAL )) && { need_discovery=1; reason="cache-stale"; }
    fi
    (( FORCE_REDISCOVER )) && { need_discovery=1; reason="forced"; }

    if (( need_discovery )); then
        local t0 t1 d
        t0=$(now_epoch)
        log_tgt DEBUG DISCOVERY_BEGIN src="$(enc "$src")" input_dir_name="$idn" reason="$reason"
        # Optional depth cap.
        local -a dexpr=(); (( DISCOVERY_MAXDEPTH > 0 )) && dexpr=( -maxdepth "$DISCOVERY_MAXDEPTH" )
        # Prune expression from the exclude patterns (case-insensitive).
        local -a fexpr=() pat; local firstp=1
        for pat in "${EXCLUDE_DIR_PATTERNS[@]:-}"; do
            [[ -z $pat ]] && continue
            if (( firstp )); then fexpr+=( '(' -type d '(' -iname "$pat" ); firstp=0
            else fexpr+=( -o -iname "$pat" ); fi
        done
        (( firstp )) || fexpr+=( ')' -prune ')' -o )
        local -a newinputs=()
        # -print0 -prune: print each input dir and DO NOT descend into it.
        while IFS= read -r -d '' d; do
            newinputs+=("$d")
            log_tgt DEBUG FOUND_INPUT_DIR dir="$(enc "${d#"$src"/}")"
        done < <(find "$src" "${dexpr[@]}" "${fexpr[@]}" -type d -name "$idn" -print0 -prune 2>/dev/null)
        INPUT_DIRS=("${newinputs[@]:-}")
        write_inputs_cache "$inputs_cache"
        t1=$(now_epoch)
        log_tgt INFO DISCOVERY input_dirs="${#newinputs[@]}" dur_s="$(( t1 - t0 ))" \
            src="$(enc "$src")" input_dir_name="$idn" reason="$reason"
        if (( ${#newinputs[@]} == 0 )); then
            log_tgt WARN NO_INPUT_DIRS src="$(enc "$src")" input_dir_name="$idn" \
                hint="no directory named '$idn' found under the source"
        fi
    else
        local encd
        while IFS= read -r encd || [[ -n $encd ]]; do
            [[ -z $encd ]] && continue
            INPUT_DIRS+=("$(dec "$encd")")
        done < "$inputs_cache"
        log_tgt DEBUG DISCOVERY_CACHED input_dirs="${#INPUT_DIRS[@]}"
    fi
}

write_inputs_cache() {
    local cache=$1 d tmp="$1.tmp.$$"
    : > "$tmp" 2>/dev/null || return 1
    for d in "${INPUT_DIRS[@]:-}"; do
        [[ -z $d ]] && continue
        printf '%s\n' "$(enc "$d")" >> "$tmp"
    done
    mv -f -- "$tmp" "$cache"
}

# ---------------------------------------------------------------------------
# Per-run accumulators
# ---------------------------------------------------------------------------
ANY_TARGET_OK=0
ANY_COPY_FAILED=0
declare -A RUN_COPIED=() RUN_VERSIONED=() RUN_SKIPPED=() RUN_ERRORS=() RUN_SCANNED=()

# process_file <key> <src_root> <arc_root> <src_path>
# Handles one source file. Never writes to the source. Sets DIR_UNSETTLED=1 when
# the file could not be finalised (unstable / error), so the directory is
# rescanned next cycle.
DIR_UNSETTLED=0
process_file() {
    local key=$1 src_root=$2 arc_root=$3 src=$4
    local relpath encrel meta size mtime now age h
    relpath=${src#"$src_root"/}
    encrel=$(enc "$relpath")

    meta=$(get_meta "$src") || {
        # File vanished between listing and stat.
        log_tgt WARN FILE_VANISHED relpath="$encrel"
        return 0
    }
    size=${meta%% *}; mtime=${meta##* }
    if ! is_uint "$size" || ! is_uint "$mtime"; then
        log_tgt WARN META_UNREADABLE relpath="$encrel"
        DIR_UNSETTLED=1
        return 0
    fi

    (( CYC_SCANNED++ ))

    now=$(now_epoch); age=$(( now - mtime ))
    if (( age < MIN_STABLE_AGE )); then
        log_tgt DEBUG SKIP_UNSTABLE relpath="$encrel" age_s="$age" min_stable_age="$MIN_STABLE_AGE"
        DIR_UNSETTLED=1
        return 0
    fi

    # Already processed this exact (path,size,mtime) -> nothing to do, no re-hash.
    if [[ -n ${LED_SMT["$key$SEP$encrel$SEP$size$SEP$mtime"]:-} ]]; then
        log_tgt DEBUG SKIP_LEDGER relpath="$encrel" size="$size" mtime="$mtime"
        return 0
    fi

    h=$(hash_file "$src") || {
        log_tgt WARN HASH_FAILED relpath="$encrel" hash_cmd="$HASH_CMD"
        (( CYC_ERRORS++ )); DIR_UNSETTLED=1
        return 0
    }

    # Content already archived for this relpath (e.g. file touched, or reverted).
    if [[ -n ${LED_RH["$key$SEP$encrel$SEP$h"]:-} ]]; then
        log_tgt DEBUG SKIP_SAME_HASH relpath="$encrel" hash="${h:0:8}…"
        LED_SMT["$key$SEP$encrel$SEP$size$SEP$mtime"]=1
        (( CYC_SKIPPED++ ))
        return 0
    fi

    # New content -> decide base name vs timestamped version.
    local reldir base target_rel action
    if [[ $relpath == */* ]]; then reldir=${relpath%/*}; else reldir=""; fi
    base=${relpath##*/}
    if [[ -z ${LED_HASREL["$key$SEP$encrel"]:-} ]]; then
        target_rel=$relpath
        action=COPIED
    else
        local stamp tgtbase
        stamp=$(ts_compact)
        if [[ $base == ?*.* ]]; then
            tgtbase="${base%.*}_${stamp}.${base##*.}"
        else
            tgtbase="${base}_${stamp}"
        fi
        target_rel="${reldir:+$reldir/}$tgtbase"
        action=VERSIONED
    fi

    local dst dst_dir enctgt at
    dst="$arc_root/$target_rel"
    dst_dir=${dst%/*}
    enctgt=$(enc "$target_rel")

    if [[ $DRY_RUN == true ]]; then
        log_tgt INFO "$action" relpath="$encrel" target="$enctgt" size="$size" dry="1"
        if [[ $action == COPIED ]]; then (( CYC_COPIED++ )); else (( CYC_VERSIONED++ )); fi
        return 0
    fi

    local err rc
    if ! err=$(mkdir -p -- "$dst_dir" 2>&1); then
        log_tgt ERROR COPY_FAILED stage="mkdir" relpath="$encrel" dst_dir="$(enc "$dst_dir")" rc="1" err="$(enc "$err")"
        (( CYC_ERRORS++ )); ANY_COPY_FAILED=1; DIR_UNSETTLED=1
        return 0
    fi

    local tmp="$dst.tmp.$$"
    if ! err=$(cp -p -- "$src" "$tmp" 2>&1); then
        rc=$?
        log_tgt ERROR COPY_FAILED stage="cp" relpath="$encrel" dst="$(enc "$dst")" rc="$rc" err="$(enc "$err")"
        rm -f -- "$tmp" 2>/dev/null
        (( CYC_ERRORS++ )); ANY_COPY_FAILED=1; DIR_UNSETTLED=1
        return 0
    fi
    if ! err=$(mv -f -- "$tmp" "$dst" 2>&1); then
        rc=$?
        log_tgt ERROR COPY_FAILED stage="mv" relpath="$encrel" dst="$(enc "$dst")" rc="$rc" err="$(enc "$err")"
        rm -f -- "$tmp" 2>/dev/null
        (( CYC_ERRORS++ )); ANY_COPY_FAILED=1; DIR_UNSETTLED=1
        return 0
    fi

    at=$(ts_iso)
    ledger_append "$key" "$LEDGER_FILE" "$encrel" "$size" "$mtime" "$h" "$enctgt" "$at"
    audit_write "$action" "$encrel" "$enctgt" "$h" "$size"
    log_tgt INFO "$action" relpath="$encrel" target="$enctgt" size="$size" hash="${h:0:8}…"
    if [[ $action == COPIED ]]; then (( CYC_COPIED++ )); else (( CYC_VERSIONED++ )); fi
    (( CYC_BYTES += size ))
}

# ---------------------------------------------------------------------------
# scan_target <idx>: one cycle over a single target.
# ---------------------------------------------------------------------------
LEDGER_FILE=""
CYC_SCANNED=0 CYC_COPIED=0 CYC_VERSIONED=0 CYC_SKIPPED=0 CYC_ERRORS=0 CYC_BYTES=0
scan_target() {
    local idx=$1
    CUR_PROJECT=${T_PROJECT[$idx]}
    CUR_ENV=${T_ENV[$idx]}
    local src=${T_SRC[$idx]} arc=${T_ARC[$idx]} idn=${T_IDN[$idx]} key=${T_KEY[$idx]}

    local tdir="$LOG_DIR/$key"
    mkdir -p -- "$tdir" 2>/dev/null
    CUR_OPLOG="$tdir/operations.log"
    CUR_AUDIT="$tdir/audit.log"
    LEDGER_FILE="$STATE_DIR/$key.ledger.tsv"
    local inputs_cache="$STATE_DIR/$key.inputs.tsv"
    local leaves_cache="$STATE_DIR/$key.leaves.tsv"

    log_tgt DEBUG TARGET_BEGIN src="$(enc "$src")" arc="$(enc "$arc")" input_dir_name="$idn"

    # Guard: the source must be an existing, readable, searchable directory.
    # A precise reason plus the deepest existing ancestor makes an unmounted
    # share or a wrong path immediately obvious.
    local mreason; mreason=$(mount_reason "$src")
    if [[ $mreason != ok ]]; then
        local prev=${T_MOUNT_STATE[$key]:-} anc; anc=$(deepest_existing "$src")
        local base_lvl=ERROR; [[ $REQUIRE_MOUNT == true ]] || base_lvl=WARN
        local lvl=DEBUG; [[ $prev != missing ]] && lvl=$base_lvl   # loud on change, quiet on repeat
        T_MOUNT_STATE[$key]=missing
        _emit_file "$CUR_OPLOG" 1 "$lvl" MOUNT_MISSING \
            "src=$(enc "$src")" "reason=$mreason" "deepest_existing=$(enc "$anc")" \
            "require_mount=$REQUIRE_MOUNT"
        return 0
    fi
    if [[ ${T_MOUNT_STATE[$key]:-} == missing ]]; then
        log_tgt INFO MOUNT_OK src="$(enc "$src")"
    fi
    T_MOUNT_STATE[$key]=ok
    ANY_TARGET_OK=1

    # Ledger (lazy): refuse the target if the ledger is corrupted.
    ensure_ledger_loaded "$key" "$LEDGER_FILE"
    local lrc=$?
    if (( lrc == 2 )); then
        log_tgt ERROR LEDGER_CORRUPT ledger="$(enc "$LEDGER_FILE")" \
            hint="inspect/rebuild the ledger to re-enable this target"
        return 0
    fi

    discover_or_load_dirs "$key" "$src" "$idn" "$inputs_cache" "$leaves_cache"

    CYC_SCANNED=0 CYC_COPIED=0 CYC_VERSIONED=0 CYC_SKIPPED=0 CYC_ERRORS=0 CYC_BYTES=0
    local -A seen=()
    local input mt leaf base f dir_reads=0 scan_dirs=0 rescanned=0

    # One bulk readdir per input dir returns the input AND each of its direct
    # subdirs with their mtime in a single directory read (~1 CIFS round-trip),
    # instead of one stat per directory. We then scan the input's direct files and
    # each direct subdir's direct files (never deeper).
    for input in "${INPUT_DIRS[@]:-}"; do
        [[ -z $input ]] && continue
        (( dir_reads++ ))
        while IFS=$'\t' read -r -d '' mt leaf; do
            [[ -z $leaf ]] && continue
            base=${leaf##*/}
            # Exclude matching sub-directories (never the input dir itself).
            if [[ $leaf != "$input" ]] && is_excluded_dirname "$base"; then
                log_tgt DEBUG EXCLUDED_DIR dir="$(enc "${leaf#"$src"/}")"
                continue
            fi
            seen["$leaf"]=1
            (( scan_dirs++ ))
            if [[ $USE_DIR_MTIME_SKIP == true && ${DIRLAST["$leaf"]:-} == "$mt" ]]; then
                log_tgt DEBUG SKIP_DIR_UNCHANGED dir="$(enc "${leaf#"$src"/}")" mtime="$mt"
                continue
            fi
            (( rescanned++ ))
            log_tgt DEBUG DIR_RESCAN dir="$(enc "${leaf#"$src"/}")" mtime="$mt" last="${DIRLAST["$leaf"]:-}"
            DIR_UNSETTLED=0
            while IFS= read -r -d '' f; do
                [[ -f $f ]] || continue
                process_file "$key" "$src" "$arc" "$f"
            done < <(find "$leaf" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
            # Settle (cache the mtime) only if everything finalised; otherwise leave
            # the previous value so the leaf is rescanned next cycle.
            (( DIR_UNSETTLED == 0 )) && DIRLAST["$leaf"]=$mt
        done < <(find "$input" -mindepth 0 -maxdepth 1 -type d -printf '%T@\t%p\0' 2>/dev/null)
    done

    # Persist settled mtimes for the leaves seen this cycle (drops removed leaves).
    local tmp="$leaves_cache.tmp.$$" lf
    if : > "$tmp" 2>/dev/null; then
        for lf in "${!seen[@]}"; do
            [[ -n ${DIRLAST["$lf"]:-} ]] && printf '%s\t%s\n' "$(enc "$lf")" "${DIRLAST["$lf"]}" >> "$tmp"
        done
        mv -f -- "$tmp" "$leaves_cache"
    fi

    RUN_COPIED[$key]=$(( ${RUN_COPIED[$key]:-0} + CYC_COPIED ))
    RUN_VERSIONED[$key]=$(( ${RUN_VERSIONED[$key]:-0} + CYC_VERSIONED ))
    RUN_SKIPPED[$key]=$(( ${RUN_SKIPPED[$key]:-0} + CYC_SKIPPED ))
    RUN_ERRORS[$key]=$(( ${RUN_ERRORS[$key]:-0} + CYC_ERRORS ))
    RUN_SCANNED[$key]=$(( ${RUN_SCANNED[$key]:-0} + CYC_SCANNED ))

    # Per-cycle detail is DEBUG (it happens every SCAN_INTERVAL); INFO summaries
    # come from HEARTBEAT and the final TARGET_SUMMARY.
    log_tgt DEBUG CYCLE_SUMMARY dir_reads="$dir_reads" scan_dirs="$scan_dirs" rescanned="$rescanned" \
        scanned="$CYC_SCANNED" copied="$CYC_COPIED" versioned="$CYC_VERSIONED" \
        skipped="$CYC_SKIPPED" errors="$CYC_ERRORS" bytes_copied="$CYC_BYTES"
}

# ---------------------------------------------------------------------------
# Config / CLI
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: squirrel.sh [--config FILE] [--rediscover] [--debug] [--once] [--verbose] [--help]

Copies files from "input" directories on a mounted NAS share into a mirror
archive tree, exactly once, with content-hash deduplication. Targets are
described in targets.tsv. See README.md for details.

  --config FILE  Use this configuration file (default: <script dir>/squirrel.conf).
  --rediscover   Request an immediate rediscovery of the input directories:
                 drops a marker the running scanner picks up next cycle. Exits
                 right away without scanning.
  --debug        Maximum verbosity: LOG_LEVEL=DEBUG and mirror every line to the
                 terminal. Great for finding why nothing is being archived.
  --once         Do a single scan pass and exit (RUN_DURATION=0), instead of the
                 continuous loop. Combine with --debug to diagnose quickly.
  --verbose      Mirror log lines to the terminal (without changing the level).
  --help         Show this help.
EOF
}

parse_args() {
    while (( $# )); do
        case $1 in
            --config) CONFIG_FILE=$2; shift 2 ;;
            --config=*) CONFIG_FILE=${1#*=}; shift ;;
            --rediscover) ACTION="rediscover"; shift ;;
            --debug) FORCE_DEBUG=1; shift ;;
            --once) ONCE=1; shift ;;
            --verbose|-v) LOG_CONSOLE="always"; shift ;;
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
    # CLI overrides applied last so they always win.
    if (( FORCE_DEBUG )); then LOG_LEVEL="DEBUG"; LOG_CONSOLE="always"; fi
    if (( ONCE )); then RUN_DURATION=0; fi
    LOG_LEVEL_NUM=$(_lvlnum "$LOG_LEVEL")
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
    RUN_ID="$(printf '%s' "$(ts_compact)")-$$"
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
        use_dir_mtime_skip="$USE_DIR_MTIME_SKIP" \
        require_mount="$REQUIRE_MOUNT" hash_cmd="$HASH_CMD" dry_run="$DRY_RUN" \
        exclude_patterns="$(enc "${EXCLUDE_DIR_PATTERNS[*]:-}")" \
        log_format="$LOG_FORMAT" log_level="$LOG_LEVEL" console="$LOG_CONSOLE"
    [[ $CONFIG_STATUS == missing ]] && log_run WARN CONFIG_NOT_FOUND config="$(enc "$CONFIG_FILE")" \
        hint="config file not found; running with built-in defaults"

    if ! load_targets; then
        exit $EX_CONFIG
    fi
    local ntargets=${#T_KEY[@]}
    log_run INFO TARGETS_LOADED count="$ntargets"
    if (( ntargets == 0 )); then
        log_run WARN NO_TARGETS hint="no enabled target in $TARGETS_FILE (check the 'enabled' column)"
        log_run INFO END
        exit $EX_OK
    fi

    # Log every resolved target so a wrong source/archive path is obvious.
    local i
    for (( i = 0; i < ntargets; i++ )); do
        log_run INFO TARGET project="${T_PROJECT[i]}" env="${T_ENV[i]}" \
            source="$(enc "${T_SRC[i]}")" archive="$(enc "${T_ARC[i]}")" \
            input_dir_name="${T_IDN[i]}" scan_interval="${T_SCAN[i]}"
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
            local hb_copied=0 hb_err=0 hb_missing=0 kk
            for kk in "${T_KEY[@]}"; do
                hb_copied=$(( hb_copied + ${RUN_COPIED[$kk]:-0} ))
                hb_err=$(( hb_err + ${RUN_ERRORS[$kk]:-0} ))
                [[ ${T_MOUNT_STATE[$kk]:-} == missing ]] && (( hb_missing++ ))
            done
            log_run INFO HEARTBEAT cycle="$cycle" elapsed_s="$SECONDS" targets="$ntargets" \
                copied="$hb_copied" errors="$hb_err" mount_missing="$hb_missing"
        fi

        (( SECONDS < RUN_DURATION )) || break
        sleep "$tick"
    done

    # Aggregated run summary (orchestration log).
    local tot_copied=0 tot_versioned=0 tot_skipped=0 tot_errors=0 k
    for k in "${T_KEY[@]}"; do
        tot_copied=$(( tot_copied + ${RUN_COPIED[$k]:-0} ))
        tot_versioned=$(( tot_versioned + ${RUN_VERSIONED[$k]:-0} ))
        tot_skipped=$(( tot_skipped + ${RUN_SKIPPED[$k]:-0} ))
        tot_errors=$(( tot_errors + ${RUN_ERRORS[$k]:-0} ))
    done

    # Emit a TARGET_SUMMARY into each target's own operations log.
    for (( i = 0; i < ntargets; i++ )); do
        k=${T_KEY[i]}
        CUR_PROJECT=${T_PROJECT[i]}; CUR_ENV=${T_ENV[i]}
        CUR_OPLOG="$LOG_DIR/$k/operations.log"
        [[ -d "$LOG_DIR/$k" ]] && log_tgt INFO TARGET_SUMMARY \
            copied="${RUN_COPIED[$k]:-0}" versioned="${RUN_VERSIONED[$k]:-0}" \
            skipped="${RUN_SKIPPED[$k]:-0}" errors="${RUN_ERRORS[$k]:-0}" \
            scanned="${RUN_SCANNED[$k]:-0}" mount="${T_MOUNT_STATE[$k]:-unknown}" cycles="$cycle"
    done
    CUR_PROJECT="" CUR_ENV="" CUR_CYCLE=""

    log_run INFO RUN_SUMMARY targets="$ntargets" cycles="$cycle" \
        copied="$tot_copied" versioned="$tot_versioned" skipped="$tot_skipped" errors="$tot_errors"
    log_run INFO END

    # Exit code precedence: no usable target > copy failure > success.
    if (( ANY_TARGET_OK == 0 )); then
        exit $EX_NOTARGET
    elif (( ANY_COPY_FAILED )); then
        exit $EX_ARCHIVE
    fi
    exit $EX_OK
}

main "$@"
