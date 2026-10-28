#!/usr/bin/env bash
# Runs install.sh and install.sh --uninstall against throwaway HOMEs and a
# throwaway system root (REBOOT_SENTINEL_SYSROOT), with stand-ins for sudo,
# kpackagetool6 and pacman, and checks exactly which files appear and go, with
# which modes, and what sudo and kpackagetool6 were asked to do.
#
# Nothing outside the scratch directory is touched: HOME and the system root
# are scratch, the stand-in sudo runs commands as you (never as root) and
# refuses any absolute path outside the scratch directory and this repo, and
# the stand-in kpackagetool6 refuses a data directory outside the scratch.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/reboot-sentinel-install.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

TESTS=0
fail() {
    echo "FAIL: $*" >&2
    local log
    for log in "$WORK"/logs/*; do
        [[ -s "$log" ]] && { echo "--- $(basename "$log")" >&2; tail -n 20 "$log" >&2; }
    done
    exit 1
}
ok() { TESTS=$((TESTS + 1)); echo "ok $TESTS - $*"; }

mkdir -p "$WORK/logs" "$WORK/fakebin"
FAKEBIN="$WORK/fakebin"
OUT="$WORK/logs/installer.out"
SUDO_LOG="$WORK/logs/sudo.calls"
KPT_LOG="$WORK/logs/kpackagetool6.calls"
PLASMOID_ID=org.kde.plasma.rebootsentinel
VERSION="$(<"$REPO/VERSION")"

# --- stand-ins --------------------------------------------------------------

cat > "$FAKEBIN/pacman" <<'EOF'
#!/bin/sh
# Stand-in pacman: install.sh only checks that one exists.
exit 0
EOF

cat > "$FAKEBIN/sudo" <<'EOF'
#!/bin/sh
# Stand-in sudo: refuses any absolute path outside the test's scratch
# directory and the repo, fails like a wrong password when FAKE_SUDO=deny,
# logs its arguments and runs the command as the caller.
[ -n "${STUB_SANDBOX:-}" ] && [ -n "${STUB_REPO:-}" ] || { echo "stub sudo: no sandbox set" >&2; exit 99; }
for a in "$@"; do
    case "$a" in
        "$STUB_SANDBOX"/*|"$STUB_REPO"/*) ;;
        /*) echo "stub sudo: refusing $a, outside the sandbox" >&2; exit 99 ;;
    esac
done
if [ "${FAKE_SUDO:-}" = deny ]; then
    echo "sudo: 3 incorrect password attempts" >&2
    exit 1
fi
printf '%s\n' "$*" >> "$STUB_SUDO_LOG"
exec "$@"
EOF

# Mirrors the real kpackagetool6 (KF 6.31, probed in a scratch HOME) for
# Plasma/Applet packages: --install fails with 4 when the package exists,
# --upgrade replaces it and fails with 2 when it is absent, --remove deletes
# the package directory and fails with 2 when it is absent. Files land 644.
cat > "$FAKEBIN/kpackagetool6" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_KPT_LOG"
if [[ "${XDG_DATA_HOME:-}" == /* ]]; then data="$XDG_DATA_HOME"; else data="$HOME/.local/share"; fi
case "$data" in
    "$STUB_SANDBOX"/*) ;;
    *) echo "stub kpackagetool6: refusing data directory $data, outside the sandbox" >&2; exit 99 ;;
esac
root="$data/plasma/plasmoids"
if [[ $# -ne 4 || "$1" != --type || "$2" != Plasma/Applet ]]; then
    echo "stub kpackagetool6: unexpected arguments: $*" >&2
    exit 64
fi
pkg_id() {
    python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["KPlugin"]["Id"])' "$1/metadata.json"
}
copy_in() {  # source-dir id
    local f
    while IFS= read -r f; do
        install -Dm644 -- "$1/$f" "$root/$2/$f"
    done < <(cd "$1" && find . -type f -printf '%P\n')
}
case "$3" in
    --install)
        id="$(pkg_id "$4")"
        [[ ! -e "$root/$id" ]] || { echo "Error: Installation of $4 failed: $root/$id already exists"; exit 4; }
        copy_in "$4" "$id"
        echo "Successfully installed $root/$id/" ;;
    --upgrade)
        id="$(pkg_id "$4")"
        [[ -e "$root/$id" ]] || { echo "Error: Plugin $id is not installed."; exit 2; }
        rm -rf -- "${root:?}/$id"
        copy_in "$4" "$id"
        echo "Successfully upgraded $root/$id/" ;;
    --remove)
        [[ -n "$4" && -e "$root/$4" ]] || { echo "Error: Plugin  is not installed."; exit 2; }
        rm -rf -- "${root:?}/$4"
        echo "Successfully uninstalled $root/$4/" ;;
    *) echo "stub kpackagetool6: unexpected operation $3" >&2; exit 64 ;;
esac
EOF
chmod 755 "$FAKEBIN/pacman" "$FAKEBIN/sudo" "$FAKEBIN/kpackagetool6"

# --- helpers ------------------------------------------------------------------

# Run the installer with HOME at $1/home and the system root at $1/sys, every
# XDG base directory and REBOOT_SENTINEL_* variable cleared first.
# INSTALL_ENV adds VAR=value pairs; RUNNER wraps the call (e.g. unshare -r).
INSTALL_ENV=()
RUNNER=()
run_installer() {  # scenario-dir [installer args...]
    local dir="$1"; shift
    : > "$SUDO_LOG"
    : > "$KPT_LOG"
    env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u XDG_STATE_HOME \
        -u REBOOT_SENTINEL_KPACKAGETOOL -u REBOOT_SENTINEL_FLAG -u FAKE_SUDO \
        HOME="$dir/home" REBOOT_SENTINEL_SYSROOT="$dir/sys" PATH="$FAKEBIN:$PATH" \
        STUB_SANDBOX="$WORK" STUB_REPO="$REPO" STUB_SUDO_LOG="$SUDO_LOG" STUB_KPT_LOG="$KPT_LOG" \
        ${INSTALL_ENV[@]+"${INSTALL_ENV[@]}"} \
        ${RUNNER[@]+"${RUNNER[@]}"} "$REPO/install.sh" "$@"
}

# run_installer for a run that must succeed: output to $OUT, and a FAIL that
# shows it when the installer exits non-zero.
run_ok() {  # scenario-dir [installer args...]
    local rc=0
    run_installer "$@" > "$OUT" 2>&1 || rc=$?
    [[ $rc == 0 ]] || fail "install.sh ${*:2} exited $rc"
}

# Every file and symlink under a directory, with its mode and checksum.
snapshot() {  # dir
    (cd "$1" && find . \( -type f -o -type l \) -printf '%p %m\n' | sort | while read -r p m; do
        printf '%s %s %s\n' "$p" "$m" "$(sha256sum < "$p" | cut -d' ' -f1)"
    done)
}

same_bytes() { [[ "$(sha256sum < "$1")" == "$(sha256sum < "$2")" ]]; }

expect_log() {  # log what expected-lines...
    local want=""
    [[ $# -gt 2 ]] && want="$(printf '%s\n' "${@:3}")"
    [[ "$(<"$1")" == "$want" ]] || fail "$2 was asked: [$(<"$1")], expected: [$want]"
}

sudo_install_flag() { echo "install -Dm755 -- $REPO/pacman/reboot-required-flag $1/sys/usr/local/bin/reboot-required-flag"; }
sudo_install_hook() { echo "install -Dm644 -- $REPO/pacman/99-reboot-required.hook $1/sys/etc/pacman.d/hooks/99-reboot-required.hook"; }
sudo_rm_hook() { echo "rm -f -- $1/sys/etc/pacman.d/hooks/99-reboot-required.hook"; }
sudo_rm_flag() { echo "rm -f -- $1/sys/usr/local/bin/reboot-required-flag"; }

check_installed() {  # scenario-dir data-home
    local sys="$1/sys" pdir="$2/plasma/plasmoids/$PLASMOID_ID" f
    local flag="$sys/usr/local/bin/reboot-required-flag" hook="$sys/etc/pacman.d/hooks/99-reboot-required.hook"
    [[ -f "$flag" && "$(stat -c %a "$flag")" == 755 ]] || fail "$flag missing or mode not 755"
    same_bytes "$flag" "$REPO/pacman/reboot-required-flag" || fail "$flag differs from the repo"
    [[ -f "$hook" && "$(stat -c %a "$hook")" == 644 ]] || fail "$hook missing or mode not 644"
    same_bytes "$hook" "$REPO/pacman/99-reboot-required.hook" || fail "$hook differs from the repo"
    for f in metadata.json contents/ui/main.qml; do
        [[ -f "$pdir/$f" && "$(stat -c %a "$pdir/$f")" == 644 ]] || fail "$pdir/$f missing or mode not 644"
        same_bytes "$pdir/$f" "$REPO/package/$f" || fail "$pdir/$f differs from the repo"
    done
    [[ "$(cd "$pdir" && find . -type f | sort)" == $'./contents/ui/main.qml\n./metadata.json' ]] \
        || fail "$pdir holds other files than the widget's two"
}

seed_unrelated() {  # scenario-dir
    # Files the installer must never touch: another pacman hook, another
    # script in /usr/local/bin, another user widget, and a pending flag.
    mkdir -p "$1/sys/etc/pacman.d/hooks" "$1/sys/usr/local/bin" "$1/sys/run" \
        "$1/home/.local/share/plasma/plasmoids/org.example.other/contents/ui"
    printf '[Trigger]\nType = Package\nTarget = foo\n' > "$1/sys/etc/pacman.d/hooks/50-other.hook"
    printf '#!/bin/sh\nexit 0\n' > "$1/sys/usr/local/bin/other-tool"
    chmod 755 "$1/sys/usr/local/bin/other-tool"
    printf 'linux\n' > "$1/sys/run/reboot-required"
    printf '{}\n' > "$1/home/.local/share/plasma/plasmoids/org.example.other/metadata.json"
    printf 'Item {}\n' > "$1/home/.local/share/plasma/plasmoids/org.example.other/contents/ui/main.qml"
}

# --- install, re-install, upgrade, uninstall (kpackagetool6) --------------------

S="$WORK/s-kpt"
seed_unrelated "$S"
before="$(snapshot "$S")"

run_ok "$S"
check_installed "$S" "$S/home/.local/share"
ok "install puts the flag script (755), the hook (644) and the widget (644) in place"

expect_log "$SUDO_LOG" sudo "$(sudo_install_flag "$S")" "$(sudo_install_hook "$S")"
ok "sudo is asked for exactly the two system files, the flag script before its hook"

expect_log "$KPT_LOG" kpackagetool6 "--type Plasma/Applet --install $REPO/package"
grep -qF "Reboot Sentinel $VERSION" "$OUT" || fail "install did not report VERSION"
grep -qF "Add Widgets" "$OUT" || fail "a first install did not say how to add the widget to a panel"
ok "a first install uses kpackagetool6 --install, reports VERSION and says how to add the widget"

first="$(snapshot "$S")"
run_ok "$S"
[[ "$(snapshot "$S")" == "$first" ]] || fail "a second install changed files"
expect_log "$SUDO_LOG" sudo
expect_log "$KPT_LOG" kpackagetool6
grep -qx "Already up to date." "$OUT" || fail "a no-op re-install did not say it was up to date"
ok "re-running install changes nothing and asks neither sudo nor kpackagetool6"

printf '// older\n' >> "$S/home/.local/share/plasma/plasmoids/$PLASMOID_ID/contents/ui/main.qml"
chmod 644 "$S/sys/usr/local/bin/reboot-required-flag"
run_ok "$S"
check_installed "$S" "$S/home/.local/share"
expect_log "$SUDO_LOG" sudo "$(sudo_install_flag "$S")"
expect_log "$KPT_LOG" kpackagetool6 "--type Plasma/Applet --upgrade $REPO/package"
grep -qF "systemctl --user restart plasma-plasmashell" "$OUT" || fail "an upgrade did not say how to reload the widget"
ok "an upgrade replaces only what differs: a changed widget (kpackagetool6 --upgrade), a flag script with the wrong mode"

printf 'Target = local-edit\n' >> "$S/sys/etc/pacman.d/hooks/99-reboot-required.hook"
run_ok "$S"
check_installed "$S" "$S/home/.local/share"
expect_log "$SUDO_LOG" sudo "$(sudo_install_hook "$S")"
expect_log "$KPT_LOG" kpackagetool6
grep -qF "pacman uses the new hook" "$OUT" || fail "a hook-only update did not say when it takes effect"
ok "a changed hook is put back with sudo for the hook alone"

run_ok "$S" --uninstall
expect_log "$SUDO_LOG" sudo "$(sudo_rm_hook "$S")" "$(sudo_rm_flag "$S")"
expect_log "$KPT_LOG" kpackagetool6 "--type Plasma/Applet --remove $PLASMOID_ID"
[[ ! -e "$S/home/.local/share/plasma/plasmoids/$PLASMOID_ID" ]] || fail "uninstall left the widget's directory"
ok "uninstall removes the hook, then the flag script (sudo), then the widget (kpackagetool6 --remove)"

[[ "$(snapshot "$S")" == "$before" ]] || {
    diff <(echo "$before") <(snapshot "$S") >&2 || true
    fail "uninstall did not return HOME and the system root to exactly their prior files"
}
ok "uninstall leaves the other hook, script, widget and the pending flag untouched"

run_ok "$S" --uninstall
grep -qF "Nothing to remove" "$OUT" || fail "a second uninstall did not say there was nothing to remove"
expect_log "$SUDO_LOG" sudo
expect_log "$KPT_LOG" kpackagetool6
[[ "$(snapshot "$S")" == "$before" ]] || fail "a second uninstall changed files"
ok "re-running uninstall is a no-op that asks neither sudo nor kpackagetool6"

# --- without kpackagetool6: a plain copy --------------------------------------------

S="$WORK/s-copy"
seed_unrelated "$S"
before="$(snapshot "$S")"
INSTALL_ENV=(REBOOT_SENTINEL_KPACKAGETOOL=no-such-kpackagetool)
run_ok "$S"
check_installed "$S" "$S/home/.local/share"
expect_log "$SUDO_LOG" sudo "$(sudo_install_flag "$S")" "$(sudo_install_hook "$S")"
expect_log "$KPT_LOG" kpackagetool6
grep -qF "copied: kpackagetool6 not found" "$OUT" || fail "the copy install did not say it copied"
ok "without kpackagetool6 the widget is copied into place, mode 644, and sudo is asked for the system files only"

first="$(snapshot "$S")"
run_ok "$S"
[[ "$(snapshot "$S")" == "$first" ]] || fail "a second copy install changed files"
expect_log "$SUDO_LOG" sudo
ok "re-running the copy install changes nothing"

run_ok "$S" --uninstall
expect_log "$SUDO_LOG" sudo "$(sudo_rm_hook "$S")" "$(sudo_rm_flag "$S")"
[[ ! -e "$S/home/.local/share/plasma/plasmoids/$PLASMOID_ID" ]] || fail "the copy uninstall left the widget's directory"
[[ "$(snapshot "$S")" == "$before" ]] || fail "the copy uninstall did not restore the prior files"
ok "the copy uninstall removes the widget's files and its now-empty directories"

run_ok "$S"
printf 'mine\n' > "$S/home/.local/share/plasma/plasmoids/$PLASMOID_ID/contents/notes.txt"
run_ok "$S" --uninstall
pdir="$S/home/.local/share/plasma/plasmoids/$PLASMOID_ID"
[[ "$(cd "$pdir" && find . \( -type f -o -type l \) | sort)" == "./contents/notes.txt" ]] \
    || fail "the copy uninstall removed a file it did not install, or left one it did"
grep -qF "Left in place: $pdir" "$OUT" || fail "the copy uninstall did not say what it left"
ok "the copy uninstall removes only its own two files and says what it left"
INSTALL_ENV=()

# --- XDG_DATA_HOME, an empty system root, a space in the path ---------------------

S="$WORK/s with space"
mkdir -p "$S/home" "$S/sys"
INSTALL_ENV=(XDG_DATA_HOME="$S/home/data dir")
run_ok "$S"
check_installed "$S" "$S/home/data dir"
[[ ! -e "$S/home/.local" ]] || fail "XDG_DATA_HOME was ignored"
ok "install honours XDG_DATA_HOME and creates the hooks directory, with spaces in the paths"

run_ok "$S" --uninstall
leftover="$(find "$S" \( -type f -o -type l \) -print)"
[[ -z "$leftover" ]] || fail "uninstall left files: $leftover"
ok "uninstall under XDG_DATA_HOME leaves no files behind"
INSTALL_ENV=()

# --- sudo refused ------------------------------------------------------------------------

S="$WORK/s-denied"
mkdir -p "$S/home" "$S/sys"
INSTALL_ENV=(FAKE_SUDO=deny)
set +e
run_installer "$S" > "$OUT" 2>&1
rc=$?
set -e
INSTALL_ENV=()
[[ $rc != 0 ]] || fail "install exited 0 although sudo failed"
[[ -z "$(find "$S" -mindepth 2 -print)" ]] || fail "install wrote files although sudo failed: $(find "$S" -mindepth 2)"
expect_log "$KPT_LOG" kpackagetool6
ok "when sudo fails, install stops before writing anything, the widget included"

# --- no pacman -----------------------------------------------------------------------------

S="$WORK/s-no-pacman"
mkdir -p "$S/home" "$S/sys" "$WORK/only-bash"
ln -s "$(command -v bash)" "$WORK/only-bash/bash"
for args in install --uninstall; do
    [[ $args == install ]] && args=""
    : > "$SUDO_LOG"
    set +e
    env -u XDG_DATA_HOME HOME="$S/home" REBOOT_SENTINEL_SYSROOT="$S/sys" PATH="$WORK/only-bash" \
        "$REPO/install.sh" ${args:+"$args"} > "$OUT" 2>&1
    rc=$?
    set -e
    [[ $rc == 1 ]] || fail "without pacman (${args:-install}) exited $rc, not 1"
    grep -qF "pacman was not found" "$OUT" || fail "the refusal does not say pacman is missing"
done
[[ -z "$(find "$S" -mindepth 2 -print)" ]] || fail "a refused run wrote files"
expect_log "$SUDO_LOG" sudo
ok "without pacman, install and --uninstall refuse (exit 1) and write nothing"

# --- root --------------------------------------------------------------------------------------

if unshare -r true 2>/dev/null; then
    S="$WORK/s-root"
    mkdir -p "$S/home" "$S/sys"
    RUNNER=(unshare -r)
    for args in install --uninstall; do
        [[ $args == install ]] && args=""
        set +e
        run_installer "$S" ${args:+"$args"} > "$OUT" 2>&1
        rc=$?
        set -e
        [[ $rc == 1 ]] || fail "running as root (${args:-install}) exited $rc, not 1"
        grep -qF "Refusing to run as root" "$OUT" || fail "the root refusal message is missing"
    done
    RUNNER=()
    [[ -z "$(find "$S" -mindepth 2 -print)" ]] || fail "a refused root run wrote files"
    ok "install and --uninstall refuse to run as root and write nothing"
else
    echo "skip - root refusal: unshare -r is not permitted here"
fi

# --- arguments, and the real kpackagetool6's options ------------------------------------------

S="$WORK/s-args"
mkdir -p "$S/home" "$S/sys"
set +e
run_installer "$S" --bogus > "$OUT" 2>&1
rc=$?
set -e
[[ $rc == 2 ]] || fail "an unknown option exited $rc, not 2"
help="$(run_installer "$S" --help)"
grep -q -- "--uninstall" <<< "$help" || fail "--help does not list --uninstall"
grep -qF "/etc/pacman.d/hooks/99-reboot-required.hook" <<< "$help" || fail "--help does not name the hook"
[[ -z "$(find "$S" -mindepth 2 -print)" ]] || fail "--bogus or --help wrote files"
ok "unknown options exit 2 and --help names the flag and the system files"

if real="$(command -v kpackagetool6)"; then  # this shell's PATH has no stand-ins
    help="$("$real" --help 2>&1)"
    for opt in --type --install --upgrade --remove; do
        grep -q -- "$opt" <<< "$help" || fail "the real kpackagetool6 ($real) has no $opt"
    done
    ok "the real kpackagetool6 offers the --type, --install, --upgrade and --remove the installer uses"
else
    echo "skip - real kpackagetool6 options: kpackagetool6 not installed"
fi

echo "all $TESTS install checks passed"
