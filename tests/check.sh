#!/usr/bin/env bash
# All of Reboot Sentinel's checks: syntax of every shell file, shellcheck when
# it is installed, the package metadata and versions, a guard on main.qml,
# then the trigger-list, flag-script and installer tests. Nothing here needs
# root or touches the real /etc, /usr, /run or ~/.local.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_FILES=("$REPO/install.sh" "$REPO/tests/check.sh" "$REPO/tests/test_flag.sh" "$REPO/tests/test_install.sh")
SH_FILES=("$REPO/pacman/reboot-required-flag")

for f in "${BASH_FILES[@]}"; do
    bash -n "$f"
done
for f in "${SH_FILES[@]}"; do
    sh -n "$f"
done
echo "ok - syntax: ${#BASH_FILES[@]} bash files, ${#SH_FILES[@]} sh file"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${BASH_FILES[@]}" "${SH_FILES[@]}"
    echo "ok - shellcheck"
else
    echo "skip - shellcheck not installed"
fi

python3 -I - "$REPO" <<'PY'
import json, pathlib, re, sys
repo = pathlib.Path(sys.argv[1])
version = (repo / "VERSION").read_text(encoding="utf-8").strip()
meta = json.loads((repo / "package" / "metadata.json").read_text(encoding="utf-8"))
plugin = meta["KPlugin"]
installer = (repo / "install.sh").read_text(encoding="utf-8")
changelog = (repo / "CHANGELOG.md").read_text(encoding="utf-8")
released = re.findall(r"^## \[(\d+\.\d+\.\d+)\]", changelog, re.M)

assert re.fullmatch(r"\d+\.\d+\.\d+", version), f"VERSION is not semver: {version!r}"
assert plugin["Version"] == version, f"metadata.json says {plugin['Version']}, VERSION says {version}"
assert released and released[0] == version, f"CHANGELOG's newest release is {released[:1]}, not {version}"
assert f"PLASMOID_ID={plugin['Id']}\n" in installer, "install.sh's PLASMOID_ID is not metadata.json's Id"
assert meta["KPackageStructure"] == "Plasma/Applet", "not a Plasma/Applet package"
assert meta["X-Plasma-API-Minimum-Version"] == "6.0", "the minimum Plasma API is not 6.0"
print(f"ok - metadata.json is valid, and VERSION, metadata.json and CHANGELOG agree on {version}")

qml = (repo / "package" / "contents" / "ui" / "main.qml").read_text(encoding="utf-8")
code = "\n".join(line.split("//", 1)[0] for line in qml.splitlines())
for bad, why in [
    (r"^import\s+\S+\s+[0-9]", "a versioned (Plasma 5 style) import"),
    (r"org\.kde\.plasma\.components|org\.kde\.plasma\.extras", "a Plasma 5 era components import"),
    (r"\bqdbus\s", "Qt 5's qdbus (Plasma 6 ships qdbus6)"),
    (r"/home/|/root/|~/", "a path in one user's home other than $HOME"),
]:
    assert not re.search(bad, code, re.M), f"main.qml has {why}"
print("ok - main.qml uses Plasma 6 imports and qdbus6, and names no one's home")
PY

"$REPO/tests/test_targets.py"
"$REPO/tests/test_flag.sh"
"$REPO/tests/test_install.sh"
