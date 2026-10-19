#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MODE="${1:-run}"
case "$MODE" in run|--verify|--logs|--build-only) ;; *) echo "usage: $0 [--build-only|--verify|--logs]" >&2; exit 2 ;; esac
mkdir -p "$ROOT_DIR/build"
# Release optimization does not make a local build production analytics traffic.
ANALYTICS_ENVIRONMENT="${ON_SCREEN_ANALYTICS_ENVIRONMENT:-development}"
ANALYTICS_INTERNAL="${ON_SCREEN_ANALYTICS_INTERNAL:-true}"
if ! xcodebuild -project "$ROOT_DIR/On Screen.xcodeproj" -scheme "On Screen" -configuration Release SYMROOT="$ROOT_DIR/build/App" ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES ALWAYS_SEARCH_USER_PATHS=NO ON_SCREEN_ANALYTICS_ENVIRONMENT="$ANALYTICS_ENVIRONMENT" ON_SCREEN_ANALYTICS_INTERNAL="$ANALYTICS_INTERNAL" build > "$ROOT_DIR/build/app-build.log" 2>&1; then
  tail -60 "$ROOT_DIR/build/app-build.log"
  exit 1
fi
if [[ "$MODE" == "--build-only" ]]; then exit 0; fi

APP_BUNDLE="$ROOT_DIR/dist/On Screen.app"
SYSTEM_BUNDLE="/Applications/On Screen.app"
BUILT_BUNDLE="$ROOT_DIR/build/App/Release/On Screen.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT_BUNDLE/Contents/Info.plist")
# Leave the running app and installed bundles intact until a build succeeds.
mkdir -p "$ROOT_DIR/dist"
for DEST in "$APP_BUNDLE" "$SYSTEM_BUNDLE"; do
  if [[ -d "$DEST" ]]; then
    EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")
    [[ "$EXISTING_ID" == "$BUNDLE_ID" ]] || { echo "Refusing to replace unrelated app: $DEST" >&2; exit 1; }
  fi
done
# Identify previous installations by their stable identity, regardless of name.
for DEST in "$ROOT_DIR/dist/"*.app /Applications/*.app "$HOME/Applications/"*.app; do
  [[ -f "$DEST/Contents/Info.plist" ]] || continue
  EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null) || continue
  [[ "$EXISTING_ID" == "$BUNDLE_ID" ]] || continue
  EXISTING_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$DEST/Contents/Info.plist")
  pkill -x "$EXISTING_EXECUTABLE" >/dev/null 2>&1 || true
  BACKUP_DIR="$(mktemp -d "$ROOT_DIR/build/replaced.XXXXXX")"
  mv "$DEST" "$BACKUP_DIR/previous-app.retired"
done
for DEST in "$APP_BUNDLE" "$SYSTEM_BUNDLE"; do
  ditto "$BUILT_BUNDLE" "$DEST"
  codesign --verify --deep --strict "$DEST"
done
/usr/bin/open "$SYSTEM_BUNDLE"
case "$MODE" in
  --verify) sleep 2; pgrep -x "On Screen" ;;
  --logs) /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  run) ;;
esac
