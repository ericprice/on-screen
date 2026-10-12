#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$ROOT_DIR/build" "$ROOT_DIR/dist"
SIGNING_IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
if [[ -n "${DISTRIBUTION_APP:-}" ]]; then
  BUILT_APP="$DISTRIBUTION_APP"
else
  if ! xcodebuild -project "$ROOT_DIR/ISO8601Kawara.xcodeproj" -target ISO8601Kawara -configuration Release SYMROOT="$ROOT_DIR/build/Distribution" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO ALWAYS_SEARCH_USER_PATHS=NO ENABLE_HARDENED_RUNTIME=YES DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}" CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" build > "$ROOT_DIR/build/distribution-build.log" 2>&1; then
    tail -60 "$ROOT_DIR/build/distribution-build.log"
    exit 1
  fi
  BUILT_APP="$ROOT_DIR/build/Distribution/Release/ISO 8601 Kawara.app"
fi
codesign --verify --deep --strict "$BUILT_APP"
APP_ARCHS="$(lipo -archs "$BUILT_APP/Contents/MacOS/ISO8601Kawara")"
[[ " $APP_ARCHS " == *" arm64 "* && " $APP_ARCHS " == *" x86_64 "* ]] || { echo "Missing universal architectures: $APP_ARCHS" >&2; exit 1; }
STAGING_DIR="$(mktemp -d "$ROOT_DIR/build/dmg.XXXXXX")"
ditto "$BUILT_APP" "$STAGING_DIR/ISO 8601 Kawara.app"
ln -s /Applications "$STAGING_DIR/Applications"
{
  printf 'ISO 8601 Kawara — Licenses and Attribution\n\nApplication code, build scripts, and documentation: MIT License.\nFont assets: CC BY-SA 4.0. Artwork assets are separate from these licenses.\n\n'
  cat "$ROOT_DIR/LICENSE"
  printf '\n\nFONT ATTRIBUTION AND MODIFICATIONS\n\n'
  sed -e 's/^#* //' -e 's/`//g' "$ROOT_DIR/THIRD-PARTY-NOTICES.md"
  printf '\n\nFULL FONT LICENSE — CC BY-SA 4.0\n\n'
  cat "$ROOT_DIR/Licenses/CC-BY-SA-4.0.txt"
} > "$STAGING_DIR/Licenses.txt"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
DMG="$ROOT_DIR/dist/ISO-8601-Kawara-$VERSION.dmg"
if [[ -f "$DMG" ]]; then
  PREVIOUS_DIR="$(mktemp -d "$ROOT_DIR/build/previous-dmg.XXXXXX")"
  mv "$DMG" "$PREVIOUS_DIR/previous.dmg"
fi
# macOS 27 uses diskutil for image creation and attachment.
diskutil image create from --volumeName "ISO 8601 Kawara" --format UDZO "$STAGING_DIR" "$DMG"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
MOUNT_DIR="$(mktemp -d "$ROOT_DIR/build/dmg-check.XXXXXX")"
diskutil image attach --readOnly --nobrowse --mountPoint "$MOUNT_DIR" "$DMG"
trap 'diskutil eject "$MOUNT_DIR" >/dev/null 2>&1 || true' EXIT
codesign --verify --deep --strict "$MOUNT_DIR/ISO 8601 Kawara.app"
cmp "$STAGING_DIR/Licenses.txt" "$MOUNT_DIR/Licenses.txt"
[[ "$(readlink "$MOUNT_DIR/Applications")" == /Applications ]]
diskutil eject "$MOUNT_DIR"
trap - EXIT
printf 'Created: %s\n' "$DMG"
