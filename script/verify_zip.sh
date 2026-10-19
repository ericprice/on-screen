#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CHECK_DIR="$(mktemp -d "$ROOT_DIR/build/zip-check.XXXXXX")"
ditto -x -k "${1:?Pass the release ZIP}" "$CHECK_DIR"
APP="$CHECK_DIR/On Screen.app"
python3 - "$CHECK_DIR" "$ROOT_DIR" <<'PYTHON'
import pathlib, plistlib, sys
check, root = map(pathlib.Path, sys.argv[1:])
app = check / "On Screen.app"
assert list(check.iterdir()) == [app], "ZIP must contain only On Screen.app"
with (app / "Contents/Info.plist").open("rb") as file:
    actual = plistlib.load(file)
with (root / "App/Info.plist").open("rb") as file:
    expected = plistlib.load(file)
assert actual["CFBundleIdentifier"] == "info.ericprice.on-screen"
for key in ["CFBundleShortVersionString", "CFBundleVersion", "SUPublicEDKey"]:
    assert actual[key] == expected[key], key
resources = app / "Contents/Resources"
for name, source in [("LICENSE", "LICENSE"), ("README.md", "README.md"), ("CC-BY-SA-4.0.txt", "Licenses/CC-BY-SA-4.0.txt")]:
    assert (resources / name).read_bytes() == (root / source).read_bytes(), name
assert "SPARKLE LICENSES AND NOTICES" in (resources / "LICENSE").read_text()
for name in ["Sparkle.txt", "THIRD-PARTY-NOTICES.md", "Licenses.txt"]:
    assert not (resources / name).exists(), name
PYTHON
python3 "$ROOT_DIR/script/configure_posthog.py" --validate-distribution-app "$APP"
codesign --verify --deep --strict "$APP"
APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/On Screen")"
[[ " $APP_ARCHS " == *" arm64 "* && " $APP_ARCHS " == *" x86_64 "* ]] || { echo "Missing universal architectures: $APP_ARCHS" >&2; exit 1; }
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
printf 'Verified signed, notarized app and bundled licenses: %s\n' "$1"
