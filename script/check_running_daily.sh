#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$ROOT_DIR/build"
xcrun swiftc -swift-version 6 "$ROOT_DIR/App/AppRunningDailyReporter.swift" "$ROOT_DIR/Tests/RunningDailyChecks.swift" -o "$ROOT_DIR/build/RunningDailyChecks"
"$ROOT_DIR/build/RunningDailyChecks"
