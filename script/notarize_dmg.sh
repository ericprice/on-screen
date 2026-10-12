#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/App/Info.plist")"
DMG="$ROOT_DIR/dist/On-Screen-$VERSION.dmg"
# notarytool securely prompts for the app-specific password. It is neither
# passed as a command-line argument nor stored by this script.
xcrun notarytool submit "$DMG" --apple-id "${APPLE_ID:?Set APPLE_ID to your Apple Developer account email}" --team-id "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
printf 'Notarized and verified: %s\n' "$DMG"
