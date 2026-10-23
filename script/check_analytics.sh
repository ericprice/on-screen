#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CHECK_DIR="$ROOT_DIR/build/analytics-checks"
PACKAGES_DIR="$ROOT_DIR/build/SourcePackages"
mkdir -p "$CHECK_DIR/Sources/AnalyticsChecks"
# Fail before resolution can switch an existing checkout with local changes.
python3 "$ROOT_DIR/script/verify_package_pins.py" --check-existing-cleanliness \
  "$ROOT_DIR/On Screen.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$PACKAGES_DIR"
# Resolve every run: existing directories can belong to another branch or SDK pin.
if ! xcodebuild -resolvePackageDependencies -project "$ROOT_DIR/On Screen.xcodeproj" \
    -scheme "On Screen" -clonedSourcePackagesDirPath "$PACKAGES_DIR" \
    -onlyUsePackageVersionsFromResolvedFile > "$CHECK_DIR/resolve.log" 2>&1; then
  tail -60 "$CHECK_DIR/resolve.log"
  exit 1
fi
python3 "$ROOT_DIR/script/verify_package_pins.py" \
  "$ROOT_DIR/On Screen.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$PACKAGES_DIR"
ln -sfn "$PACKAGES_DIR/artifacts/sparkle/Sparkle/Sparkle.xcframework" "$CHECK_DIR/Sparkle.xcframework"
for SOURCE in Analytics AnalyticsContext AppRunningDailyReporter PostHogConfiguration DesktopAppDelegate DiagnosticsWriter DateDisplayFormat DateFormatMenuPreviews DailyUpdateScheduler TimestampView; do
  ln -sf "$ROOT_DIR/App/$SOURCE.swift" "$CHECK_DIR/Sources/AnalyticsChecks/$SOURCE.swift"
done
ln -sf "$ROOT_DIR/Tests/AnalyticsChecks.swift" "$CHECK_DIR/Sources/AnalyticsChecks/Checks.swift"
ln -sf "$ROOT_DIR/Tests/PostHogIntegrationChecks.swift" "$CHECK_DIR/Sources/AnalyticsChecks/PostHogIntegrationChecks.swift"
cat > "$CHECK_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AnalyticsChecks",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../SourcePackages/checkouts/posthog-ios")
    ],
    targets: [
        .binaryTarget(name: "Sparkle", path: "Sparkle.xcframework"),
        .executableTarget(name: "AnalyticsChecks", dependencies: [
            .product(name: "PostHog", package: "posthog-ios"), "Sparkle"
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
    ]
)
SWIFT
if ! swift build --package-path "$CHECK_DIR" > "$CHECK_DIR/build.log" 2>&1; then
  tail -60 "$CHECK_DIR/build.log"
  exit 1
fi
BIN_DIR="$(swift build --package-path "$CHECK_DIR" --show-bin-path)"
APP="$CHECK_DIR/AnalyticsChecks.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/AnalyticsChecks" "$APP/Contents/MacOS/AnalyticsChecks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
for BUNDLE in "$BIN_DIR/"*.bundle; do
  [[ -d "$BUNDLE" ]] && ditto "$BUNDLE" "$APP/Contents/Resources/$(basename "$BUNDLE")"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>info.ericprice.on-screen.analytics-checks</string>
<key>CFBundleExecutable</key><string>AnalyticsChecks</string>
<key>CFBundleName</key><string>Analytics Checks</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>SUFeedURL</key><string>https://example.invalid/appcast.xml</string>
</dict></plist>
PLIST
cat > "$APP/Contents/Resources/PostHogConfiguration.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>ON_SCREEN_ANALYTICS_ENVIRONMENT</key><string>test</string>
<key>ON_SCREEN_ANALYTICS_INTERNAL</key><string>true</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" > "$CHECK_DIR/sign.log" 2>&1
CHECK_HOME=""
trap 'if [[ -n "$CHECK_HOME" ]]; then rm -rf "$CHECK_HOME"; fi' EXIT
for MODE in enabled disabled integration-enabled integration-disabled; do
  REPORT="$CHECK_DIR/$MODE.txt"
  CHECK_HOME="$(mktemp -d "$CHECK_DIR/home-$MODE.XXXXXX")"
  rm -f "$REPORT" "$CHECK_DIR/$MODE.stdout" "$CHECK_DIR/$MODE.stderr"
  /usr/bin/open -n -W --env "CFFIXED_USER_HOME=$CHECK_HOME" --stdout "$CHECK_DIR/$MODE.stdout" --stderr "$CHECK_DIR/$MODE.stderr" "$APP" --args "--$MODE" "$REPORT"
  [[ -f "$REPORT" ]] || { cat "$CHECK_DIR/$MODE.stderr" >&2; echo "Analytics checks exited without a report" >&2; exit 1; }
  cat "$REPORT"
  [[ "$(head -c 4 "$REPORT")" == PASS ]] || exit 1
  rm -rf "$CHECK_HOME"
  CHECK_HOME=""
done
