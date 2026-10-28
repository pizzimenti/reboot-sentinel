#!/usr/bin/env python3
"""Check the pacman hook's Target list against real package names.

pacman (libalpm's _alpm_fnmatch_patterns) walks a hook's Targets from the
last one back to the first and stops at the first that matches the package
name with fnmatch(3), flags 0: a plain line means the hook fires, a line
starting with ! means it does not, and a name no line matches does not fire
it. A leading backslash escapes a literal !. That is "applied in order, the
last match wins" (alpm-hooks(5): "subsequent matches overriding previous
ones"), which is what matches() below does.

Python's fnmatch.fnmatchcase agrees with fnmatch(3) on *, ? and [...] with
[!...]; it differs on backslash escapes and on [^...], so the list must use
neither, and this test checks that first.

The names are real: Arch and CachyOS ones from their sync databases
(core, extra, cachyos) in October 2026, Manjaro's from its kernel and
extramodules naming (linuxNNN, linuxNNN-<module>).
"""
import fnmatch
import pathlib
import sys

HOOK = pathlib.Path(__file__).resolve().parent.parent / "pacman" / "99-reboot-required.hook"

YES, NO = True, False

TABLE = [
    # --- kernels: Arch -------------------------------------------------------
    ("linux", YES),
    ("linux-lts", YES),
    ("linux-zen", YES),
    ("linux-hardened", YES),
    ("linux-rt", YES),
    ("linux-rt-lts", YES),
    ("linux-headers", NO),
    ("linux-lts-headers", NO),
    ("linux-zen-headers", NO),
    ("linux-hardened-headers", NO),
    ("linux-rt-headers", NO),
    ("linux-rt-lts-headers", NO),
    ("linux-docs", NO),
    ("linux-lts-docs", NO),
    ("linux-zen-docs", NO),
    ("linux-hardened-docs", NO),
    ("linux-rt-docs", NO),
    ("linux-rt-lts-docs", NO),
    # Arch packages that start with "linux" and are not kernels
    ("linux-api-headers", NO),
    ("linux-atm", NO),
    ("linux-tools-meta", NO),
    ("linux-apfs-rw-dkms", NO),
    ("linuxconsole", NO),
    ("linuxdoc-tools", NO),
    ("linuxptp", NO),
    ("linuxsampler", NO),
    ("linuxwave", NO),
    # --- kernels and extramodules: Manjaro -------------------------------------
    ("linux61", YES),
    ("linux66", YES),
    ("linux612", YES),
    ("linux612-rt", YES),
    ("linux612-nvidia", YES),
    ("linux612-zfs", YES),
    ("linux612-r8168", YES),
    ("linux612-virtualbox-host-modules", YES),
    ("linux61-headers", NO),
    ("linux612-headers", NO),
    ("linux612-rt-headers", NO),
    # --- kernels and their module packages: CachyOS ------------------------------
    ("linux-cachyos", YES),
    ("linux-cachyos-lts", YES),
    ("linux-cachyos-bore", YES),
    ("linux-cachyos-eevdf", YES),
    ("linux-cachyos-bmq", YES),
    ("linux-cachyos-rc", YES),
    ("linux-cachyos-hardened", YES),
    ("linux-cachyos-server", YES),
    ("linux-cachyos-deckify", YES),
    ("linux-cachyos-rt-bore", YES),
    ("linux-cachyos-nvidia-open", YES),
    ("linux-cachyos-lts-nvidia-open", YES),
    ("linux-cachyos-rc-nvidia", YES),
    ("linux-cachyos-zfs", YES),
    ("linux-cachyos-r8125", YES),
    ("linux-cachyos-headers", NO),
    ("linux-cachyos-lts-headers", NO),
    ("linux-cachyos-bore-headers", NO),
    ("linux-cachyos-rc-headers", NO),
    ("linux-cachyos-rt-bore-headers", NO),
    ("linux-cachyos-dbg", NO),
    ("linux-cachyos-rc-dbg", NO),
    ("linux-cachyos-server-dbg", NO),
    # --- firmware (all three) ------------------------------------------------------
    ("linux-firmware", YES),
    ("linux-firmware-amdgpu", YES),
    ("linux-firmware-intel", YES),
    ("linux-firmware-nvidia", YES),
    ("linux-firmware-realtek", YES),
    ("linux-firmware-whence", YES),
    # --- microcode -------------------------------------------------------------------
    ("amd-ucode", YES),
    ("intel-ucode", YES),
    # --- core userspace --------------------------------------------------------------
    ("systemd", YES),
    ("glibc", YES),
    ("dbus", YES),
    ("systemd-libs", NO),
    ("systemd-sysvcompat", NO),
    ("systemd-boot-manager", NO),
    ("glibc-locales", NO),
    ("dbus-broker", NO),
    ("dbus-glib", NO),
    ("dbus-docs", NO),
    # --- GPU drivers and the Wayland stack -------------------------------------------
    ("mesa", YES),
    ("vulkan-radeon", YES),
    ("vulkan-intel", YES),
    ("nvidia-utils", YES),
    ("nvidia-open", YES),
    ("nvidia-open-dkms", YES),
    ("nvidia-open-lts", YES),
    ("nvidia-580xx-dkms", YES),
    ("nvidia-580xx-utils", YES),
    ("nvidia-470xx-dkms", YES),
    ("nvidia-settings", YES),  # nvidia* takes the whole family; a harmless extra
    ("egl-wayland", YES),
    ("wayland", YES),
    ("mesa-docs", NO),
    ("mesa-utils", NO),
    ("mesa-demos", NO),
    ("lib32-mesa", NO),  # upgrades together with mesa, which flags it
    ("lib32-nvidia-utils", NO),  # likewise with nvidia-utils
    ("vulkan-icd-loader", NO),
    ("wayland-protocols", NO),
    ("wayland-utils", NO),
    ("wayland-docs", NO),
    # --- ordinary packages --------------------------------------------------------------
    ("pacman", NO),
    ("yay", NO),
    ("plasma-workspace", NO),
    ("firefox", NO),
    ("xf86-video-amdgpu", NO),
]


