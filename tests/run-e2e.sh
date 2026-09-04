#!/usr/bin/env bash
#
# End-to-end test suite for file-deploy.sh — pure bash, no external deps.
# Each test builds an isolated sandbox, runs the real script against it, and
# asserts on the filesystem, the logs and the exit code. Exits non-zero if any
# assertion fails.

set -uo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd -P)
SCRIPT="$ROOT/file-deploy.sh"

# shellcheck source=tests/lib/assert.sh
source "$HERE/lib/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/file-deploy-e2e.XXXXXX")
cleanup() { chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
new_case() {
    local d; d=$(mktemp -d "$WORK/case.XXXXXX")
    mkdir -p "$d/state" "$d/logs"
    printf '%s' "$d"
}

write_conf() {  # dir [extra config lines...]
    local d=$1; shift
    local inst src dep idn
    IFS=$'\t' read -r inst src dep idn < "$d/.pair"
    {
        cat <<EOF
INSTANCE_ID="$inst"
SOURCE_DIR="$src"
DEPLOY_DIR="$dep"
INPUT_DIR_NAME="$idn"
SCAN_INTERVAL=1
RUN_DURATION=0
MIN_STABLE_AGE=0
HASH_CMD="sha256sum"
DRY_RUN=false
DISCOVERY_INTERVAL=1800
USE_DIR_MTIME_SKIP=true
LOCAL_ARCHIVE_DIR="archive"
LOG_LEVEL="DEBUG"
LOG_FORMAT="text"
LOG_ROTATE_MAX_BYTES=10485760
LOG_ROTATE_KEEP=7
AUDIT_LOG=true
STATE_DIR="$d/state/$inst"
LOG_DIR="$d/logs/$inst"
LOCK_FILE="$d/run-$inst.lock"
EOF
        local kv; for kv in "$@"; do printf '%s\n' "$kv"; done
    } > "$d/conf"
}

# One configuration = one source/destination pair. The instance is named
# <project>__<env> so the log and state paths keep the shape the assertions use.
add_target() {  # dir project env source deploy [idn] [scan] [enabled]
    local d=$1 p=$2 e=$3 src=$4 dep=$5 idn=${6:--}
    [[ $idn == - ]] && idn=input
    printf '%s\t%s\t%s\t%s\n' "${p}__${e}" "$src" "$dep" "$idn" > "$d/.pair"
}

# run_shimmed <shim_dir> <case_dir> [env...]: run with a fake cp/rm ahead on
# PATH, to reach the two branches that a real filesystem will not produce on
# demand (a writer racing the copy, an unlinkable source file).
run_shimmed() { local shim=$1 d=$2; shift 2; env "$@" PATH="$shim:$PATH" bash "$SCRIPT" --config "$d/conf"; }

# make_shim <dir> <tool> <body>: put a fake <tool> ahead on PATH for one case.
make_shim() {
    local dir=$1 tool=$2 body=$3
    mkdir -p "$dir"
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$body"; } > "$dir/$tool"
    chmod +x "$dir/$tool"
}

run() { bash "$SCRIPT" --config "$1/conf"; }

oplog() { printf '%s/logs/%s__%s/file-deploy.log' "$1" "$2" "$3"; }
auditlog() { printf '%s/logs/%s__%s/audit.log' "$1" "$2" "$3"; }
deployed_mark() { printf '%s/state/%s__%s/deployed' "$1" "$2" "$3"; }

# NUL-based counts so that file names containing newlines count as one file.
# The root sentinels are bookkeeping, never content.
_MARKERS=( ! -name '.file-deploy-root' )

# Everything under a tree (deployment trees, or a source including its archives).
count_files() {
    find "$1" -type f "${_MARKERS[@]}" -print0 2>/dev/null | tr -dc '\0' | wc -c | tr -d ' '
}

# Files still waiting in the source: everything EXCEPT the local archives.
# In move mode the steady state of a pickup directory is zero.
count_pending() {
    local arc=${2:-archive}
    find "$1" -type d -name "$arc" -prune -o -type f "${_MARKERS[@]}" -print0 2>/dev/null |
        tr -dc '\0' | wc -c | tr -d ' '
}

# Files sitting in the local archive directories of a source tree.
count_archived() {
    local arc=${2:-archive}
    find "$1" -type d -name "$arc" -exec find {} -type f -print0 \; 2>/dev/null |
        tr -dc '\0' | wc -c | tr -d ' '
}

fingerprint() {  # names + contents fingerprint of a directory tree
    ( cd "$1" 2>/dev/null && find . -type f "${_MARKERS[@]}" -print0 2>/dev/null |
        LC_ALL=C sort -z |
        while IFS= read -r -d '' f; do
            printf '%s|%s\n' "$f" "$(sha256sum -- "$f" 2>/dev/null | cut -d' ' -f1)"
        done ) | sha256sum | cut -d' ' -f1
}

# Digest of the CONTENTS of a tree, ignoring path and name. Move mode relocates
# files, so this is what proves "the same bytes are still there, elsewhere".
content_digest() {
    ( find "$1" -type f "${_MARKERS[@]}" -print0 2>/dev/null |
        while IFS= read -r -d '' f; do sha256sum -- "$f" | cut -d' ' -f1; done ) |
        LC_ALL=C sort | sha256sum | cut -d' ' -f1
}

title() { printf '\n== %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


test_defaults_inheritance() {  # matrix 2
    title "default resolution ('-' inherits INPUT_DIR_NAME)"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc" - - true
    write_conf "$d"
    run "$d"
    assert_file "$d/arc/input/x.txt" "inherited input dir name"
}


test_copy_and_audit() {  # matrix 5
    title "a move is recorded in the audit trail"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo hello > "$d/src/input/f.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_grep "$(auditlog "$d" p e)" 'action=DEPLOYED'
    assert_grep "$(auditlog "$d" p e)" 'relpath="input/f.txt"'
    assert_grep "$(auditlog "$d" p e)" 'archive="input/archive/f.txt"'
    # The mirror makes the relative path identical on both sides, so there is no
    # second path field to carry: a constant tells the reader nothing.
    assert_nogrep "$(auditlog "$d" p e)" 'target=' "no redundant target field"
    assert_file "$(deployed_mark "$d" p e)" "target recorded as having deployed"
}

test_idempotence_and_dirskip() {  # matrix 6,7,24
    title "a drained pickup dir deploys nothing again and then settles"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo hello > "$d/src/input/f.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "one file deployed"
    assert_eq 0 "$(count_pending "$d/src")" "pickup dir drained"
    # Run 2 still has to look: our own move changed the directory's mtime.
    : > "$(oplog "$d" p e)"
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "still one file after run 2"
    assert_nogrep "$(oplog "$d" p e)" 'event=DEPLOYED' "nothing left to deploy"
    # Run 3: nothing has changed since run 2, so the mtime skip finally fires.
    : > "$(oplog "$d" p e)"
    run "$d"
    assert_grep "$(oplog "$d" p e)" 'event=SKIP_DIR_UNCHANGED'
}

test_versioning_and_revert() {  # matrix 8,9
    title "changed content overwrites the deployment and versions the archive"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    printf 'v1\n' > "$d/src/input/test.xml"
    touch -d '2001-01-01 10:00:00' "$d/src/input/test.xml"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_file "$d/arc/input/test.xml" "deployed"
    assert_eq 1 "$(count_archived "$d/src")" "archived once"

    # Same name, new content: the deployment tree holds the CURRENT state, so it
    # is overwritten; the previous version survives in the local archive.
    printf 'version-two-longer\n' > "$d/src/input/test.xml"
    touch -d '2001-01-01 10:00:05' "$d/src/input/test.xml"
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "deployment tree still holds exactly one file"
    assert_eq "version-two-longer" "$(cat "$d/arc/input/test.xml")" "deployment is the new content"
    assert_eq 2 "$(count_archived "$d/src")" "archive keeps both versions"
    assert_grep "$(oplog "$d" p e)" 'event=DEPLOYED_OVERWRITE'
    assert_grep "$(oplog "$d" p e)" 'old_hash='
    # An overwrite destroys a version in the deployment tree: the audit trail
    # must record which digest it replaced.
    assert_grep "$(auditlog "$d" p e)" 'action=DEPLOYED_OVERWRITE'
    assert_grep "$(auditlog "$d" p e)" 'prev_hash='

    # Re-drop the ORIGINAL content: it is deployed again (never left stuck in
    # the source) and reuses its identical archive entry instead of duplicating.
    printf 'v1\n' > "$d/src/input/test.xml"
    touch -d '2001-01-01 10:00:00' "$d/src/input/test.xml"
    : > "$(oplog "$d" p e)"
    run "$d"
    assert_eq 0 "$(count_pending "$d/src")" "re-dropped file is never left behind"
    assert_eq "v1" "$(cat "$d/arc/input/test.xml")" "deployment reverted"
    assert_eq 2 "$(count_archived "$d/src")" "identical archive entry reused, not duplicated"
}

test_stability() {  # matrix 10
    title "unstable file skipped, archived once stable"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo data > "$d/src/input/f.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'MIN_STABLE_AGE=3600' 'USE_DIR_MTIME_SKIP=false'
    run "$d"
    assert_eq 0 "$(count_files "$d/arc")" "too recent -> not deployed"
    assert_grep "$(oplog "$d" p e)" 'event=SKIP_UNSTABLE'
    # The whole point in move mode: an unstable file must not be consumed.
    assert_file "$d/src/input/f.txt" "and above all NOT removed from the source"
    assert_eq 0 "$(count_archived "$d/src")" "nor archived"
    touch -d '2 hours ago' "$d/src/input/f.txt"
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "deployed once stable"
    assert_eq 0 "$(count_pending "$d/src")" "and drained once stable"
}

test_source_drained() {  # matrix 11 (inverted: the source IS modified now)
    title "the source is drained and its bytes survive in the local archive"
    local d; d=$(new_case)
    mkdir -p "$d/src/a/input" "$d/src/b/input"
    echo one > "$d/src/a/input/one.txt"
    echo two > "$d/src/b/input/two.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    local before after
    before=$(content_digest "$d/src")
    run "$d"
    after=$(content_digest "$d/src")
    assert_eq "$before" "$after" "every byte still present in the source tree"
    assert_eq 0 "$(count_pending "$d/src")" "pickup dirs emptied"
    assert_eq 2 "$(count_archived "$d/src")" "both files archived locally"
    assert_file "$d/src/a/input/archive/one.txt" "archived next to where it came from"
    assert_file "$d/src/b/input/archive/two.txt" "archived next to where it came from"
    assert_eq 2 "$(count_files "$d/arc")" "both deployed"
}

test_json_logging() {  # matrix 14
    title "JSON log format produces valid JSON lines"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo j > "$d/src/input/j.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'LOG_FORMAT="json"'
    run "$d"
    assert_grepE "$(oplog "$d" p e)" '^\{"ts":' "starts as JSON object"
    assert_grep "$(oplog "$d" p e)" '"event":"DEPLOYED"'
}

test_log_rotation() {  # matrix 15
    title "operations log rotates past the size threshold"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    local i
    for i in $(seq 1 20); do echo "content $i" > "$d/src/input/f$i.txt"; done
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'LOG_ROTATE_MAX_BYTES=1'
    run "$d"
    assert_file "$(oplog "$d" p e).1" "rotated file exists"
}


test_exit_notarget() {  # matrix 16 (no target), 19
    title "exit 2 when the only source is missing"
    local d; d=$(new_case)
    add_target "$d" p e "$d/does-not-exist" "$d/arc"
    write_conf "$d"
    run "$d"; local rc=$?
    assert_exit "$rc" 2 "no usable target"
    assert_grep "$(oplog "$d" p e)" 'event=MOUNT_MISSING'
}

test_exit_archive_error() {  # matrix 16 (archive), G2/G3
    title "exit 4 when the archive root is not writable"
    local d; d=$(new_case)
    mkdir -p "$d/src/input" "$d/arc"
    echo x > "$d/src/input/x.txt"
    chmod 555 "$d/arc"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d" 2>"$d/stderr"; local rc=$?
    chmod 755 "$d/arc"
    assert_exit "$rc" 4 "archive error"
    assert_grep "$(oplog "$d" p e)" 'event=DEPLOY_UNAVAILABLE'
    assert_eq 0 "$(wc -c < "$d/stderr" | tr -d ' ')" "no shell noise on stderr"
    assert_eq 0 "$(count_files "$d/arc")" "nothing deployed"
    assert_file "$d/src/input/x.txt" "and the source is untouched"
    assert_eq 0 "$(count_archived "$d/src")" "nothing archived either"
}

test_copy_failed_midtree() {  # per-file DEPLOY_FAILED once the deploy root is fine
    title "exit 4 + DEPLOY_FAILED when a destination subdir is not writable"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo a > "$d/src/input/a.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_file "$d/arc/input/a.txt" "first file archived"
    # archive root stays writable (marker ok), the mirrored subdir does not
    echo b > "$d/src/input/b.txt"
    chmod 555 "$d/arc/input"
    run "$d"; local rc=$?
    chmod 755 "$d/arc/input"
    assert_exit "$rc" 4 "deploy error"
    assert_grep "$(oplog "$d" p e)" 'event=DEPLOY_FAILED'
    assert_file "$d/src/input/b.txt" "the file that failed to deploy is kept"
    assert_nofile "$d/src/input/archive/b.txt" "and was not archived"
}

test_lock_busy() {  # matrix 17
    title "exit 3 when another instance holds the lock"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    ( exec 8> "$d/run-p__e.lock"; flock 8; sleep 3 ) &
    local holder=$!
    sleep 0.4
    run "$d"; local rc=$?
    wait "$holder" 2>/dev/null
    assert_exit "$rc" 3 "lock busy"
    assert_grep "$(oplog "$d" p e)" 'event=LOCK_BUSY'
}

test_dry_run() {  # matrix 18
    title "DRY_RUN writes nothing but logs the intended action"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'DRY_RUN=true'
    local before; before=$(fingerprint "$d/src")
    run "$d"
    assert_eq 0 "$(count_files "$d/arc")" "nothing deployed"
    assert_nofile "$(deployed_mark "$d" p e)" "no state written"
    assert_grep "$(oplog "$d" p e)" 'dry="1"'
    # A rehearsal of a destructive tool must be provably inert.
    assert_eq "$before" "$(fingerprint "$d/src")" "source byte-identical after a dry run"
    assert_nofile "$d/src/input/archive" "no archive directory created"
    assert_grep "$(oplog "$d" p e)" 'event=WOULD_MOVE'
}

test_weird_names() {  # matrix 20
    title "files with spaces / UTF-8 / newline are archived"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo one > "$d/src/input/a b é.txt"
    printf 'two\n' > "$d/src/input/line"$'\n'"break.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_file "$d/arc/input/a b é.txt" "space + utf8 name"
    assert_eq 2 "$(count_files "$d/arc")" "both weird names deployed"
    assert_file "$d/src/input/archive/a b é.txt" "and archived under the same name"
    assert_eq 2 "$(count_archived "$d/src")" "both archived"
    assert_eq 0 "$(count_pending "$d/src")" "both drained"
}

test_discovery_cache() {  # matrix 23
    title "new input dir found only after rediscovery"
    local d; d=$(new_case)
    mkdir -p "$d/src/a/input"
    echo a > "$d/src/a/input/a.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'DISCOVERY_INTERVAL=1800'
    run "$d"
    assert_file "$d/arc/a/input/a.txt" "initial archive"
    mkdir -p "$d/src/b/input"
    echo b > "$d/src/b/input/b.txt"
    run "$d"
    assert_nofile "$d/arc/b/input/b.txt" "new dir not yet discovered"
    write_conf "$d" 'DISCOVERY_INTERVAL=0'
    run "$d"
    assert_file "$d/arc/b/input/b.txt" "discovered after rediscovery"
}

test_subdir_selection() {  # input + direct subdirs only, never deeper
    title "collect files in input AND its direct subdirs, never sub-sub-dirs"
    local d; d=$(new_case)
    mkdir -p "$d/src/A/input/supplier/archive"
    echo direct > "$d/src/A/input/direct.txt"
    echo sub    > "$d/src/A/input/supplier/sub.txt"
    echo deep   > "$d/src/A/input/supplier/archive/deep.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_file   "$d/arc/A/input/direct.txt"                 "file directly in input"
    assert_file   "$d/arc/A/input/supplier/sub.txt"           "file in a direct subdir"
    assert_nofile "$d/arc/A/input/supplier/archive/deep.txt"  "sub-sub-dir ignored"
    assert_eq 2 "$(count_files "$d/arc")" "exactly two files"
    assert_grep "$(oplog "$d" p e)" 'scan_dirs="2"'
}

test_new_subdir_immediate() {  # new direct subdir picked up next cycle (no rediscovery)
    title "a new direct subdir is seen on the next cycle, without rediscovery"
    local d; d=$(new_case)
    mkdir -p "$d/src/input/s1"
    echo f1 > "$d/src/input/s1/f1.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'DISCOVERY_INTERVAL=1800'   # no rediscovery between the two runs
    run "$d"
    assert_file "$d/arc/input/s1/f1.txt" "initial subdir archived"
    mkdir -p "$d/src/input/s2"
    echo f2 > "$d/src/input/s2/f2.txt"
    run "$d"
    assert_file "$d/arc/input/s2/f2.txt" "new subdir seen immediately (bulk readdir per cycle)"
}

test_discovery_maxdepth() {  # DISCOVERY_MAXDEPTH caps how deep input dirs are located
    title "DISCOVERY_MAXDEPTH limits input-dir discovery depth"
    local d; d=$(new_case)
    mkdir -p "$d/src/a/b/c/input"       # input at depth 4
    echo deep > "$d/src/a/b/c/input/f.txt"
    mkdir -p "$d/src/shallow/input"     # input at depth 2
    echo ok > "$d/src/shallow/input/g.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'DISCOVERY_MAXDEPTH=3'
    run "$d"
    assert_file   "$d/arc/shallow/input/g.txt" "shallow input found"
    assert_nofile "$d/arc/a/b/c/input/f.txt"   "input beyond maxdepth not found"
}

test_exclude_subdir() {  # EXCLUDE_DIR_PATTERNS ignores a matching subdir
    title "EXCLUDE_DIR_PATTERNS ignores a matching subdir"
    local d; d=$(new_case)
    mkdir -p "$d/src/input/supplier" "$d/src/input/archived"
    echo direct > "$d/src/input/direct.txt"
    echo s      > "$d/src/input/supplier/s.txt"
    echo a      > "$d/src/input/archived/a.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" "EXCLUDE_DIR_PATTERNS=('*archived*')"
    run "$d"
    assert_file   "$d/arc/input/direct.txt"     "input direct file kept"
    assert_file   "$d/arc/input/supplier/s.txt" "normal subdir kept"
    assert_nofile "$d/arc/input/archived/a.txt" "excluded subdir ignored"
    assert_eq 2 "$(count_files "$d/arc")" "two files"
    assert_grep "$(oplog "$d" p e)" 'event=EXCLUDED_DIR'
}

test_exclude_case_insensitive() {  # matching is case-insensitive
    title "exclusion is case-insensitive"
    local d; d=$(new_case)
    mkdir -p "$d/src/input/AvanteamArchive"
    echo x > "$d/src/input/AvanteamArchive/x.txt"
    echo y > "$d/src/input/y.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" "EXCLUDE_DIR_PATTERNS=('*archive*')"
    run "$d"
    assert_file   "$d/arc/input/y.txt" "input direct file kept"
    assert_nofile "$d/arc/input/AvanteamArchive/x.txt" "CamelCase Archive excluded"
}

test_exclude_prune_deep() {  # excluded dir pruned even if it holds input dirs
    title "excluded dir is pruned even when it contains input dirs"
    local d; d=$(new_case)
    mkdir -p "$d/src/proj/archived/deep/input" "$d/src/proj/live/input"
    echo h > "$d/src/proj/archived/deep/input/hidden.txt"
    echo o > "$d/src/proj/live/input/ok.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" "EXCLUDE_DIR_PATTERNS=('*archived*')"
    run "$d"
    assert_file   "$d/arc/proj/live/input/ok.txt" "live input archived"
    assert_nofile "$d/arc/proj/archived/deep/input/hidden.txt" "input under archived pruned"
    assert_eq 1 "$(count_files "$d/arc")" "only one file"
}

test_exclude_default_off() {  # default empty -> nothing excluded
    title "no patterns -> archived subdir is archived (unchanged default)"
    local d; d=$(new_case)
    mkdir -p "$d/src/input/archived"
    echo a > "$d/src/input/archived/a.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_file "$d/arc/input/archived/a.txt" "archived included when no exclude patterns"
}

test_force_rediscovery() {  # manual --rediscover
    title "--rediscover picks up a new input dir before DISCOVERY_INTERVAL"
    local d; d=$(new_case)
    mkdir -p "$d/src/a/input"
    echo a > "$d/src/a/input/a.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'DISCOVERY_INTERVAL=1800'
    run "$d"
    assert_file "$d/arc/a/input/a.txt" "initial archive"
    mkdir -p "$d/src/b/input"
    echo b > "$d/src/b/input/b.txt"
    run "$d"
    assert_nofile "$d/arc/b/input/b.txt" "new dir not yet discovered"
    # request manual rediscovery
    bash "$SCRIPT" --rediscover --config "$d/conf"; local rc=$?
    assert_exit "$rc" 0 "--rediscover exits ok"
    assert_file "$d/state/p__e/.force-rediscover" "marker created"
    run "$d"
    assert_file "$d/arc/b/input/b.txt" "discovered after --rediscover"
    assert_nofile "$d/state/p__e/.force-rediscover" "marker consumed"
    assert_grep "$(oplog "$d" p e)" 'event=FORCE_REDISCOVER'
}

test_antioubli() {  # matrix 25
    title "directory left unsettled while a file is unstable"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo A > "$d/src/input/A.txt"
    touch -d '2001-01-01 09:00:00' "$d/src/input/A.txt"      # A stable
    touch -d '2001-01-01 10:00:00' "$d/src/input"            # dir mtime = dmt1
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'MIN_STABLE_AGE=3600'
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "A archived, dir settled at dmt1"
    # New fresh file B; force a distinct, fixed dir mtime (dmt2). B is unstable.
    echo B > "$d/src/input/B.txt"
    touch -d '2001-01-01 11:00:00' "$d/src/input"            # dir mtime = dmt2 != dmt1
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "B still unstable, dir left unsettled"
    # Make B old; touching the file does NOT change the dir mtime (still dmt2).
    # It must still be picked up because the dir was never settled.
    touch -d '2001-01-01 08:00:00' "$d/src/input/B.txt"
    run "$d"
    assert_eq 2 "$(count_files "$d/arc")" "B archived (dir was not settled)"
}

test_dirskip_disabled() {  # matrix 26
    title "USE_DIR_MTIME_SKIP=false rescans every cycle"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'USE_DIR_MTIME_SKIP=false'
    run "$d"
    : > "$(oplog "$d" p e)"
    run "$d"
    assert_grep "$(oplog "$d" p e)" 'event=DIR_RESCAN'
    assert_nogrep "$(oplog "$d" p e)" 'event=SKIP_DIR_UNCHANGED'
}



test_resilience_unreadable_file() {  # matrix 22 (resilience)
    title "an unreadable file is skipped, others still archived"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo good > "$d/src/input/good.txt"
    echo secret > "$d/src/input/bad.txt"
    chmod 000 "$d/src/input/bad.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"; local rc=$?
    chmod 644 "$d/src/input/bad.txt"
    assert_file "$d/arc/input/good.txt" "readable file deployed"
    assert_grep "$(oplog "$d" p e)" 'event=HASH_FAILED'
    assert_exit "$rc" 0 "run did not crash"
    # Never consume what could not be read back.
    assert_file "$d/src/input/bad.txt" "the unreadable file is kept in the source"
    assert_nofile "$d/src/input/archive/bad.txt" "and never archived"
    assert_nofile "$d/src/input/good.txt" "the readable one did leave"
}

test_multiple_input_names() {  # INPUT_DIR_NAME accepts several exact names
    title "input_dir_name lists several exact, case-sensitive names"
    local d; d=$(new_case)
    mkdir -p "$d/src/a/input" "$d/src/b/Input" "$d/src/c/input_" "$d/src/d/output"
    echo 1 > "$d/src/a/input/x.txt"
    echo 2 > "$d/src/b/Input/y.txt"
    echo 3 > "$d/src/c/input_/z.txt"
    echo 4 > "$d/src/d/output/w.txt"
    add_target "$d" p e "$d/src" "$d/arc" "input,Input,input_"
    write_conf "$d"
    run "$d"
    assert_file   "$d/arc/a/input/x.txt"  "lowercase input matched"
    assert_file   "$d/arc/b/Input/y.txt"  "CamelCase Input matched"
    assert_file   "$d/arc/c/input_/z.txt" "input_ matched"
    assert_nofile "$d/arc/d/output/w.txt" "unlisted name not matched"
    assert_eq 3 "$(count_files "$d/arc")" "exactly three files"
}

test_input_name_with_space() {  # a name containing a space must still work
    title "input_dir_name may contain spaces (comma is the only separator)"
    local d; d=$(new_case)
    mkdir -p "$d/src/a/Input Files" "$d/src/b/input"
    echo 1 > "$d/src/a/Input Files/x.txt"
    echo 2 > "$d/src/b/input/y.txt"
    add_target "$d" p e "$d/src" "$d/arc" "Input Files, input"
    write_conf "$d"
    run "$d"
    assert_file "$d/arc/a/Input Files/x.txt" "name with a space matched"
    assert_file "$d/arc/b/input/y.txt"       "plain name still matched"
    assert_eq 2 "$(count_files "$d/arc")" "both matched"
}

test_input_name_no_globs() {  # names are matched literally, as documented
    title "input_dir_name is literal: no glob expansion"
    local d; d=$(new_case)
    mkdir -p "$d/src/a/input_old" "$d/src/b/input[1]"
    echo 1 > "$d/src/a/input_old/x.txt"
    echo 2 > "$d/src/b/input[1]/y.txt"
    add_target "$d" p e "$d/src" "$d/arc" "input*"
    write_conf "$d"
    run "$d"
    assert_eq 0 "$(count_files "$d/arc")" "'input*' does not glob-match input_old"
    # a name that is all metacharacters is found when it exists literally
    local d2; d2=$(new_case)
    mkdir -p "$d2/src/b/input[1]"
    echo 2 > "$d2/src/b/input[1]/y.txt"
    add_target "$d2" p e "$d2/src" "$d2/arc" "input[1]"
    write_conf "$d2"
    run "$d2"
    assert_file "$d2/arc/b/input[1]/y.txt" "literal bracket name matched"
}

test_input_name_comma_separated() {  # comma is also a valid separator
    title "input_dir_name accepts comma-separated names"
    local d; d=$(new_case)
    mkdir -p "$d/src/a/input" "$d/src/b/Input"
    echo 1 > "$d/src/a/input/x.txt"
    echo 2 > "$d/src/b/Input/y.txt"
    add_target "$d" p e "$d/src" "$d/arc" "input,Input"
    write_conf "$d"
    run "$d"
    assert_eq 2 "$(count_files "$d/arc")" "both matched via comma list"
}

test_input_name_case_sensitive() {  # a single name stays case-sensitive
    title "a single input name is case-sensitive (input != Input)"
    local d; d=$(new_case)
    mkdir -p "$d/src/a/input" "$d/src/b/Input"
    echo 1 > "$d/src/a/input/x.txt"
    echo 2 > "$d/src/b/Input/y.txt"
    add_target "$d" p e "$d/src" "$d/arc" "input"
    write_conf "$d"
    run "$d"
    assert_file   "$d/arc/a/input/x.txt" "lowercase matched"
    assert_nofile "$d/arc/b/Input/y.txt" "different case not matched"
    assert_eq 1 "$(count_files "$d/arc")" "only one file"
}







# ---------------------------------------------------------------------------
# Regression tests for the review findings
# ---------------------------------------------------------------------------

test_archive_unmounted() {
    title "an unmounted archive share is refused, not silently filled"
    local d; d=$(new_case)
    mkdir -p "$d/src/input" "$d/mnt"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/mnt/archive"
    write_conf "$d"
    run "$d"                                    # share mounted: normal archiving
    assert_file "$d/mnt/archive/.file-deploy-root" "marker bootstrapped"
    assert_eq 1 "$(count_files "$d/mnt/archive")" "archived while mounted"
    # The share goes away; the local mount point stays behind, empty.
    rm -rf "$d/mnt/archive"
    echo y > "$d/src/input/y.txt"
    : > "$(oplog "$d" p e)"
    run "$d"; local rc=$?
    assert_exit "$rc" 4 "archive unavailable"
    assert_grep "$(oplog "$d" p e)" 'event=DEPLOY_UNAVAILABLE'
    assert_eq 0 "$(count_files "$d/mnt/archive")" "nothing written to the bare mount point"
    assert_nogrep "$(auditlog "$d" p e)" 'y.txt' "not recorded as moved"
    # The property that matters most: an unmounted destination must never cause
    # a file to be taken out of the source.
    assert_file "$d/src/input/y.txt" "the source file survives the outage"
    assert_nofile "$d/src/input/archive/y.txt" "and is not archived either"
    # Once the share is back, the file that was refused is archived for real.
    mkdir -p "$d/mnt/archive"; : > "$d/mnt/archive/.file-deploy-root"
    run "$d"
    assert_file "$d/mnt/archive/input/y.txt" "archived once remounted"
}

test_archive_marker_adopted() {
    title "a pre-existing archive is adopted, not refused"
    local d; d=$(new_case)
    mkdir -p "$d/src/input" "$d/arc/input"
    echo x > "$d/src/input/x.txt"
    # A tree this configuration has deployed to before, whose marker was lost.
    mkdir -p "$d/state/p__e"; : > "$(deployed_mark "$d" p e)"
    echo old > "$d/arc/input/gone.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"; local rc=$?
    assert_exit "$rc" 0 "adopted, not refused"
    assert_grep "$(oplog "$d" p e)" 'event=DEPLOY_MARKER_ADOPTED'
    assert_file "$d/arc/.file-deploy-root" "marker created"
    assert_file "$d/arc/input/x.txt" "still deploying"
}


test_deep_scan_recovers_stale_mtime() {
    title "the deep pass recovers a directory whose mtime did not move"
    local d; d=$(new_case)
    mkdir -p "$d/src/input" "$d/arc"
    printf 'v1\n' > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'DEEP_SCAN_INTERVAL=3600'
    # Pin the directory mtime to an exact value. The scanner compares against
    # find's %T@, which keeps sub-second precision that `stat -c %Y` truncates,
    # so only a timestamp we set ourselves can be restored byte for byte.
    local pinned='2020-01-01 00:00:00'
    touch -d "$pinned" "$d/src/input"
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "deployed once"
    # A share that fails to bump the directory mtime when a file appears: forge
    # exactly that by putting the pinned mtime back.
    printf 'newcomer\n' > "$d/src/input/y.txt"
    touch -d "$pinned" "$d/src/input"
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "the mtime skip hides it"
    assert_eq 1 "$(count_pending "$d/src")" "and it is still waiting in the source"
    # Make the deep pass due (deterministically, no sleep).
    touch -d '-1 hour' "$d/state/p__e/deepscan"
    touch -d "$pinned" "$d/src/input"
    write_conf "$d" 'DEEP_SCAN_INTERVAL=60'
    run "$d"
    assert_eq 2 "$(count_files "$d/arc")" "the deep pass finds it"
    assert_eq 0 "$(count_pending "$d/src")" "and drains it"
}

test_unreadable_file_settles() {
    title "a permanently unreadable file does not re-warn on every cycle"
    local d; d=$(new_case)
    mkdir -p "$d/src/input" "$d/arc"
    echo ok > "$d/src/input/good.txt"
    echo secret > "$d/src/input/bad.txt"; chmod 000 "$d/src/input/bad.txt"
    add_target "$d" p e "$d/src" "$d/arc" - 1
    write_conf "$d" 'RUN_DURATION=4' 'SCAN_INTERVAL=1' 'DEEP_SCAN_INTERVAL=0' 'LOG_LEVEL="INFO"'
    run "$d"; local rc=$?
    chmod 644 "$d/src/input/bad.txt"
    assert_exit "$rc" 0 "run completes"
    assert_file "$d/arc/input/good.txt" "the readable file is archived"
    assert_eq 1 "$(grep -c 'event=HASH_FAILED' "$(oplog "$d" p e)")" \
        "warned once per run, not once per cycle"
}

test_prehistoric_mtime() {
    title "a file dated before 1970 is archived, not flagged as unreadable"
    local d; d=$(new_case)
    mkdir -p "$d/src/input" "$d/arc"
    echo old > "$d/src/input/old.txt"
    touch -d '1969-01-01 00:00:00' "$d/src/input/old.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'USE_DIR_MTIME_SKIP=false'
    run "$d"
    assert_file "$d/arc/input/old.txt" "pre-1970 file archived"
    assert_nogrep "$(oplog "$d" p e)" 'event=META_UNREADABLE'
    : > "$(oplog "$d" p e)"
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "not re-deployed on the second pass"
    assert_eq 0 "$(count_pending "$d/src")" "and it is drained, not stuck"
}

test_stderr_clean_first_run() {
    title "a first run on a fresh deployment writes nothing to stderr"
    local d; d=$(new_case)
    mkdir -p "$d/src/input" "$d/arc"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'LOG_CONSOLE="never"'
    run "$d" 2>"$d/stderr"
    assert_eq 0 "$(wc -c < "$d/stderr" | tr -d ' ')" "clean stderr (no cron mail)"
    assert_file "$d/arc/input/x.txt" "still archived"
}

# ---------------------------------------------------------------------------
# ON_CONFLICT: what happens when the destination holds different content
# ---------------------------------------------------------------------------

# _conflict_case <dir> <policy>: a deployed "old" plus an incoming "new" under
# the same relative path, ready to run.
_conflict_case() {
    local d=$1 policy=$2
    mkdir -p "$d/src/input" "$d/arc/input"
    printf 'incoming\n' > "$d/src/input/f.txt"
    touch -d '2001-01-01 10:00:00' "$d/src/input/f.txt"
    printf 'already-deployed\n' > "$d/arc/input/f.txt"
    : > "$d/arc/.file-deploy-root"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" "ON_CONFLICT=\"$policy\""
}

test_conflict_overwrite() {
    title "ON_CONFLICT=overwrite replaces the deployed file"
    local d; d=$(new_case); _conflict_case "$d" overwrite
    run "$d"; local rc=$?
    assert_exit "$rc" 0 "run succeeds"
    assert_eq "incoming" "$(cat "$d/arc/input/f.txt")" "destination replaced"
    assert_eq 1 "$(count_files "$d/arc")" "no extra file in the deployment tree"
    assert_eq 0 "$(count_pending "$d/src")" "source drained"
    assert_grep "$(oplog "$d" p e)" 'event=DEPLOYED_OVERWRITE'
    assert_grep "$(auditlog "$d" p e)" 'prev_hash=' "the replaced digest is recorded"
}

test_conflict_version() {
    title "ON_CONFLICT=version deploys alongside and clobbers nothing"
    local d; d=$(new_case); _conflict_case "$d" version
    run "$d"; local rc=$?
    assert_exit "$rc" 0 "run succeeds"
    assert_eq "already-deployed" "$(cat "$d/arc/input/f.txt")" "existing file untouched"
    assert_eq 2 "$(count_files "$d/arc")" "both versions present"
    assert_file "$d/arc/input/f_20010101_100000.txt" "stamped from the SOURCE mtime"
    assert_eq 0 "$(count_pending "$d/src")" "source drained"
    assert_grep "$(oplog "$d" p e)" 'event=DEPLOYED_VERSION'
    # The name is a pure function of (name, source mtime, hash), so re-dropping
    # the same content must land on the same path, not a third file.
    printf 'incoming\n' > "$d/src/input/f.txt"
    touch -d '2001-01-01 10:00:00' "$d/src/input/f.txt"
    run "$d"
    assert_eq 2 "$(count_files "$d/arc")" "a repeat is idempotent"
}

test_conflict_skip() {
    title "ON_CONFLICT=skip leaves the destination stale but drains the source"
    local d; d=$(new_case); _conflict_case "$d" skip
    run "$d"; local rc=$?
    assert_exit "$rc" 0 "not an error"
    assert_eq "already-deployed" "$(cat "$d/arc/input/f.txt")" "destination untouched"
    assert_eq 1 "$(count_files "$d/arc")" "nothing added"
    # Nothing is lost and nothing piles up: the incoming file is archived.
    assert_eq 0 "$(count_pending "$d/src")" "source drained anyway"
    assert_eq "incoming" "$(cat "$d/src/input/archive/f.txt")" "and preserved locally"
    assert_grep "$(oplog "$d" p e)" 'event=DEPLOY_SKIPPED'
}

test_conflict_fail() {
    title "ON_CONFLICT=fail keeps the source file and exits 4"
    local d; d=$(new_case); _conflict_case "$d" fail
    run "$d"; local rc=$?
    assert_exit "$rc" 4 "deploy conflict"
    assert_eq "already-deployed" "$(cat "$d/arc/input/f.txt")" "destination untouched"
    assert_file "$d/src/input/f.txt" "source file kept for a human to resolve"
    assert_eq 0 "$(count_archived "$d/src")" "and not archived either"
    assert_grep "$(oplog "$d" p e)" 'event=DEPLOY_CONFLICT'
}

test_conflict_identical_is_never_a_conflict() {
    title "identical content is not a conflict, whatever the policy"
    local d p
    for p in overwrite version skip fail; do
        d=$(new_case)
        mkdir -p "$d/src/input" "$d/arc/input"
        printf 'same\n' > "$d/src/input/f.txt"
        printf 'same\n' > "$d/arc/input/f.txt"
        : > "$d/arc/.file-deploy-root"
        add_target "$d" p e "$d/src" "$d/arc"
        write_conf "$d" "ON_CONFLICT=\"$p\""
        run "$d"; local rc=$?
        assert_exit "$rc" 0 "$p: run succeeds"
        assert_eq 1 "$(count_files "$d/arc")" "$p: nothing added"
        assert_eq 0 "$(count_pending "$d/src")" "$p: source drained"
    done
}

test_conflict_dry_run_reports_the_policy() {
    title "a rehearsal reports the verdict the policy would apply"
    local d p
    for p in overwrite version skip fail; do
        d=$(new_case); _conflict_case "$d" "$p"
        bash "$SCRIPT" --config "$d/conf" --dry-run >/dev/null 2>&1
        assert_grep "$(oplog "$d" p e)" "on_conflict=\"$p\""
        assert_eq "already-deployed" "$(cat "$d/arc/input/f.txt")" "$p: nothing written"
        assert_file "$d/src/input/f.txt" "$p: source untouched"
    done
}

test_conflict_invalid_value() {
    title "an unknown ON_CONFLICT stops the run instead of guessing"
    local d; d=$(new_case); _conflict_case "$d" ovrewrite
    local out rc
    out=$(run "$d" 2>&1); rc=$?
    assert_exit "$rc" 1 "config error"
    case $out in
        *"Invalid ON_CONFLICT"*) _ok "names the offending value" ;;
        *) _no "clear message, got: [$out]" ;;
    esac
    assert_file "$d/src/input/f.txt" "nothing touched"
}

