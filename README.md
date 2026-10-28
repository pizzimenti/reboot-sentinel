# Reboot Sentinel

KDE Plasma 6 panel widget that appears only when a pacman or yay transaction
needs a reboot. Hovering lists what triggered it; clicking opens Plasma's
reboot prompt.

Current version: `1.2.0` · See [CHANGELOG.md](CHANGELOG.md) · Use GitHub Issues for bugs and feature requests.

## What it does

Reboot Sentinel has three parts:

| Part | Installed at | Role |
|---|---|---|
| pacman hook | `/etc/pacman.d/hooks/99-reboot-required.hook` | After a transaction that installs, upgrades or removes a package on its Target list, runs the flag script with the names that matched |
| Flag script | `/usr/local/bin/reboot-required-flag` | Merges those names into `/run/reboot-required` |
| Widget | `~/.local/share/plasma/plasmoids/org.kde.plasma.rebootsentinel/` | Checks every 30 seconds and shows its icon while a reboot is pending |

- **When it shows.** The icon appears when `/run/reboot-required` lists
  packages, or when the running kernel's modules
  (`/usr/lib/modules/<running version>/kernel`) are gone. The second check
  catches a kernel upgrade the Target list does not name, such as an AUR
  kernel.
- **Hover** shows *Reboot required* and the packages (and kernel line) behind
  it.
- **Click** opens Plasma's own reboot confirmation (`org.kde.LogoutPrompt`
  over D-Bus, through `qdbus6`), where you can still cancel.
- **Idle**, it takes no panel space at all.
- **yay** installs through pacman, so repository and AUR packages both reach
  the hook.

### The flag clears itself at reboot

`/run` is a tmpfs: it lives in memory and starts empty at every boot. So
`/run/reboot-required` disappears when the machine reboots, and the icon goes
with it. Nothing clears the flag, and nothing needs to. Logging out is not
enough; it takes a reboot.

### A panel widget, not a system-tray entry

The widget sits directly in a panel; put it next to the system tray if you
like. It was built that way because, on the author's machine, the system tray
would not take a widget installed per user. When nothing is pending it
collapses to zero width.

## Requirements

- An Arch-family system with pacman: Arch, Manjaro, CachyOS and the like. The
  installer refuses to run without pacman.
- KDE Plasma 6. Everything else it uses comes with Plasma there: `qdbus6`
  (qt6-tools), the executable data engine (plasma5support) and `kpackagetool6`
  (kpackage).
- sudo, for the hook and the flag script.

## Install

```bash
git clone https://github.com/pizzimenti/reboot-sentinel.git
cd reboot-sentinel
./install.sh
```

Then right-click a panel, choose *Add Widgets*, and drag *Reboot Sentinel*
onto it.

The installer:

- installs the widget for you, with `kpackagetool6` (or by copying its two
  files when that is missing), honouring `XDG_DATA_HOME`;
- runs sudo for exactly two files, the flag script and then the hook, and only
  when one is missing or differs from the checkout, so a re-run that changes
  nothing asks for no password;