def read_hook(path):
    """Return {section: [(key, value)]} the way pacman's ini parser reads it:
    everything from # to the end of a line is a comment, keys and values are
    trimmed, a key without = has the value None."""
    sections, current = {}, None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections.setdefault(current, [])
            continue
        if current is None:
            raise ValueError(f"{path}: key outside a section: {raw!r}")
        key, sep, value = line.partition("=")
        sections[current].append((key.strip(), value.strip() if sep else None))
    return sections


def matches(patterns, name):
    """libalpm's _alpm_fnmatch_patterns: True if the hook fires for name."""
    for pattern in reversed(patterns):
        inverted = pattern.startswith("!")
        if inverted or pattern.startswith("\\"):
            pattern = pattern[1:]
        if fnmatch.fnmatchcase(name, pattern):
            return not inverted
    return False


def load_libc_fnmatch():
    """The C library's fnmatch(3), or None where it cannot be loaded."""
    try:
        import ctypes
        import ctypes.util
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
        fn = libc.fnmatch
    except (OSError, AttributeError):
        return None
    fn.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int)
    fn.restype = ctypes.c_int
    return fn


def main():
    count = 0
    failures = []

    def check(condition, label):
        nonlocal count
        count += 1
        if condition:
            print(f"ok {count} - {label}")
        else:
            print(f"not ok {count} - {label}")
            failures.append(label)

    sections = read_hook(HOOK)
    trigger = sections.get("Trigger", [])
    action = sections.get("Action", [])
    targets = [v for k, v in trigger if k == "Target"]

    check(sorted(v for k, v in trigger if k == "Operation") == ["Install", "Remove", "Upgrade"]
          and ("Type", "Package") in trigger,
          "the trigger fires on install, upgrade and remove of packages")
    check(("When", "PostTransaction") in action
          and ("Exec", "/usr/local/bin/reboot-required-flag") in action
          and ("NeedsTargets", None) in action,
          "the action runs the flag script after the transaction with the matched names")
    check(len(targets) > 0 and all(t and "\\" not in t and "[^" not in t for t in targets),
          "every Target is non-empty and avoids \\ and [^, where Python and fnmatch(3) differ")
    check(len(set(targets)) == len(targets), "no Target is listed twice")
    text = HOOK.read_text(encoding="utf-8")
    check("https://github.com/pizzimenti/reboot-sentinel" in text and "~/Code" not in text,
          "the hook's comment names the repository, not a path on one machine")

    names = [name for name, _ in TABLE]
    check(len(set(names)) == len(names), "no package name is listed twice in the table")

    libc_fnmatch = load_libc_fnmatch()
    if libc_fnmatch is None:
        print("skip - the C library's fnmatch(3) could not be loaded for the cross-check")
    else:
        pairs = [(p.lstrip("!"), n) for p in targets for n in names]
        disagree = [(p, n) for p, n in pairs
                    if (libc_fnmatch(p.encode(), n.encode(), 0) == 0) != fnmatch.fnmatchcase(n, p)]
        check(not disagree, f"Python's fnmatch agrees with the C library's fnmatch(3), which "
              f"pacman calls, on all {len(pairs)} Target and name pairs"
              + ("" if not disagree else f" (disagree: {disagree[:5]})"))
    for name, expected in TABLE:
        got = matches(targets, name)
        check(got == expected, f"{name}: {'flags' if expected else 'does not flag'} a reboot"
              + ("" if got == expected else f" (got {'flag' if got else 'no flag'})"))

    # Every plain Target flags at least one name in the table, so no line of
    # the list goes untested. (The exclusions are kept even where no real
    # package needs one today: a future linux-cachyos-docs would.)
    for pattern in targets:
        if not pattern.startswith("!"):
            flagged = [n for n, e in TABLE if e and fnmatch.fnmatchcase(n, pattern)]
            check(bool(flagged), f"{pattern} flags at least one listed name")

    if failures:
        print(f"FAIL: {len(failures)} of {count} target checks failed", file=sys.stderr)
        return 1
    print(f"all {count} target checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