test_conflict_retry() {
    title "ON_CONFLICT=retry keeps both sides and clears by itself"
    local d; d=$(new_case); _conflict_case "$d" retry
    run "$d"; local rc=$?
    assert_exit "$rc" 0 "a pending collision is not a failure"
    assert_eq "already-deployed" "$(cat "$d/arc/input/f.txt")" "destination untouched"
    assert_file "$d/src/input/f.txt" "source kept for the next attempt"
    assert_eq 0 "$(count_archived "$d/src")" "and not archived yet"
    assert_grep "$(oplog "$d" p e)" 'event=DEPLOY_RETRY'
    # It resolves on its own once the deployed file goes away or changes.
    rm "$d/arc/input/f.txt"
    run "$d"
    assert_eq "incoming" "$(cat "$d/arc/input/f.txt")" "delivered on a later cycle"
    assert_eq 0 "$(count_pending "$d/src")" "and drained"
}

test_report_csv() {
    title "REPORT_DIR writes one CSV row per file that moved"
    local d; d=$(new_case)
    mkdir -p "$d/src/input/sub"
    printf 'one\n' > "$d/src/input/a.txt"
    # A name carrying the delimiter and a quote must survive RFC 4180 quoting.
    printf 'two\n' > "$d/src/input/sub/b,\"x\".txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" "REPORT_DIR=\"$d/reports\""
    run "$d"
    local csv; csv=$(find "$d/reports" -name '*.csv' | head -1)
    assert_file "$csv" "a dated CSV was written"
    assert_grep "$csv" 'run_id,deployed_at,instance,outcome' "header present"
    assert_eq 3 "$(wc -l < "$csv" | tr -d ' ')" "header + one row per file"
    assert_grep "$csv" '"DEPLOYED"'
    assert_grep "$csv" '"a.txt"'
    assert_grep "$csv" '/input/archive/a.txt' "archive path recorded for retrieval"
    # The awkward name must be quoted, with its inner quote doubled.
    assert_grep "$csv" '"b,""x"".txt"' "delimiter and quote escaped"
    # A second run appends to the same day's file instead of starting over.
    printf 'three\n' > "$d/src/input/c.txt"
    run "$d"
    assert_eq 4 "$(wc -l < "$csv" | tr -d ' ')" "appended, header not repeated"
}

