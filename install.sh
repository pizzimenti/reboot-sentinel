#!/usr/bin/env bash
# Reboot Sentinel installer, for Arch-family systems (pacman) running KDE
# Plasma 6.
#
#   ./install.sh              install, or upgrade to this checkout
#   ./install.sh --uninstall  remove everything install.sh installed
#
# The widget installs for the user running this (kpackagetool6 when present,
# otherwise a plain copy). The pacman hook and the flag script it runs are
# system files, so the installer runs sudo for exactly those two files, and
# only when one is missing or differs from this checkout.
set -euo pipefail

usage() {
    printf '%s\n' \
        "Usage: ./install.sh [--uninstall]" \
        "" \
        "  (no option)    install Reboot Sentinel, or upgrade it to this checkout" \
        "  --uninstall    remove the widget, the pacman hook and the flag script" \
        "  -h, --help     show this help" \
        "" \
        "The widget installs for your user; sudo is asked for the pacman hook" \
        "(/etc/pacman.d/hooks/99-reboot-required.hook) and the flag script" \
        "(/usr/local/bin/reboot-required-flag) only."
}

UNINSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1 (see ./install.sh --help)" >&2; exit 2 ;;
    esac
done

# Under sudo the widget would land in root's home and every file would be
# written as root without asking; the installer asks sudo itself, per file.
if [[ $EUID -eq 0 ]]; then
    echo "Refusing to run as root: the widget installs for the user who runs this," >&2
    echo "and install.sh asks sudo itself for the two system files. Re-run ./install.sh" >&2
    echo "as your user." >&2
    exit 1
fi

# Builtins only up to here, so this check is the first thing that can fail
# on a machine without pacman.
if ! command -v pacman >/dev/null 2>&1; then
    echo "Refusing to run: pacman was not found. Reboot Sentinel is triggered by a" >&2
    echo "pacman hook, so it works only on Arch-family systems (Arch, Manjaro," >&2
    echo "CachyOS, ...). Nothing was changed." >&2
    exit 1
fi

if [[ "${HOME:-}" != /* ]]; then
    echo "HOME is not set to an absolute path; cannot tell where to install the widget." >&2
    exit 1
fi

case "${BASH_SOURCE[0]}" in
    */*) ROOT_DIR="${BASH_SOURCE[0]%/*}" ;;
    *) ROOT_DIR=. ;;
esac
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"
VERSION="$(<"$ROOT_DIR/VERSION")"

