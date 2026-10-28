#!/usr/bin/env bash
# Runs pacman/reboot-required-flag the way the hook does (matched package
# names on stdin), with REBOOT_SENTINEL_FLAG pointing at a scratch file, so it
# needs no root and never touches /run/reboot-required.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAG_SCRIPT="$REPO/pacman/reboot-required-flag"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/reboot-sentinel-flag.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

TESTS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { TESTS=$((TESTS + 1)); echo "ok $TESTS - $*"; }

# Every run uses a umask of 077, so a 644 flag proves the script sets its own.
flag() {  # flag-file < names
    (umask 077 && REBOOT_SENTINEL_FLAG="$1" "${RUNNER[@]}")
}

run_suite() {  # label
    local f="$WORK/$1/reboot-required"
    mkdir -p "$WORK/$1"

    printf 'systemd\nlinux\n' | flag "$f"
    [[ "$(<"$f")" == $'linux\nsystemd' ]] || fail "$1: a new flag is not the sorted names: $(<"$f")"
    [[ "$(stat -c %a "$f")" == 644 ]] || fail "$1: the flag's mode is $(stat -c %a "$f"), not 644"
    ok "$1: the first transaction writes the sorted names, mode 644 under umask 077"

    printf 'mesa\nlinux\nlinux\n' | flag "$f"
    [[ "$(<"$f")" == $'linux\nmesa\nsystemd' ]] || fail "$1: names were not merged: $(<"$f")"
    ok "$1: a later transaction merges its names, each listed once"

    : | flag "$f"
    [[ "$(<"$f")" == $'linux\nmesa\nsystemd' ]] || fail "$1: empty input changed the flag"
    ok "$1: no names on stdin leaves the flag as it was"

    [[ -z "$(find "$WORK/$1" -name '*.tmp')" ]] || fail "$1: a .tmp file was left behind"
    ok "$1: no temporary file is left next to the flag"
}

RUNNER=("$FLAG_SCRIPT")
run_suite "as-installed"

# The script is POSIX sh; run it under dash too where dash is installed.
if command -v dash >/dev/null 2>&1; then
    RUNNER=(dash "$FLAG_SCRIPT")
    run_suite "dash"
else
    echo "skip - dash not installed"
fi

[[ "$(head -n 1 "$FLAG_SCRIPT")" == '#!/bin/sh' ]] || fail "the flag script is not a #!/bin/sh script"
grep -qxF -- "f=\${REBOOT_SENTINEL_FLAG:-/run/reboot-required}" "$FLAG_SCRIPT" \
    || fail "the flag path does not default to /run/reboot-required"
ok "without the override the flag is /run/reboot-required"

echo "all $TESTS flag checks passed"