test_report_delimiter_and_dry_run() {
    title "REPORT_DELIMITER is honoured, and a rehearsal writes no report"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" "REPORT_DIR=\"$d/reports\"" 'REPORT_DELIMITER=";"'
    bash "$SCRIPT" --config "$d/conf" --dry-run >/dev/null 2>&1
    assert_eq 0 "$(find "$d/reports" -name '*.csv' 2>/dev/null | wc -l)" "rehearsal wrote nothing"
    run "$d"
    local csv; csv=$(find "$d/reports" -name '*.csv' | head -1)
    assert_grep "$csv" 'run_id;deployed_at;instance;outcome' "semicolon header"
    assert_grep "$csv" '"p__e";"DEPLOYED";"x.txt"' "semicolon rows"
}

test_dry_run_flag() {
    title "--dry-run rehearses without touching the config"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"                      # DRY_RUN stays false in the file
    local before; before=$(fingerprint "$d/src")
    bash "$SCRIPT" --config "$d/conf" --dry-run >/dev/null 2>&1; local rc=$?
    assert_exit "$rc" 0 "rehearsal exits cleanly"
    assert_eq 0 "$(count_files "$d/arc")" "nothing deployed"
    assert_eq "$before" "$(fingerprint "$d/src")" "source byte-identical"
    assert_grep "$(oplog "$d" p e)" 'event=WOULD_MOVE'
    # A rehearsal left on is indistinguishable from a run that delivers nothing.
    assert_grep "$(oplog "$d" p e)" 'event=DRY_RUN_ACTIVE'
    assert_grep "$(oplog "$d" p e)" 'source="--dry-run"'
    # The flag is applied after the config, so it cannot be overridden by it.
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "the same command without the flag delivers"
}