- is idempotent: run it again after `git pull` to upgrade;
- refuses to run as root (the widget would land in root's home) and on a
  machine without pacman.

After an upgrade of the widget, Plasma keeps the old one loaded until it
restarts: log out and in, or run

```bash
systemctl --user restart plasma-plasmashell
```

A new or changed hook applies from pacman's next transaction; nothing needs
restarting for that.

## Uninstall

First take the widget out of its panel. While nothing is pending it takes no
space, so there is nothing to right-click; make it visible:

```bash
echo test > ~/.cache/reboot-sentinel-test
```

Within 30 seconds the icon appears: right-click it and choose *Remove*. Then:

```bash
rm ~/.cache/reboot-sentinel-test
./install.sh --uninstall
```

This removes the hook, then the flag script (with sudo), then the widget:
`kpackagetool6` removes the widget's whole directory, while the copy fallback
removes only its own two files and says if anything else was left there. A pending `/run/reboot-required` stays until the next reboot clears
it, and `/etc/pacman.d/hooks/` itself is left alone, as other hooks may live
there.

## Seeing it without a pending reboot

The widget also reads `~/.cache/reboot-sentinel-test`, which needs no root.
Write anything there and the icon appears within 30 seconds, showing that line
on hover:

```bash
echo test > ~/.cache/reboot-sentinel-test
```

Clicking it opens the real reboot prompt; cancel it. To hide the icon again:

```bash
rm ~/.cache/reboot-sentinel-test
```

## Editing the trigger list

The Target lines in the hook decide which packages flag a reboot:

| Group | Targets |
|---|---|
| Kernels | Arch: `linux`, `linux-lts`, `linux-zen`, `linux-hardened`, `linux-rt`, `linux-rt-lts`. Manjaro: `linux[0-9]*` (`linux612`, `linux612-nvidia`, ...). CachyOS: `linux-cachyos*` (`linux-cachyos`, `linux-cachyos-nvidia-open`, ...) |
| Firmware | `linux-firmware*` |
| CPU microcode | `amd-ucode`, `intel-ucode` |
| Core userspace | `systemd`, `glibc`, `dbus` |
| GPU drivers and Wayland | `mesa`, `vulkan-radeon`, `vulkan-intel`, `egl-wayland`, `wayland`, and NVIDIA's drivers but not its tools: `nvidia`, `nvidia-lts`, `nvidia-open*`, `nvidia*-dkms`, `nvidia*-utils` |
| Never | `!*-headers`, `!*-docs`, `!*-dbg`, `!*-debug` |

pacman compares each package name with every Target as a shell glob
(`fnmatch`), and **the last Target that matches decides**; a Target starting
with `!` means "not this one". The exclusions at the end therefore win over
every line above them, so add new Targets above them. A name no Target
matches does not flag a reboot.

To change the list:

1. Edit `pacman/99-reboot-required.hook` in your clone.
2. Add a row to `TABLE` in `tests/test_targets.py` for each package that
   should or should not flag a reboot, then run `tests/test_targets.py`.
3. Run `./install.sh`, which puts the new hook in place.

Edits made directly to `/etc/pacman.d/hooks/99-reboot-required.hook` work too,
but the next `./install.sh` replaces that file with the clone's copy.

## Tests

```bash
tests/check.sh
```

Runs `bash -n` and `sh -n` on every shell file, `shellcheck` when installed,
checks that `VERSION`, `metadata.json` and the changelog agree, guards
`main.qml` against Plasma 5 imports and home-directory paths, then:

- `tests/test_targets.py`: the Target list against a table of real Arch,
  Manjaro and CachyOS package names, each expected to flag a reboot or not,
  using pacman's last-match-wins rule; Python's `fnmatch` is cross-checked
  against the C library's `fnmatch(3)`, which pacman calls, on every pair.
- `tests/test_flag.sh`: a copy of the flag script, its path changed by sed
  to a scratch file, writing and merging the names, mode 644 whatever the
  caller's umask, and writing nothing when no names arrive. The installed
  script has no override: pacman passes its environment to hooks.
- `tests/test_install.sh`: the installer against scratch homes and a scratch
  system root (`REBOOT_SENTINEL_SYSROOT`), with stand-ins for sudo,
  kpackagetool6 and pacman: what gets installed and with which modes, exactly
  what sudo is asked to do, idempotency, upgrades, the copy fallback
  (`REBOOT_SENTINEL_KPACKAGETOOL`), `XDG_DATA_HOME`, `--uninstall` restoring
  the prior files, a failed sudo writing nothing, and the refusals without
  pacman and as root.

None of them needs root or touches the real `/etc`, `/usr`, `/run` or
`~/.local`: the stand-in sudo runs commands as you and refuses any path
outside the scratch directory.

## License

MIT (see `LICENSE`)
