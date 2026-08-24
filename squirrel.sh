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
USE_DIR_MTIME_SKIP=true
LOG_LEVEL="INFO"
LOG_FORMAT="text"
LOG_ROTATE_MAX_BYTES=10485760
LOG_ROTATE_KEEP=7
AUDIT_LOG=true

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
_emit_file() {
    local file=$1 withctx=$2 level=$3 event=$4
    shift 4
    (( $(_lvlnum "$level") >= LOG_LEVEL_NUM )) || return 0
    rotate_if_needed "$file"
    local ts kv k v
    ts=$(ts_iso)
    if [[ $LOG_FORMAT == json ]]; then
        local out
        out="{\"ts\":\"$ts\",\"level\":\"$level\",\"run\":\"$(json_esc "$RUN_ID")\""
        if (( withctx )) && [[ -n $CUR_PROJECT ]]; then
            out+=",\"project\":\"$(json_esc "$CUR_PROJECT")\",\"env\":\"$(json_esc "$CUR_ENV")\""
            [[ -n $CUR_CYCLE ]] && out+=",\"cycle\":$CUR_CYCLE"
        fi
        out+=",\"event\":\"$event\""
        for kv in "$@"; do
            k=${kv%%=*}; v=${kv#*=}
            out+=",\"$(json_esc "$k")\":\"$(json_esc "$v")\""
        done
        out+="}"
        printf '%s\n' "$out" >> "$file"
    else
        local line
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
        printf '%s\n' "$line" >> "$file"
    fi
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

# load_targets: parse targets.tsv into the T_* arrays. Returns EX_CONFIG on a
# fatal read error.
load_targets() {
    if [[ ! -f $TARGETS_FILE || ! -r $TARGETS_FILE ]]; then
        log_run ERROR TARGETS_UNREADABLE file="$(enc "$TARGETS_FILE")"
        return $EX_CONFIG
    fi
    local raw c1 c2 c3 c4 c5 c6 c7 rest
    local project env src arc idn scan enabled key
    while IFS= read -r raw || [[ -n $raw ]]; do
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
            log_run WARN TARGET_MALFORMED line="$(enc "$t")"
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
            log_run ERROR TARGET_DUPLICATE project="$project" env="$env"
            continue
        fi
        _seen_target[$key]=1

        if [[ $enabled != true ]]; then
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
# Input-directory cache (per target)
#   file: STATE_DIR/<key>.inputdirs.tsv  ->  "<enc(dir)>\t<last_settled_mtime>"
# ---------------------------------------------------------------------------

# discover_or_load_dirs <key> <src> <idn> <cache>
# Populates the global DIRS array and DIRLAST map. Rediscovers (full tree walk)
# only when the cache is missing or older than DISCOVERY_INTERVAL.
declare -a DIRS=()
declare -A DIRLAST=()
discover_or_load_dirs() {
    local key=$1 src=$2 idn=$3 cache=$4
    DIRS=(); DIRLAST=()

    local need_discovery=0 now cache_mt age
    now=$(now_epoch)
    if [[ ! -f $cache ]]; then
        need_discovery=1
    else
        cache_mt=$(get_mtime "$cache"); is_uint "$cache_mt" || cache_mt=0
        age=$(( now - cache_mt ))
        (( age >= DISCOVERY_INTERVAL )) && need_discovery=1
    fi
    (( FORCE_REDISCOVER )) && need_discovery=1

    # Always load whatever the cache currently holds (to preserve settled mtimes).
    local encdir lastm dir
    if [[ -f $cache ]]; then
        while IFS=$'\t' read -r encdir lastm || [[ -n $encdir ]]; do
            [[ -z $encdir ]] && continue
            is_uint "$lastm" || lastm=0
            dir=$(dec "$encdir")
            DIRLAST["$dir"]=$lastm
            DIRS+=("$dir")
        done < "$cache"
    fi

    if (( need_discovery )); then
        local t0 t1 count=0 d
        t0=$(now_epoch)
        declare -A _found=()
        local -a newdirs=()
        while IFS= read -r -d '' d; do
            _found["$d"]=1
            newdirs+=("$d")
            [[ -z ${DIRLAST["$d"]:-} ]] && DIRLAST["$d"]=0
            (( count++ ))
        done < <(find "$src" -type d -name "$idn" -print0 2>/dev/null)
        # Drop directories that disappeared.
        for dir in "${DIRS[@]:-}"; do
            [[ -z $dir ]] && continue
            [[ -z ${_found["$dir"]:-} ]] && unset 'DIRLAST[$dir]'
        done
        DIRS=("${newdirs[@]:-}")
        t1=$(now_epoch)
        log_tgt INFO DISCOVERY count="$count" dur_s="$(( t1 - t0 ))"
        write_dir_cache "$cache"
    fi
}

write_dir_cache() {
    local cache=$1 dir tmp
    tmp="$cache.tmp.$$"
    : > "$tmp" || return 1
    for dir in "${DIRS[@]:-}"; do
        [[ -z $dir ]] && continue
        printf '%s\t%s\n' "$(enc "$dir")" "${DIRLAST["$dir"]:-0}" >> "$tmp"
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
# Handles one source file. Never writes to the source. Sets the caller's
# `dir_settled` to 0 (via the DIR_UNSETTLED global) when the file could not be
# finalised (unstable / error), so the directory is rescanned next cycle.
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
        log_tgt DEBUG SKIP_UNSTABLE relpath="$encrel" age_s="$age"
        DIR_UNSETTLED=1
        return 0
    fi

    # Already processed this exact (path,size,mtime) -> nothing to do, no re-hash.
    if [[ -n ${LED_SMT["$key$SEP$encrel$SEP$size$SEP$mtime"]:-} ]]; then
        log_tgt DEBUG SKIP_LEDGER relpath="$encrel"
        return 0
    fi

    h=$(hash_file "$src") || {
        log_tgt WARN HASH_FAILED relpath="$encrel"
        (( CYC_ERRORS++ )); DIR_UNSETTLED=1
        return 0
    }

    # Content already archived for this relpath (e.g. file touched, or reverted).
    if [[ -n ${LED_RH["$key$SEP$encrel$SEP$h"]:-} ]]; then
        log_tgt DEBUG SKIP_SAME_HASH relpath="$encrel"
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
        log_tgt ERROR COPY_FAILED relpath="$encrel" rc="1" err="$(enc "$err")"
        (( CYC_ERRORS++ )); ANY_COPY_FAILED=1; DIR_UNSETTLED=1
        return 0
    fi

    local tmp="$dst.tmp.$$"
    if ! err=$(cp -p -- "$src" "$tmp" 2>&1); then
        rc=$?
        log_tgt ERROR COPY_FAILED relpath="$encrel" rc="$rc" err="$(enc "$err")"
        rm -f -- "$tmp" 2>/dev/null
        (( CYC_ERRORS++ )); ANY_COPY_FAILED=1; DIR_UNSETTLED=1
        return 0
    fi
    if ! err=$(mv -f -- "$tmp" "$dst" 2>&1); then
        rc=$?
        log_tgt ERROR COPY_FAILED relpath="$encrel" rc="$rc" err="$(enc "$err")"
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
    local cache="$STATE_DIR/$key.inputdirs.tsv"

    log_tgt DEBUG TARGET_BEGIN src="$(enc "$src")" arc="$(enc "$arc")"

    # Guard: source must exist and be readable (covers an unmounted share).
    if [[ ! -d $src || ! -r $src ]]; then
        if [[ $REQUIRE_MOUNT == true ]]; then
            log_tgt ERROR MOUNT_MISSING src="$(enc "$src")"
            return 0
        fi
        log_tgt WARN MOUNT_MISSING src="$(enc "$src")"
        return 0
    fi
    ANY_TARGET_OK=1

    # Ledger (lazy): refuse the target if the ledger is corrupted.
    ensure_ledger_loaded "$key" "$LEDGER_FILE"
    local lrc=$?
    if (( lrc == 2 )); then
        log_tgt ERROR LEDGER_CORRUPT ledger="$(enc "$LEDGER_FILE")" \
            hint="inspect/rebuild the ledger to re-enable this target"
        return 0
    fi

    discover_or_load_dirs "$key" "$src" "$idn" "$cache"

    CYC_SCANNED=0 CYC_COPIED=0 CYC_VERSIONED=0 CYC_SKIPPED=0 CYC_ERRORS=0 CYC_BYTES=0

    local dir dmt cache_dirty=0
    for dir in "${DIRS[@]:-}"; do
        [[ -z $dir ]] && continue
        [[ -d $dir ]] || continue
        dmt=$(get_mtime "$dir"); is_uint "$dmt" || dmt=0

        if [[ $USE_DIR_MTIME_SKIP == true && ${DIRLAST["$dir"]:-0} == "$dmt" && $dmt != 0 ]]; then
            log_tgt DEBUG SKIP_DIR_UNCHANGED dir="$(enc "${dir#"$src"/}")"
            continue
        fi

        log_tgt DEBUG DIR_RESCAN dir="$(enc "${dir#"$src"/}")"
        DIR_UNSETTLED=0
        local f
        while IFS= read -r -d '' f; do
            [[ -f $f ]] || continue
            process_file "$key" "$src" "$arc" "$f"
        done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)

        # Mark the directory settled (cache its mtime) only if everything was
        # finalised; otherwise leave the previous value so it is rescanned.
        if (( DIR_UNSETTLED == 0 )); then
            DIRLAST["$dir"]=$dmt
            cache_dirty=1
        fi
    done

    (( cache_dirty )) && write_dir_cache "$cache"

    RUN_COPIED[$key]=$(( ${RUN_COPIED[$key]:-0} + CYC_COPIED ))
    RUN_VERSIONED[$key]=$(( ${RUN_VERSIONED[$key]:-0} + CYC_VERSIONED ))
    RUN_SKIPPED[$key]=$(( ${RUN_SKIPPED[$key]:-0} + CYC_SKIPPED ))
    RUN_ERRORS[$key]=$(( ${RUN_ERRORS[$key]:-0} + CYC_ERRORS ))
    RUN_SCANNED[$key]=$(( ${RUN_SCANNED[$key]:-0} + CYC_SCANNED ))

    log_tgt INFO CYCLE_SUMMARY scanned="$CYC_SCANNED" copied="$CYC_COPIED" \
        versioned="$CYC_VERSIONED" skipped="$CYC_SKIPPED" errors="$CYC_ERRORS" \
        bytes_copied="$CYC_BYTES"
}

# ---------------------------------------------------------------------------
# Config / CLI
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: squirrel.sh [--config FILE] [--rediscover] [--help]

Copies files from "input" directories on a mounted NAS share into a mirror
archive tree, exactly once, with content-hash deduplication. Targets are
described in targets.tsv. See README.md for details.

  --rediscover   Request an immediate rediscovery of the input directories:
                 drops a marker that the running scanner picks up on its next
                 cycle (a new input directory is then seen without waiting for
                 DISCOVERY_INTERVAL). Does not start a scan; exits right away.
EOF
}

parse_args() {
    while (( $# )); do
        case $1 in
            --config) CONFIG_FILE=$2; shift 2 ;;
            --config=*) CONFIG_FILE=${1#*=}; shift ;;
            --rediscover) ACTION="rediscover"; shift ;;
            -h|--help) usage; exit $EX_OK ;;
            *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit $EX_CONFIG ;;
        esac
    done
}

load_config() {
    if [[ -n $CONFIG_FILE && -f $CONFIG_FILE ]]; then
        if [[ ! -r $CONFIG_FILE ]]; then
            printf 'Config file not readable: %s\n' "$CONFIG_FILE" >&2
            exit $EX_CONFIG
        fi
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
    LOG_LEVEL_NUM=$(_lvlnum "$LOG_LEVEL")
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

    log_run INFO START pid="$$" host="${HOSTNAME:-$(uname -n 2>/dev/null)}"
    log_run INFO CONFIG targets="$(enc "$TARGETS_FILE")" scan_interval="$SCAN_INTERVAL" \
        run_duration="$RUN_DURATION" min_stable_age="$MIN_STABLE_AGE" \
        discovery_interval="$DISCOVERY_INTERVAL" dry_run="$DRY_RUN" \
        log_format="$LOG_FORMAT" log_level="$LOG_LEVEL"

    if ! load_targets; then
        exit $EX_CONFIG
    fi
    local ntargets=${#T_KEY[@]}
    log_run INFO TARGETS_LOADED count="$ntargets"
    if (( ntargets == 0 )); then
        log_run WARN NO_TARGETS
        log_run INFO END
        exit $EX_OK
    fi

    # Poll granularity = smallest per-target scan interval.
    local tick=$SCAN_INTERVAL i
    for (( i = 0; i < ntargets; i++ )); do
        (( T_SCAN[i] < tick )) && tick=${T_SCAN[i]}
    done
    (( tick < 1 )) && tick=1

    local cycle=0 first=1 now
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
            scanned="${RUN_SCANNED[$k]:-0}" cycles="$cycle"
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