test_dry_run_then_real_deploys() {
    title "a rehearsal does not stop the real run that follows it"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'DRY_RUN=true'
    run "$d"
    assert_eq 0 "$(count_files "$d/arc")" "rehearsal deployed nothing"
    assert_nofile "$d/state/p__e/leaves.tsv" "and settled no directory"
    assert_nofile "$d/state/p__e/deepscan" "and did not consume the deep pass"
    # The prescribed workflow: rehearse, then flip DRY_RUN off and run for real.
    # The rehearsal must not have recorded the pickup dir as up to date.
    write_conf "$d"
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "the real run deploys"
    assert_eq 0 "$(count_pending "$d/src")" "and drains the source"
}

test_verbose_flag_wins() {
    title "--verbose is not overridden by LOG_CONSOLE in the config"
    local d; d=$(new_case)
    mkdir -p "$d/src/input" "$d/arc"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'LOG_CONSOLE="never"'
    bash "$SCRIPT" --config "$d/conf" --verbose >/dev/null 2>"$d/stderr"
    assert_grep "$d/stderr" 'event=START' "--verbose mirrors to the terminal"
}

test_config_missing_value() {
    title "--config without a value fails cleanly"
    local out rc
    out=$(bash "$SCRIPT" --config 2>&1); rc=$?
    assert_exit "$rc" 1 "config error"
    case $out in
        *"Missing value for --config"*) _ok "clear message" ;;
        *) _no "clear message, got: [$out]" ;;
    esac
    case $out in
        *"unbound variable"*) _no "raw bash error leaked" ;;
        *) _ok "no raw bash error" ;;
    esac
}

