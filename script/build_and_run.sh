#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MODE="${1:-run}"
case "$MODE" in run|--verify|--logs|--build-only) ;; *) echo "usage: $0 [--build-only|--verify|--logs]" >&2; exit 2 ;; esac
APP_BUNDLE="$ROOT_DIR/dist/ISO 8601 Today.app"
INSTALLED_BUNDLE="$HOME/Applications/ISO 8601 Today.app"
SYSTEM_BUNDLE="/Applications/ISO 8601 Today.app"
pkill -x ISO8601Today >/dev/null 2>&1 || true
pkill -x ISO8601Kawara >/dev/null 2>&1 || true
pkill -x OnKawara >/dev/null 2>&1 || true
mkdir -p "$ROOT_DIR/build" "$ROOT_DIR/dist" "$HOME/Applications"
if ! xcodebuild -project "$ROOT_DIR/ISO8601Today.xcodeproj" -scheme ISO8601Today -configuration Release SYMROOT="$ROOT_DIR/build/App" ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES ALWAYS_SEARCH_USER_PATHS=NO build > "$ROOT_DIR/build/app-build.log" 2>&1; then
  tail -60 "$ROOT_DIR/build/app-build.log"
  exit 1
fi
for DEST in "$ROOT_DIR/dist/ISO 8601 On Kawara.app" "$HOME/Applications/ISO 8601 On Kawara.app" "$ROOT_DIR/dist/ISO 8601 Kawara.app" "$HOME/Applications/ISO 8601 Kawara.app" "/Applications/ISO 8601 Kawara.app" "$APP_BUNDLE" "$INSTALLED_BUNDLE" "$SYSTEM_BUNDLE"; do
  if [[ -d "$DEST" ]]; then
    EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")
    [[ "$EXISTING_ID" == "dev.ericprice.iso8601-on-kawara" ]] || { echo "Refusing to replace unrelated app: $DEST" >&2; exit 1; }
    BACKUP_DIR="$(mktemp -d "$ROOT_DIR/build/replaced.XXXXXX")"
    mv "$DEST" "$BACKUP_DIR/ISO8601Kawara.retired"
  fi
done
for DEST in "$APP_BUNDLE" "$INSTALLED_BUNDLE" "$SYSTEM_BUNDLE"; do
  ditto "$ROOT_DIR/build/App/Release/ISO 8601 Today.app" "$DEST"
  codesign --verify --deep --strict "$DEST"
done
if [[ "$MODE" == "--build-only" ]]; then exit 0; fi
/usr/bin/open "$SYSTEM_BUNDLE"
case "$MODE" in
  --verify) sleep 2; pgrep -x ISO8601Today ;;
  --logs) /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.ericprice.iso8601-on-kawara"' ;;
  run) ;;
esac
