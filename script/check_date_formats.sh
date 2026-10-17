#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$ROOT_DIR/build"
xcrun swiftc -swift-version 6 "$ROOT_DIR/App/DateDisplayFormat.swift" "$ROOT_DIR/App/DailyUpdateScheduler.swift" "$ROOT_DIR/App/TimestampView.swift" "$ROOT_DIR/Tests/DateDisplayFormatChecks.swift" -o "$ROOT_DIR/build/DateDisplayFormatChecks"
"$ROOT_DIR/build/DateDisplayFormatChecks"
