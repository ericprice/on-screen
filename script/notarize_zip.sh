#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# An explicit empty value retains the interactive Apple ID login option.
export NOTARY_PROFILE="${NOTARY_PROFILE-on-screen}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/App/Info.plist")"
[[ $# -le 1 ]] || { echo "usage: $0 [ZIP]" >&2; exit 2; }
ZIP="${1:-$ROOT_DIR/dist/On-Screen-$VERSION.zip}"
# Validate this exact archive before contacting Apple, including its release version.
"$ROOT_DIR/script/verify_zip.sh" "$ZIP" --before-notarization
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
  # Let notarytool prompt securely for the app-specific password.
  AUTH=(--apple-id "${APPLE_ID:?Set APPLE_ID to your Apple Developer account email}" --team-id "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}")
fi
xcrun notarytool submit "$ZIP" "${AUTH[@]}" --wait --output-format json > "$ROOT_DIR/build/notarization-$VERSION.json"
python3 - "$ROOT_DIR/build/notarization-$VERSION.json" <<'PYTHON'
import json, sys
with open(sys.argv[1]) as file:
    result = json.load(file)
assert result["status"] == "Accepted", result
print("Apple notarization accepted:", result["id"])
PYTHON
STAGING_DIR="$(mktemp -d "$ROOT_DIR/build/notarized-zip.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto -x -k "$ZIP" "$STAGING_DIR"
xcrun stapler staple "$STAGING_DIR/On Screen.app"
# ZIP files cannot hold a stapled ticket themselves; archive the stapled app.
ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIR/On Screen.app" "$STAGING_DIR/release.zip"
"$ROOT_DIR/script/verify_zip.sh" "$STAGING_DIR/release.zip"
mv "$STAGING_DIR/release.zip" "$ZIP"
printf 'Notarized and verified: %s\n' "$ZIP"
