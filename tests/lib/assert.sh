#!/usr/bin/env bash
# Minimal assertion helpers for the pure-bash E2E suite. No external deps.

ASSERT_PASS=0
ASSERT_FAIL=0

_ok() { ASSERT_PASS=$((ASSERT_PASS + 1)); printf '    ok   %s\n' "$1"; }
_no() { ASSERT_FAIL=$((ASSERT_FAIL + 1)); printf '    FAIL %s\n' "$1" >&2; }

assert_eq() {  # expected actual [msg]
    if [[ $1 == "$2" ]]; then _ok "eq ${3:-}: [$2]"; else _no "eq ${3:-}: expected [$1] got [$2]"; fi
}

assert_file() {  # path [msg]
    if [[ -e $1 ]]; then _ok "exists ${2:-$1}"; else _no "missing ${2:-$1}"; fi
}

assert_nofile() {  # path [msg]
    if [[ ! -e $1 ]]; then _ok "absent ${2:-$1}"; else _no "unexpectedly present ${2:-$1}"; fi
}

# Fixed-string grep in a file.
assert_grep() {  # file pattern [msg]
    if grep -qF -- "$2" "$1" 2>/dev/null; then _ok "grep [$2] ${3:-}"; else _no "grep [$2] not found in $1 ${3:-}"; fi
}

assert_nogrep() {  # file pattern [msg]
    if grep -qF -- "$2" "$1" 2>/dev/null; then _no "unexpected [$2] in $1 ${3:-}"; else _ok "no [$2] ${3:-}"; fi
}

# Regex grep in a file.
assert_grepE() {  # file regex [msg]
    if grep -qE -- "$2" "$1" 2>/dev/null; then _ok "grepE [$2] ${3:-}"; else _no "grepE [$2] not found in $1 ${3:-}"; fi
}

assert_exit() {  # actual expected [msg]
    if [[ $1 == "$2" ]]; then _ok "exit=$2 ${3:-}"; else _no "exit expected $2 got $1 ${3:-}"; fi
}
