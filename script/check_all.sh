#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/script/check_date_formats.sh"
"$ROOT_DIR/script/check_running_daily.sh"
"$ROOT_DIR/script/check_distribution.sh"
"$ROOT_DIR/script/check_analytics.sh"
"$ROOT_DIR/script/build_and_run.sh" --build-only
printf 'All local checks and the build passed.\n'
