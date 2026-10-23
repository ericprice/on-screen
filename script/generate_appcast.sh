#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Use tools from Sparkle 2.10.0's official distribution (or Xcode's resolved package).
SPARKLE_BIN="${SPARKLE_BIN:?Set SPARKLE_BIN to the directory containing generate_appcast and generate_keys}"
ACCOUNT="${SPARKLE_KEY_ACCOUNT:-info.ericprice.on-screen}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/App/Info.plist")"
TAG="v$VERSION"
REPOSITORY="ericprice/on-screen"
ZIP="${UPDATE_ZIP:-$ROOT_DIR/dist/On-Screen-$VERSION.zip}"
[[ -f "$ZIP" ]] || { echo "Build and notarize the ZIP first." >&2; exit 1; }
# Only archives containing notarized, stapled, Developer ID signed apps may become update assets.
"$ROOT_DIR/script/verify_zip.sh" "$ZIP"
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p)"
EXPECTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT_DIR/App/Info.plist")"
[[ "$PUBLIC_KEY" == "$EXPECTED_KEY" ]] || { echo "The Keychain signing key does not match the app's public key." >&2; exit 1; }
# Keep each release isolated: one full ZIP, optional embedded notes, no deltas.
STAGING_DIR="$(mktemp -d "$ROOT_DIR/build/appcast.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$ZIP" "$STAGING_DIR/$(basename "$ZIP")"
if [[ -n "${RELEASE_NOTES_FILE:-}" ]]; then
  # An HTML fragment is embedded directly, so no additional hosted asset is needed.
  ditto "$RELEASE_NOTES_FILE" "$STAGING_DIR/$(basename "$ZIP" .zip).html"
fi
"$SPARKLE_BIN/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$TAG/" \
  --link "https://github.com/$REPOSITORY/releases/tag/$TAG" "$STAGING_DIR"
python3 - "$STAGING_DIR/appcast.xml" "$VERSION" "$ZIP" "$ROOT_DIR/App/Info.plist" "${RELEASE_NOTES_FILE:-}" <<'PYTHON'
import pathlib, plistlib, sys, xml.etree.ElementTree as ET
feed, version, archive, info_path, notes_path = sys.argv[1:]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
items = ET.parse(feed).findall("./channel/item")
assert len(items) == 1, "Expected exactly one update"
assert ET.parse(feed).findtext("./channel/title") == "On Screen"
item = items[0]
enclosure = item.find("enclosure")
assert item.findtext("sparkle:shortVersionString", namespaces=ns) == version
if notes_path:
    assert item.findtext("description").strip() == pathlib.Path(notes_path).read_text().strip()
else:
    assert item.find("description") is None
assert item.find("sparkle:releaseNotesLink", namespaces=ns) is None
with open(info_path, "rb") as file:
    assert item.findtext("sparkle:version", namespaces=ns) == plistlib.load(file)["CFBundleVersion"]
assert enclosure.get("url") == f"https://github.com/ericprice/on-screen/releases/download/v{version}/{pathlib.Path(archive).name}"
assert enclosure.get("{%s}edSignature" % ns["sparkle"]), "Missing update signature"
assert int(enclosure.get("length")) == pathlib.Path(archive).stat().st_size
PYTHON
cp "$STAGING_DIR/appcast.xml" "$ROOT_DIR/dist/appcast.xml"
printf 'Ready to upload to GitHub release %s:\n  %s\n  %s\n' "$TAG" "$ZIP" "$ROOT_DIR/dist/appcast.xml"