test_discovery_cache_config_change() {
    title "changing input_dir_name invalidates the discovery cache at once"
    local d; d=$(new_case)
    mkdir -p "$d/src/a/input" "$d/src/b/Input" "$d/arc"
    echo 1 > "$d/src/a/input/x.txt"
    echo 2 > "$d/src/b/Input/y.txt"
    add_target "$d" p e "$d/src" "$d/arc" "input"
    write_conf "$d" 'DISCOVERY_INTERVAL=99999'
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "only 'input' discovered"
    add_target "$d" p e "$d/src" "$d/arc" "input,Input"
    write_conf "$d" 'DISCOVERY_INTERVAL=99999'
    : > "$(oplog "$d" p e)"
    run "$d"
    assert_grep "$(oplog "$d" p e)" 'reason="config-changed"'
    assert_eq 2 "$(count_files "$d/arc")" "the new name is picked up on the next cycle"
}

test_audit_rotation() {
    title "audit.log is rotated like the operations log"
    local d; d=$(new_case)
    mkdir -p "$d/src/input" "$d/arc"
    local i
    for i in $(seq 1 40); do printf 'content-%s\n' "$i" > "$d/src/input/f$i.txt"; done
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'LOG_ROTATE_MAX_BYTES=400' 'LOG_ROTATE_KEEP=3'
    run "$d"
    assert_file "$(auditlog "$d" p e).1" "audit.log rotated"
    local sz; sz=$(wc -c < "$(auditlog "$d" p e)" | tr -d ' ')
    if (( sz <= 800 )); then _ok "audit.log kept bounded [$sz]"; else _no "audit.log unbounded [$sz]"; fi
}



