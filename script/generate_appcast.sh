#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Use tools from Sparkle 2.10.0's official distribution (or Xcode's resolved package).
SPARKLE_BIN="${SPARKLE_BIN:?Set SPARKLE_BIN to the directory containing generate_appcast and generate_keys}"
ACCOUNT="${SPARKLE_KEY_ACCOUNT:-iso-8601-kawara}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/App/Info.plist")"
TAG="v$VERSION"
REPOSITORY="ericprice/iso-8601-kawara"
DMG="${UPDATE_DMG:-$ROOT_DIR/dist/ISO-8601-Kawara-$VERSION.dmg}"
NOTES="$ROOT_DIR/releases/$VERSION.md"
[[ -f "$DMG" && -f "$NOTES" ]] || { echo "Build and notarize the DMG and add release notes first." >&2; exit 1; }
# Only notarized, stapled, Developer ID signed archives may become update assets.
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p)"
EXPECTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT_DIR/App/Info.plist")"
[[ "$PUBLIC_KEY" == "$EXPECTED_KEY" ]] || { echo "The Keychain signing key does not match the app's public key." >&2; exit 1; }
# Keep each release isolated: one full DMG, embedded notes, no delta assets.
STAGING_DIR="$(mktemp -d "$ROOT_DIR/build/appcast.XXXXXX")"
ditto "$DMG" "$STAGING_DIR/$(basename "$DMG")"
cp "$NOTES" "$STAGING_DIR/$(basename "$DMG" .dmg).md"
"$SPARKLE_BIN/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$TAG/" \
  --link "https://github.com/$REPOSITORY/releases/tag/$TAG" "$STAGING_DIR"
python3 - "$STAGING_DIR/appcast.xml" "$VERSION" "$DMG" "$ROOT_DIR/App/Info.plist" <<'PYTHON'
import pathlib, plistlib, sys, xml.etree.ElementTree as ET
feed, version, dmg, info_path = sys.argv[1:]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
items = ET.parse(feed).findall("./channel/item")
assert len(items) == 1, "Expected exactly one update"
item = items[0]
enclosure = item.find("enclosure")
assert item.findtext("sparkle:shortVersionString", namespaces=ns) == version
with open(info_path, "rb") as file:
    assert item.findtext("sparkle:version", namespaces=ns) == plistlib.load(file)["CFBundleVersion"]
assert enclosure.get("url") == f"https://github.com/ericprice/iso-8601-kawara/releases/download/v{version}/{pathlib.Path(dmg).name}"
assert enclosure.get("{%s}edSignature" % ns["sparkle"]), "Missing update signature"
assert int(enclosure.get("length")) == pathlib.Path(dmg).stat().st_size
PYTHON
cp "$STAGING_DIR/appcast.xml" "$ROOT_DIR/dist/appcast.xml"
printf 'Ready to upload to GitHub release %s:\n  %s\n  %s\n' "$TAG" "$DMG" "$ROOT_DIR/dist/appcast.xml"
