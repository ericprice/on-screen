#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DMG="$ROOT_DIR/dist/ISO 8601 Kawara-1.0.dmg"
# notarytool securely prompts for the app-specific password. It is neither
# passed as a command-line argument nor stored by this script.
xcrun notarytool submit "$DMG" --apple-id "${APPLE_ID:?Set APPLE_ID to your Apple Developer account email}" --team-id "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
printf 'Notarized and verified: %s\n' "$DMG"
