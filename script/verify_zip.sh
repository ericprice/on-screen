#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: $0 ZIP [--before-notarization]" >&2; exit 2; }
MODE="${2:-notarized}"
case "$MODE" in notarized|--before-notarization) ;; *) echo "Unknown verification mode: $MODE" >&2; exit 2 ;; esac
[[ -f "$1" ]] || { echo "Release ZIP does not exist: $1" >&2; exit 1; }
mkdir -p "$ROOT_DIR/build"
CHECK_DIR="$(mktemp -d "$ROOT_DIR/build/zip-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
ditto -x -k "${1:?Pass the release ZIP}" "$CHECK_DIR"
APP="$CHECK_DIR/On Screen.app"
python3 - "$CHECK_DIR" <<'PYTHON'
import pathlib, sys
check = pathlib.Path(sys.argv[1])
if list(check.iterdir()) != [check / "On Screen.app"]:
    sys.exit("ZIP must contain only On Screen.app")
PYTHON
python3 "$ROOT_DIR/script/validate_release_app.py" "$APP"
python3 "$ROOT_DIR/script/configure_posthog.py" --validate-distribution-app "$APP"
codesign --verify --deep --strict "$APP"
APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/On Screen")"
[[ " $APP_ARCHS " == *" arm64 "* && " $APP_ARCHS " == *" x86_64 "* ]] || { echo "Missing universal architectures: $APP_ARCHS" >&2; exit 1; }
if [[ "$MODE" == "notarized" ]]; then
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  printf 'Verified signed, notarized app and bundled licenses: %s\n' "$1"
else
  printf 'Verified signed app and release metadata before notarization: %s\n' "$1"
fi