# ---------------------------------------------------------------------------
# Move mode: the no-loss properties
# ---------------------------------------------------------------------------

test_local_archive_not_rescanned() {
    title "the local archive is never re-deployed nor re-consumed"
    local d; d=$(new_case)
    mkdir -p "$d/src/proj/input/sub"
    echo one > "$d/src/proj/input/f.txt"
    echo two > "$d/src/proj/input/sub/g.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_eq 2 "$(count_archived "$d/src")" "both archived locally"
    local arc_before; arc_before=$(fingerprint "$d/src")
    : > "$(oplog "$d" p e)"
    run "$d"; run "$d"
    assert_eq "$arc_before" "$(fingerprint "$d/src")" "the source tree stopped changing"
    assert_eq 2 "$(count_files "$d/arc")" "nothing new deployed"
    assert_nofile "$d/arc/proj/input/archive" "no archive dir mirrored into the deployment tree"
    assert_nofile "$d/arc/proj/input/sub/archive" "none from the subdir either"
    assert_nogrep "$(oplog "$d" p e)" 'event=DEPLOYED' "no second deployment"
    assert_grep "$(oplog "$d" p e)" 'event=LOCAL_ARCHIVE_SKIPPED'
}

test_pickup_dir_unwritable() {
    title "an undrainable pickup dir deploys nothing and exits 5"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    chmod 555 "$d/src/input"
    run "$d"; local rc=$?
    chmod 755 "$d/src/input"
    assert_exit "$rc" 5 "source stuck"
    assert_grep "$(oplog "$d" p e)" 'event=SOURCE_NOT_WRITABLE'
    # Deploying out of a directory we cannot then clean would re-deploy forever.
    assert_eq 0 "$(count_files "$d/arc")" "nothing deployed from it"
    assert_file "$d/src/input/x.txt" "the file is untouched"
}

