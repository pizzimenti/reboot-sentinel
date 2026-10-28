#!/usr/bin/env bash
# Runs pacman/reboot-required-flag the way the hook does (matched package
# names on stdin). The script hard-codes /run/reboot-required, so each run
# uses a copy whose flag path sed has changed to a scratch file: it needs no
# root and never touches /run.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAG_SCRIPT="$REPO/pacman/reboot-required-flag"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/reboot-sentinel-flag.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

TESTS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { TESTS=$((TESTS + 1)); echo "ok $TESTS - $*"; }

[[ "$(head -n 1 "$FLAG_SCRIPT")" == '#!/bin/sh' ]] || fail "the flag script is not a #!/bin/sh script"
[[ "$(grep -c '^f=' "$FLAG_SCRIPT")" == 1 ]] && grep -qxF 'f=/run/reboot-required' "$FLAG_SCRIPT" \
    || fail "the flag script does not set its path once, to /run/reboot-required"
! grep -qE 'REBOOT_SENTINEL|\$\{f[:-]|\$\{[A-Z_]*:-/run' "$FLAG_SCRIPT" \
    || fail "the flag script takes its path from the environment"
ok "the flag path is hard-coded to /run/reboot-required, with no environment override"

# A copy of the script writing to $1 instead of /run/reboot-required.
make_copy() {  # flag-file copy
    [[ "$1" != *[\|\&\\]* ]] || fail "scratch path $1 has a character sed would read"
    sed "s|^f=/run/reboot-required\$|f=$1|" "$FLAG_SCRIPT" > "$2"
    chmod 755 "$2"
    grep -qxF "f=$1" "$2" || fail "sed did not point the copy at $1"
    ! grep -q '/run/reboot-required$' "$2" || fail "the copy still names /run/reboot-required"
}

# Every run uses a umask of 077, so a 644 flag proves the script sets its own.
flag() {  # copy < names
    (umask 077 && "${RUNNER[@]}" "$1")
}

run_suite() {  # label
    local dir="$WORK/$1" f="$WORK/$1/reboot-required" copy="$WORK/$1/flag-copy" inode
    mkdir -p "$dir"
    make_copy "$f" "$copy"

    : | flag "$copy"
    [[ ! -e "$f" ]] || fail "$1: no names on stdin created a flag"
    ok "$1: no names on stdin and no flag yet: nothing is written"

    printf 'systemd\nlinux\n' | flag "$copy"
    [[ "$(<"$f")" == $'linux\nsystemd' ]] || fail "$1: a new flag is not the sorted names: $(<"$f")"
    [[ "$(stat -c %a "$f")" == 644 ]] || fail "$1: the flag's mode is $(stat -c %a "$f"), not 644"
    ok "$1: the first transaction writes the sorted names, mode 644 under umask 077"

    printf 'mesa\nlinux\nlinux\n' | flag "$copy"
    [[ "$(<"$f")" == $'linux\nmesa\nsystemd' ]] || fail "$1: names were not merged: $(<"$f")"
    ok "$1: a later transaction merges its names, each listed once"

    inode="$(stat -c %i "$f")"
    : | flag "$copy"
    [[ "$(<"$f")" == $'linux\nmesa\nsystemd' && "$(stat -c %i "$f")" == "$inode" ]] \
        || fail "$1: empty input rewrote the flag"
    ok "$1: no names on stdin leaves the existing flag unwritten"

    [[ -z "$(find "$dir" -name '*.tmp')" ]] || fail "$1: a .tmp file was left behind"
    ok "$1: no temporary file is left next to the flag"
}

RUNNER=()
run_suite "as-installed"

# The script is POSIX sh; run it under dash too where dash is installed.
if command -v dash >/dev/null 2>&1; then
    RUNNER=(dash)
    run_suite "dash"
else
    echo "skip - dash not installed"
fi

echo "all $TESTS flag checks passed"
