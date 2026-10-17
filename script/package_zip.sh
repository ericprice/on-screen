#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# An explicit empty value skips notarization; otherwise use the saved profile.
export NOTARY_PROFILE="${NOTARY_PROFILE-on-screen}"
mkdir -p "$ROOT_DIR/build" "$ROOT_DIR/dist"
SIGNING_IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
if [[ -n "${DISTRIBUTION_APP:-}" ]]; then
  BUILT_APP="$DISTRIBUTION_APP"
else
  ARCHIVE="$ROOT_DIR/build/Distribution.xcarchive"
  EXPORT_DIR="$ROOT_DIR/build/Distribution-export"
  # Archive/export signs Sparkle's nested helper tools for Developer ID distribution.
  if ! xcodebuild -project "$ROOT_DIR/On Screen.xcodeproj" -scheme "On Screen" -configuration Release -archivePath "$ARCHIVE" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO ALWAYS_SEARCH_USER_PATHS=NO ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}" CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" archive > "$ROOT_DIR/build/distribution-build.log" 2>&1; then
    tail -60 "$ROOT_DIR/build/distribution-build.log"
    exit 1
  fi
  EXPORT_OPTIONS="$ROOT_DIR/build/ExportOptions.plist"
  python3 - "$EXPORT_OPTIONS" "$DEVELOPMENT_TEAM" "$SIGNING_IDENTITY" <<'PYTHON'
import plistlib, sys
with open(sys.argv[1], "wb") as file:
    plistlib.dump({"method": "developer-id", "teamID": sys.argv[2],
                  "signingStyle": "manual", "signingCertificate": sys.argv[3]}, file)
PYTHON
  if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$EXPORT_OPTIONS" > "$ROOT_DIR/build/distribution-export.log" 2>&1; then
    tail -60 "$ROOT_DIR/build/distribution-export.log"
    exit 1
  fi
  BUILT_APP="$EXPORT_DIR/On Screen.app"
fi
codesign --verify --deep --strict "$BUILT_APP"
APP_ARCHS="$(lipo -archs "$BUILT_APP/Contents/MacOS/On Screen")"
[[ " $APP_ARCHS " == *" arm64 "* && " $APP_ARCHS " == *" x86_64 "* ]] || { echo "Missing universal architectures: $APP_ARCHS" >&2; exit 1; }
for RESOURCE in LICENSE README.md CC-BY-SA-4.0.txt; do
  [[ -f "$BUILT_APP/Contents/Resources/$RESOURCE" ]] || { echo "Missing bundled license resource: $RESOURCE" >&2; exit 1; }
done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
ZIP="$ROOT_DIR/dist/On-Screen-$VERSION.zip"
if [[ -f "$ZIP" ]]; then
  PREVIOUS_DIR="$(mktemp -d "$ROOT_DIR/build/previous-zip.XXXXXX")"
  mv "$ZIP" "$PREVIOUS_DIR/previous.zip"
fi
# Preserve the bundle's permissions, symlinks, and macOS metadata.
ditto -c -k --sequesterRsrc --keepParent "$BUILT_APP" "$ZIP"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  "$ROOT_DIR/script/notarize_zip.sh"
fi
printf 'Created: %s\n' "$ZIP"