test_source_stuck_exit5() {
    title "deployed but not removable: exit 5, file kept, no duplicate archive"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo a > "$d/src/input/a.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_eq 1 "$(count_archived "$d/src")" "first file archived"
    # The pickup dir stays writable (so the guard passes) but its archive does not.
    chmod 555 "$d/src/input/archive"
    echo b > "$d/src/input/b.txt"
    : > "$(oplog "$d" p e)"
    run "$d"; local rc=$?
    chmod 755 "$d/src/input/archive"
    assert_exit "$rc" 5 "source stuck"
    assert_grep "$(oplog "$d" p e)" 'event=SOURCE_STUCK'
    assert_file "$d/src/input/b.txt" "kept in the source, not lost"
    assert_file "$d/arc/input/b.txt" "but it IS deployed"
    assert_eq 1 "$(count_archived "$d/src")" "no half-written archive entry"
    # Once the obstacle is gone the retry converges, with no duplicate anywhere.
    run "$d"
    assert_eq 0 "$(count_pending "$d/src")" "drained on retry"
    assert_eq 2 "$(count_archived "$d/src")" "exactly two archive entries"
    assert_eq 2 "$(count_files "$d/arc")" "exactly two deployed files"
}

test_retry_after_deploy_failure() {
    title "a failed deployment leaves the source intact and retries cleanly"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo a > "$d/src/input/a.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    chmod 555 "$d/arc/input"
    echo b > "$d/src/input/b.txt"
    run "$d"; local rc=$?
    chmod 755 "$d/arc/input"
    assert_exit "$rc" 4 "deploy failure"
    assert_file "$d/src/input/b.txt" "source kept when the deployment fails"
    assert_eq 1 "$(count_archived "$d/src")" "nothing archived for a file that never deployed"
    run "$d"
    assert_file "$d/arc/input/b.txt" "deployed on retry"
    assert_eq 0 "$(count_pending "$d/src")" "and drained"
    assert_eq 2 "$(count_archived "$d/src")" "exactly one archive entry per file"
}

test_source_changed_during_copy() {
    title "a file rewritten mid-copy is deployed but never removed"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    printf 'start\n' > "$d/src/input/w.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    # A slow writer that appends right after our copy read the file. Only a shim
    # can produce this race on demand.
    make_shim "$d/shim" cp '/bin/cp "$@"; rc=$?
for a in "$@"; do [[ $a == */input/w.txt ]] && printf "grew\n" >> "$a"; done
exit $rc'
    run_shimmed "$d/shim" "$d" >/dev/null 2>&1
    assert_grep "$(oplog "$d" p e)" 'event=SOURCE_CHANGED_DURING_COPY'
    assert_file "$d/src/input/w.txt" "NOT removed: what we deployed is a half-written snapshot"
    assert_eq 0 "$(count_archived "$d/src")" "and not archived either"
    # Without the shim the writer has stopped, so the next pass converges.
    run "$d"
    assert_eq 0 "$(count_pending "$d/src")" "drained once the file settles"
    assert_eq "$(cat "$d/src/input/archive/w.txt")" "$(cat "$d/arc/input/w.txt")" \
        "deployment and archive agree on the final content"
}

# ---------------------------------------------------------------------------
# Move mode: deployment semantics
# ---------------------------------------------------------------------------

test_identical_redrop_moves() {
    title "an identical re-drop is re-deployed, moved, and not duplicated"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    printf 'same\n' > "$d/src/input/f.txt"
    touch -d '2001-01-01 10:00:00' "$d/src/input/f.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    printf 'same\n' > "$d/src/input/f.txt"
    touch -d '2001-01-01 10:00:00' "$d/src/input/f.txt"
    : > "$(oplog "$d" p e)"
    run "$d"
    assert_grep "$(oplog "$d" p e)" 'event=DEPLOYED_IDENTICAL'
    # The point of decision 5: it must never be left stuck in the pickup dir.
    assert_eq 0 "$(count_pending "$d/src")" "removed from the source anyway"
    assert_eq 1 "$(count_archived "$d/src")" "identical archive entry reused"
    assert_eq 1 "$(count_files "$d/arc")" "one deployed file"
}

test_archive_versioning() {
    title "successive contents stack in the archive, not in the deployment tree"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    local i
    for i in 1 2 3; do
        printf 'content-%s\n' "$i" > "$d/src/input/f.txt"
        touch -d "2001-01-0$i 10:00:00" "$d/src/input/f.txt"
        run "$d"
    done
    assert_eq 1 "$(count_files "$d/arc")" "the deployment tree holds only the latest"
    assert_eq "content-3" "$(cat "$d/arc/input/f.txt")" "and it is the latest"
    assert_eq 3 "$(count_archived "$d/src")" "all three versions kept in the archive"
    assert_file "$d/src/input/archive/f.txt" "the first keeps the base name"
    assert_eq 0 "$(count_pending "$d/src")" "source drained"
}

test_local_archive_dir_configurable() {
    title "LOCAL_ARCHIVE_DIR renames the archive and frees the name 'archive'"
    local d; d=$(new_case)
    mkdir -p "$d/src/input/archive"
    echo x > "$d/src/input/x.txt"
    echo y > "$d/src/input/archive/y.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'LOCAL_ARCHIVE_DIR="_bak"'
    run "$d"
    assert_file "$d/src/input/_bak/x.txt" "archived under the configured name"
    # 'archive' is no longer reserved, so it is ordinary deployable content.
    assert_file "$d/arc/input/archive/y.txt" "a dir named 'archive' is deployed again"
    assert_eq 0 "$(count_pending "$d/src" _bak)" "everything drained"
}