# REBOOT_SENTINEL_SYSROOT stands in for / under the two system files, and
# REBOOT_SENTINEL_KPACKAGETOOL names the package tool (an unknown name means
# "copy instead"). Both exist for the tests; leave them unset otherwise.
SYSROOT="${REBOOT_SENTINEL_SYSROOT:-}"
if [[ -n "$SYSROOT" && "$SYSROOT" != /* ]]; then
    echo "REBOOT_SENTINEL_SYSROOT must be an absolute path." >&2
    exit 1
fi
KPACKAGETOOL="${REBOOT_SENTINEL_KPACKAGETOOL-kpackagetool6}"

FLAG_SRC="$ROOT_DIR/pacman/reboot-required-flag"
FLAG_DEST="$SYSROOT/usr/local/bin/reboot-required-flag"
HOOK_SRC="$ROOT_DIR/pacman/99-reboot-required.hook"
HOOK_DEST="$SYSROOT/etc/pacman.d/hooks/99-reboot-required.hook"

# kpackagetool6 installs into the same place: Qt's writable generic data
# location, which is XDG_DATA_HOME when that is an absolute path.
if [[ "${XDG_DATA_HOME:-}" == /* ]]; then
    DATA_HOME="$XDG_DATA_HOME"
else
    DATA_HOME="$HOME/.local/share"
fi
PLASMOID_ID=org.kde.plasma.rebootsentinel
PLASMOID_SRC="$ROOT_DIR/package"
PLASMOID_DIR="$DATA_HOME/plasma/plasmoids/$PLASMOID_ID"
PLASMOID_FILES=(metadata.json contents/ui/main.qml)

have_kpackagetool() {
    [[ -n "$KPACKAGETOOL" ]] && command -v "$KPACKAGETOOL" >/dev/null 2>&1
}

same_bytes() {  # a b
    [[ "$(sha256sum < "$1")" == "$(sha256sum < "$2")" ]]
}

# True when dest is a regular file with src's bytes and the given mode.
system_file_current() {  # src dest mode
    [[ -f "$2" && ! -L "$2" ]] || return 1
    [[ "$(stat -c %a -- "$2")" == "$3" ]] || return 1
    same_bytes "$1" "$2"
}

plasmoid_current() {
    local f
    for f in "${PLASMOID_FILES[@]}"; do
        [[ -f "$PLASMOID_DIR/$f" ]] || return 1
        same_bytes "$PLASMOID_SRC/$f" "$PLASMOID_DIR/$f" || return 1
    done
}

SUDO_ANNOUNCED=0
as_root() {  # command...
    if [[ $SUDO_ANNOUNCED == 0 ]]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "sudo was not found. As root, run:" >&2
            echo "  install -Dm755 $FLAG_SRC $FLAG_DEST" >&2
            echo "  install -Dm644 $HOOK_SRC $HOOK_DEST" >&2
            exit 1
        fi
        echo "Using sudo for the pacman hook and its flag script (it may ask for your password)."
        SUDO_ANNOUNCED=1
    fi
    sudo "$@"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if [[ $UNINSTALL == 1 ]]; then
    removed=0
    # The hook goes first, so pacman never runs a hook whose script is gone.
    for path in "$HOOK_DEST" "$FLAG_DEST"; do
        if [[ -e "$path" || -L "$path" ]]; then
            as_root rm -f -- "$path"
            echo "  removed  $path"
            removed=$((removed + 1))
        fi
    done
    if [[ -e "$PLASMOID_DIR" || -L "$PLASMOID_DIR" ]]; then
        if have_kpackagetool; then
            "$KPACKAGETOOL" --type Plasma/Applet --remove "$PLASMOID_ID"
        else
            rm -f -- "$PLASMOID_DIR/metadata.json" "$PLASMOID_DIR/contents/ui/main.qml"
            rmdir -- "$PLASMOID_DIR/contents/ui" "$PLASMOID_DIR/contents" "$PLASMOID_DIR" 2>/dev/null || true
        fi
        echo "  removed  $PLASMOID_DIR"
        removed=$((removed + 1))
        if [[ -e "$PLASMOID_DIR" ]]; then
            echo "Left in place: $PLASMOID_DIR, which holds files install.sh did not put there."
        fi
    fi
    if [[ $removed == 0 ]]; then
        echo "Nothing to remove; Reboot Sentinel was not installed."
    else
        echo "Reboot Sentinel uninstalled. If the widget is still in a panel, remove it"
        echo "there too (right-click it, Remove)."
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Install / upgrade
# ---------------------------------------------------------------------------

echo "Reboot Sentinel $VERSION"

CHANGED=0
install_system_file() {  # src dest mode
    if system_file_current "$1" "$2" "$3"; then
        echo "  unchanged  $2"
        return 0
    fi
    local verb=installed
    [[ -e "$2" || -L "$2" ]] && verb=updated
    as_root install -Dm"$3" -- "$1" "$2"
    echo "  $verb  $2"
    CHANGED=1
}
# The flag script goes before the hook that runs it.
install_system_file "$FLAG_SRC" "$FLAG_DEST" 755
install_system_file "$HOOK_SRC" "$HOOK_DEST" 644

PLASMOID_STATE=unchanged
if plasmoid_current; then
    echo "  unchanged  $PLASMOID_DIR"
else
    PLASMOID_STATE=installed
    [[ -e "$PLASMOID_DIR" ]] && PLASMOID_STATE=updated
    if have_kpackagetool; then
        how="$KPACKAGETOOL"
        if [[ $PLASMOID_STATE == updated ]]; then
            "$KPACKAGETOOL" --type Plasma/Applet --upgrade "$PLASMOID_SRC"
        else
            "$KPACKAGETOOL" --type Plasma/Applet --install "$PLASMOID_SRC"
        fi
    else
        how="copied: kpackagetool6 not found"
        for f in "${PLASMOID_FILES[@]}"; do
            install -Dm644 -- "$PLASMOID_SRC/$f" "$PLASMOID_DIR/$f"
        done
    fi
    echo "  $PLASMOID_STATE  $PLASMOID_DIR ($how)"
    CHANGED=1
fi

echo
case "$PLASMOID_STATE" in
    installed)
        echo "Add it to a panel: right-click the panel, choose Add Widgets, and drag"
        echo "Reboot Sentinel onto it. It takes no space until a reboot is needed."
        ;;
    updated)
        echo "Plasma keeps the previous widget loaded until it restarts: log out and in,"
        echo "or run: systemctl --user restart plasma-plasmashell"
        ;;
    *)
        if [[ $CHANGED == 0 ]]; then
            echo "Already up to date."
        else
            echo "pacman uses the new hook from its next transaction."
        fi
        ;;
esac
