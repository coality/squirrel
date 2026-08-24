#!/usr/bin/env bash
#
# End-to-end test suite for archive-input.sh — pure bash, no external deps.
# Each test builds an isolated sandbox, runs the real script against it, and
# asserts on the filesystem, the logs and the exit code. Exits non-zero if any
# assertion fails.

set -uo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd -P)
SCRIPT="$ROOT/archive-input.sh"

# shellcheck source=tests/lib/assert.sh
source "$HERE/lib/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/archive-input-e2e.XXXXXX")
cleanup() { chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
new_case() {
    local d; d=$(mktemp -d "$WORK/case.XXXXXX")
    mkdir -p "$d/state" "$d/logs"
    : > "$d/targets.tsv"
    printf '%s' "$d"
}

write_conf() {  # dir [extra config lines...]
    local d=$1; shift
    {
        cat <<EOF
INPUT_DIR_NAME="input"
SCAN_INTERVAL=1
RUN_DURATION=0
MIN_STABLE_AGE=0
REQUIRE_MOUNT=false
HASH_CMD="sha256sum"
DRY_RUN=false
DISCOVERY_INTERVAL=1800
USE_DIR_MTIME_SKIP=true
LOG_LEVEL="DEBUG"
LOG_FORMAT="text"
LOG_ROTATE_MAX_BYTES=10485760
LOG_ROTATE_KEEP=7
AUDIT_LOG=true
TARGETS_FILE="$d/targets.tsv"
STATE_DIR="$d/state"
LOG_DIR="$d/logs"
LOCK_FILE="$d/run.lock"
EOF
        local kv; for kv in "$@"; do printf '%s\n' "$kv"; done
    } > "$d/conf"
}

add_target() {  # dir project env src arc [idn] [scan] [enabled]
    local d=$1 p=$2 e=$3 src=$4 arc=$5 idn=${6:--} scan=${7:--} en=${8:-true}
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$e" "$src" "$arc" "$idn" "$scan" "$en" >> "$d/targets.tsv"
}

run() { bash "$SCRIPT" --config "$1/conf"; }

oplog() { printf '%s/logs/%s__%s/operations.log' "$1" "$2" "$3"; }
auditlog() { printf '%s/logs/%s__%s/audit.log' "$1" "$2" "$3"; }
ledger() { printf '%s/state/%s__%s.ledger.tsv' "$1" "$2" "$3"; }

# NUL-based count so that file names containing newlines count as one file.
count_files() { find "$1" -type f -print0 2>/dev/null | tr -dc '\0' | wc -c | tr -d ' '; }

fingerprint() {  # names + contents fingerprint of a directory tree
    ( cd "$1" 2>/dev/null && find . -type f -print0 2>/dev/null | LC_ALL=C sort -z |
        while IFS= read -r -d '' f; do
            printf '%s|%s\n' "$f" "$(sha256sum -- "$f" 2>/dev/null | cut -d' ' -f1)"
        done ) | sha256sum | cut -d' ' -f1
}

title() { printf '\n== %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_multitarget_and_isolation() {  # matrix 1,4,12,13,21
    title "multi-target, mirror depth, ledger/log isolation, atomic copy"
    local d; d=$(new_case)
    mkdir -p "$d/srcA/input" "$d/srcB/deep/nested/input"
    echo aaa > "$d/srcA/input/a.txt"
    echo bbb > "$d/srcB/deep/nested/input/b.txt"
    add_target "$d" projA prod "$d/srcA" "$d/arcA"
    add_target "$d" projB prod "$d/srcB" "$d/arcB"
    write_conf "$d"
    run "$d"; local rc=$?
    assert_exit "$rc" 0 "run"
    assert_file "$d/arcA/input/a.txt" "A mirror"
    assert_file "$d/arcB/deep/nested/input/b.txt" "B mirror depth"
    assert_grep "$(oplog "$d" projA prod)" 'event=COPIED'
    assert_nogrep "$(oplog "$d" projA prod)" 'project=projB' "no cross-target logs"
    assert_nogrep "$(ledger "$d" projA prod)" 'b.txt' "no cross-target ledger"
    assert_grep "$d/logs/_run.log" 'event=START'
    assert_grep "$d/logs/_run.log" 'event=RUN_SUMMARY'
    assert_nogrep "$d/logs/_run.log" 'event=COPIED' "_run.log has no archive events"
    assert_eq 0 "$(find "$d/arcA" -name '*.tmp.*' | wc -l | tr -d ' ')" "no tmp residue"
}

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

test_enabled_false() {  # matrix 3
    title "enabled=false target is ignored"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc" - - false
    write_conf "$d"
    run "$d"
    assert_eq 0 "$(count_files "$d/arc")" "nothing archived"
    assert_nofile "$d/logs/p__e/operations.log" "no per-target log"
}

test_copy_and_audit() {  # matrix 5
    title "initial copy fills ledger and audit"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo hello > "$d/src/input/f.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_file "$(ledger "$d" p e)"
    assert_grep "$(ledger "$d" p e)" 'input/f.txt'
    assert_grep "$(auditlog "$d" p e)" 'action=COPIED'
    assert_grep "$(auditlog "$d" p e)" 'input/f.txt'
}

test_idempotence_and_dirskip() {  # matrix 6,7,24
    title "idempotence + SKIP_DIR_UNCHANGED on a no-op second run"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo hello > "$d/src/input/f.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "one file after run 1"
    : > "$(oplog "$d" p e)"
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "still one file after run 2"
    assert_grep "$(oplog "$d" p e)" 'event=SKIP_DIR_UNCHANGED'
    assert_nogrep "$(oplog "$d" p e)" 'event=COPIED' "no re-copy"
}

test_versioning_and_revert() {  # matrix 8,9
    title "versioning on changed content, no re-copy on revert"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    # Explicit, distinct mtimes/sizes so the (path,size,mtime) fast-path never
    # hides a genuine content change (1-second mtime granularity otherwise).
    printf 'v1\n' > "$d/src/input/test.xml"
    touch -d '2001-01-01 10:00:00' "$d/src/input/test.xml"
    add_target "$d" p e "$d/src" "$d/arc"
    # skip disabled so in-place content changes are always detected
    write_conf "$d" 'USE_DIR_MTIME_SKIP=false'
    run "$d"
    assert_file "$d/arc/input/test.xml" "base version"
    printf 'version-two-longer\n' > "$d/src/input/test.xml"
    touch -d '2001-01-01 10:00:05' "$d/src/input/test.xml"
    run "$d"
    assert_eq 2 "$(count_files "$d/arc")" "base + timestamped version"
    assert_file "$d/arc/input/test.xml" "original kept"
    assert_grep "$(oplog "$d" p e)" 'event=VERSIONED'
    # revert to v1 content with a fresh mtime (hash already archived -> skip)
    printf 'v1\n' > "$d/src/input/test.xml"
    touch -d '2001-01-01 10:00:10' "$d/src/input/test.xml"
    : > "$(oplog "$d" p e)"
    run "$d"
    assert_eq 2 "$(count_files "$d/arc")" "revert adds nothing"
    assert_grep "$(oplog "$d" p e)" 'event=SKIP_SAME_HASH'
}

test_stability() {  # matrix 10
    title "unstable file skipped, archived once stable"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo data > "$d/src/input/f.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'MIN_STABLE_AGE=3600' 'USE_DIR_MTIME_SKIP=false'
    run "$d"
    assert_eq 0 "$(count_files "$d/arc")" "too recent -> not archived"
    assert_grep "$(oplog "$d" p e)" 'event=SKIP_UNSTABLE'
    touch -d '2 hours ago' "$d/src/input/f.txt"
    run "$d"
    assert_eq 1 "$(count_files "$d/arc")" "archived once stable"
}

test_source_readonly() {  # matrix 11
    title "source tree is never modified"
    local d; d=$(new_case)
    mkdir -p "$d/src/a/input" "$d/src/b/input"
    echo one > "$d/src/a/input/one.txt"
    echo two > "$d/src/b/input/two.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    local before after
    before=$(fingerprint "$d/src")
    run "$d"
    after=$(fingerprint "$d/src")
    assert_eq "$before" "$after" "source fingerprint unchanged"
    assert_eq 2 "$(count_files "$d/arc")" "both archived"
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
    assert_grep "$(oplog "$d" p e)" '"event":"COPIED"'
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

test_exit_config() {  # matrix 16 (config)
    title "exit 1 on unreadable targets file"
    local d; d=$(new_case)
    write_conf "$d" "TARGETS_FILE=\"$d/nope.tsv\""
    run "$d"; local rc=$?
    assert_exit "$rc" 1 "config error"
    assert_grep "$d/logs/_run.log" 'event=TARGETS_UNREADABLE'
}

test_exit_notarget() {  # matrix 16 (no target), 19
    title "exit 2 when the only source is missing (REQUIRE_MOUNT)"
    local d; d=$(new_case)
    add_target "$d" p e "$d/does-not-exist" "$d/arc"
    write_conf "$d" 'REQUIRE_MOUNT=true'
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
    run "$d"; local rc=$?
    chmod 755 "$d/arc"
    assert_exit "$rc" 4 "archive error"
    assert_grep "$(oplog "$d" p e)" 'event=COPY_FAILED'
}

test_lock_busy() {  # matrix 17
    title "exit 3 when another instance holds the lock"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    ( exec 8> "$d/run.lock"; flock 8; sleep 3 ) &
    local holder=$!
    sleep 0.4
    run "$d"; local rc=$?
    wait "$holder" 2>/dev/null
    assert_exit "$rc" 3 "lock busy"
    assert_grep "$d/logs/_run.log" 'event=LOCK_BUSY'
}

test_dry_run() {  # matrix 18
    title "DRY_RUN writes nothing but logs the intended action"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d" 'DRY_RUN=true'
    run "$d"
    assert_eq 0 "$(count_files "$d/arc")" "nothing archived"
    assert_nofile "$(ledger "$d" p e)" "no ledger written"
    assert_grep "$(oplog "$d" p e)" 'dry="1"'
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
    assert_eq 2 "$(count_files "$d/arc")" "both weird names archived"
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
    assert_file "$d/state/.force-rediscover" "marker created"
    run "$d"
    assert_file "$d/arc/b/input/b.txt" "discovered after --rediscover"
    assert_nofile "$d/state/.force-rediscover" "marker consumed"
    assert_grep "$d/logs/_run.log" 'event=FORCE_REDISCOVER'
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

test_ledger_corrupt() {  # matrix 27
    title "corrupted ledger makes the target refuse to run"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    printf 'garbage-without-tabs\n' > "$(ledger "$d" p e)"
    add_target "$d" p e "$d/src" "$d/arc"
    write_conf "$d"
    run "$d"
    assert_grep "$(oplog "$d" p e)" 'event=LEDGER_CORRUPT'
    assert_eq 0 "$(count_files "$d/arc")" "nothing archived on corrupt ledger"
}

test_duplicate_target() {  # matrix 28
    title "duplicate (project,env) rejected, first kept"
    local d; d=$(new_case)
    mkdir -p "$d/src/input"
    echo x > "$d/src/input/x.txt"
    add_target "$d" p e "$d/src" "$d/arc"
    add_target "$d" p e "$d/src2" "$d/arc2"
    write_conf "$d"
    run "$d"
    assert_grep "$d/logs/_run.log" 'event=TARGET_DUPLICATE'
    assert_file "$d/arc/input/x.txt" "first target processed"
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
    assert_file "$d/arc/input/good.txt" "readable file archived"
    assert_grep "$(oplog "$d" p e)" 'event=HASH_FAILED'
    assert_exit "$rc" 0 "run did not crash"
}

# ---------------------------------------------------------------------------
# Run all
# ---------------------------------------------------------------------------
main() {
    [[ -f $SCRIPT ]] || { printf 'Script not found: %s\n' "$SCRIPT" >&2; exit 2; }

    test_multitarget_and_isolation
    test_defaults_inheritance
    test_enabled_false
    test_copy_and_audit
    test_idempotence_and_dirskip
    test_versioning_and_revert
    test_stability
    test_source_readonly
    test_json_logging
    test_log_rotation
    test_exit_config
    test_exit_notarget
    test_exit_archive_error
    test_lock_busy
    test_dry_run
    test_weird_names
    test_discovery_cache
    test_force_rediscovery
    test_antioubli
    test_dirskip_disabled
    test_ledger_corrupt
    test_duplicate_target
    test_resilience_unreadable_file

    printf '\n=========================================\n'
    printf 'Results: %d passed, %d failed\n' "$ASSERT_PASS" "$ASSERT_FAIL"
    printf '=========================================\n'
    (( ASSERT_FAIL == 0 ))
}

main "$@"