test_archived_dirname_still_deployed() {
    title "the archive-dir skip is an exact match: 'archived' is still deployed"
    local d; d=$(new_case)
    mkdir -p "$d/src/input/archived"
    echo a > "$d/src/input/archived/a.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_file "$d/arc/input/archived/a.txt" "'archived' != 'archive'"
    assert_file "$d/src/input/archived/archive/a.txt" "and it gets its own archive dir"
}


# ---------------------------------------------------------------------------
# One configuration = one instance
# ---------------------------------------------------------------------------

test_instance_isolation() {
    title "two configurations share nothing and run concurrently"
    local d; d=$(new_case)
    mkdir -p "$d/srcA/input" "$d/srcB/input"
    echo a > "$d/srcA/input/a.txt"
    echo b > "$d/srcB/input/b.txt"
    # Two configurations in the same directory, distinguished only by their id.
    add_target "$d" compta prod "$d/srcA" "$d/arcA"; write_conf "$d"; mv "$d/conf" "$d/confA"
    add_target "$d" rh     prod "$d/srcB" "$d/arcB"; write_conf "$d"; mv "$d/conf" "$d/confB"
    bash "$SCRIPT" --config "$d/confA" >/dev/null 2>&1
    bash "$SCRIPT" --config "$d/confB" >/dev/null 2>&1
    assert_file "$d/arcA/input/a.txt" "A deployed"
    assert_file "$d/arcB/input/b.txt" "B deployed"
    # Separate state, separate logs -- nothing to mix up.
    assert_file "$d/state/compta__prod/deployed" "A has its own state"
    assert_file "$d/state/rh__prod/deployed"     "B has its own state"
    assert_nogrep "$(oplog "$d" compta prod)" 'b.txt' "A's log has none of B"
    assert_nogrep "$(oplog "$d" rh prod)"     'a.txt' "B's log has none of A"
    # Separate locks, so one does not serialise behind the other.
    assert_file "$d/run-compta__prod.lock"
    assert_file "$d/run-rh__prod.lock"
}

test_state_dir_conflict() {
    title "two configurations pointed at one state dir are refused"
    local d; d=$(new_case)
    mkdir -p "$d/srcA/input" "$d/srcB/input"
    echo a > "$d/srcA/input/a.txt"
    echo b > "$d/srcB/input/b.txt"
    # Default paths make this impossible; force it by overriding STATE_DIR.
    add_target "$d" compta prod "$d/srcA" "$d/arcA"
    write_conf "$d" "STATE_DIR=\"$d/shared\""; mv "$d/conf" "$d/confA"
    add_target "$d" rh prod "$d/srcB" "$d/arcB"
    write_conf "$d" "STATE_DIR=\"$d/shared\""; mv "$d/conf" "$d/confB"
    bash "$SCRIPT" --config "$d/confA" >/dev/null 2>&1
    local out rc
    out=$(bash "$SCRIPT" --config "$d/confB" 2>&1); rc=$?
    assert_exit "$rc" 1 "config error"
    assert_grep "$(oplog "$d" rh prod)" 'event=STATE_DIR_CONFLICT'
    # Refused before anything moved: mixing two instances' caches would make
    # each one mistake the other's "already deployed here" marker for its own.
    assert_file "$d/srcB/input/b.txt" "nothing taken from the second source"
    assert_eq 0 "$(count_files "$d/arcB")" "nothing deployed"
}

test_instance_id_defaults_to_config_name() {
    title "INSTANCE_ID defaults to the configuration file's base name"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"; write_conf "$d"
    # Drop the explicit id and every path override, then rename the file: the id
    # must follow the file, and the paths must follow the id. The script is
    # copied into the sandbox because the defaults hang off ITS directory.
    grep -v '^INSTANCE_ID=' "$d/conf" | grep -v '^STATE_DIR=' | grep -v '^LOG_DIR=' \
        | grep -v '^LOCK_FILE=' > "$d/facturation.conf"
    cp "$SCRIPT" "$d/file-deploy.sh"
    bash "$d/file-deploy.sh" --config "$d/facturation.conf" >/dev/null 2>&1
    assert_file "$d/arc/input/x.txt" "deployed"
    assert_grep "$d/logs/facturation/file-deploy.log" 'instance=facturation'
    assert_file "$d/state/facturation/deployed" "state named after the config"
}

test_missing_source_or_deploy() {
    title "a configuration without both directories is refused"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    add_target "$d" p e "$d/src" "$d/arc"; write_conf "$d"
    local out rc
    out=$(grep -v '^DEPLOY_DIR=' "$d/conf" > "$d/half.conf"; bash "$SCRIPT" --config "$d/half.conf" 2>&1); rc=$?
    assert_exit "$rc" 1 "config error"
    case $out in
        *"SOURCE_DIR and DEPLOY_DIR must both be set"*) _ok "names what is missing" ;;
        *) _no "clear message, got: [$out]" ;;
    esac
}

test_invalid_instance_id() {
    title "an unusable INSTANCE_ID stops the run"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    add_target "$d" p e "$d/src" "$d/arc"; write_conf "$d" 'INSTANCE_ID="../escape"'
    local out rc
    out=$(run "$d" 2>&1); rc=$?
    assert_exit "$rc" 1 "config error"
    case $out in
        *"Invalid INSTANCE_ID"*) _ok "names the offending value" ;;
        *) _no "clear message, got: [$out]" ;;
    esac
}

# ---------------------------------------------------------------------------
# Run all
# ---------------------------------------------------------------------------
main() {
    [[ -f $SCRIPT ]] || { printf 'Script not found: %s\n' "$SCRIPT" >&2; exit 2; }

    test_defaults_inheritance
    test_copy_and_audit
    test_idempotence_and_dirskip
    test_versioning_and_revert
    test_stability
    test_source_drained
    test_json_logging
    test_log_rotation
    test_exit_notarget
    test_exit_archive_error
    test_lock_busy
    test_dry_run
    test_weird_names
    test_discovery_cache
    test_subdir_selection
    test_new_subdir_immediate
    test_discovery_maxdepth
    test_exclude_subdir
    test_exclude_case_insensitive
    test_exclude_prune_deep
    test_exclude_default_off
    test_force_rediscovery
    test_antioubli
    test_dirskip_disabled
    test_resilience_unreadable_file
    test_multiple_input_names
    test_input_name_comma_separated
    test_input_name_case_sensitive
    test_copy_failed_midtree
    test_input_name_with_space
    test_input_name_no_globs
    test_archive_unmounted
    test_archive_marker_adopted
    test_deep_scan_recovers_stale_mtime
    test_unreadable_file_settles
    test_prehistoric_mtime
    test_stderr_clean_first_run
    test_conflict_overwrite
    test_conflict_version
    test_conflict_skip
    test_conflict_fail
    test_conflict_identical_is_never_a_conflict
    test_conflict_dry_run_reports_the_policy
    test_conflict_invalid_value
    test_conflict_retry
    test_report_csv
    test_report_delimiter_and_dry_run
    test_instance_isolation
    test_state_dir_conflict
    test_instance_id_defaults_to_config_name
    test_missing_source_or_deploy
    test_invalid_instance_id
    test_dry_run_flag
    test_dry_run_then_real_deploys
    test_verbose_flag_wins
    test_config_missing_value
    test_discovery_cache_config_change
    test_audit_rotation
    test_local_archive_not_rescanned
    test_pickup_dir_unwritable
    test_source_stuck_exit5
    test_retry_after_deploy_failure
    test_source_changed_during_copy
    test_identical_redrop_moves
    test_archive_versioning
    test_local_archive_dir_configurable
    test_archived_dirname_still_deployed

    printf '\n=========================================\n'
    printf 'Results: %d passed, %d failed\n' "$ASSERT_PASS" "$ASSERT_FAIL"
    printf '=========================================\n'
    (( ASSERT_FAIL == 0 ))
}

main "$@"
