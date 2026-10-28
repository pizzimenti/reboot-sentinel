# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/).
Each version's heading says whether it was a major, minor or patch change.

## [Unreleased]

## [1.2.0] - 2026-10-27 (minor)

The trigger list now covers Arch, Manjaro and CachyOS, and the widget installs
from a clone with one command. The widget's code (`main.qml`) is unchanged.

### Added

- `install.sh`: installs the widget for the current user (with `kpackagetool6`
  when present, otherwise by copying its two files), and the pacman hook and
  flag script with sudo, which it asks for itself and only for those two
  files, and only when one is missing or differs from the checkout. Re-running
  it is a no-op. `--uninstall` removes the hook, the flag script and the
  widget: `kpackagetool6` removes the widget's whole directory, the copy
  fallback only the two files it copied. It refuses to run as root and on a
  machine without pacman.
- Tests (`tests/check.sh`): the Target list against a table of real Arch,
  Manjaro and CachyOS package names, using pacman's rule (fnmatch, the last
  matching line decides) and cross-checked with the C library's `fnmatch(3)`;
  a copy of the flag script pointed at a scratch flag file; the installer against scratch
  homes and a scratch system root, with stand-ins for sudo, kpackagetool6 and
  pacman. None needs root.
- README, LICENSE (MIT) and VERSION.

### Changed

- The hook's Target list names every kernel family, not only Manjaro's
  `linux[0-9]*`: Arch's `linux`, `linux-lts`, `linux-zen`, `linux-hardened`,
  `linux-rt` and `linux-rt-lts`, and CachyOS's `linux-cachyos*`. Every
  `*-headers`, `*-docs`, `*-dbg` and `*-debug` package is excluded (previously
  only Manjaro's headers were).
- Microcode for both vendors (`intel-ucode` beside `amd-ucode`) and GPU
  drivers for all three (`vulkan-intel` beside `mesa` and `vulkan-radeon`,
  and NVIDIA's drivers by an allowlist that leaves out its tools such as
  `nvidia-settings`: `nvidia`, `nvidia-lts`, `nvidia-open*`, `nvidia*-dkms`
  and `nvidia*-utils`).
- The hook's comment names this repository instead of a path on the author's
  machine.
- `reboot-required-flag` writes nothing when no package names arrive; before,
  it rewrote the flag (or created an empty one).
- `metadata.json` says 1.2.0 and describes a panel widget, not a tray icon.
- `main.qml`'s comments no longer refer to the author's machine or his other
  widgets; its code is unchanged.

## [1.1.1] - 2026-10-27 (patch)

As installed, first in a repo: the widget, the pacman hook and the flag script
exactly as they ran on the author's workstation, where they had been installed
by hand. The date is the day it entered the repository; no earlier version was
kept in one.
