#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CHECK_DIR="$ROOT_DIR/build/analytics-checks"
PACKAGES_DIR="$ROOT_DIR/build/SourcePackages"
mkdir -p "$CHECK_DIR/Sources/AnalyticsChecks"
if [[ ! -d "$PACKAGES_DIR/checkouts/SwiftSDK" || ! -d "$PACKAGES_DIR/artifacts/sparkle/Sparkle/Sparkle.xcframework" ]]; then
  xcodebuild -resolvePackageDependencies -project "$ROOT_DIR/On Screen.xcodeproj" \
    -scheme "On Screen" -clonedSourcePackagesDirPath "$PACKAGES_DIR" > "$CHECK_DIR/resolve.log" 2>&1
fi
ln -sfn "$PACKAGES_DIR/artifacts/sparkle/Sparkle/Sparkle.xcframework" "$CHECK_DIR/Sparkle.xcframework"
for SOURCE in Analytics DesktopAppDelegate DateDisplayFormat DailyUpdateScheduler TimestampView; do
  ln -sf "$ROOT_DIR/App/$SOURCE.swift" "$CHECK_DIR/Sources/AnalyticsChecks/$SOURCE.swift"
done
ln -sf "$ROOT_DIR/Tests/AnalyticsChecks.swift" "$CHECK_DIR/Sources/AnalyticsChecks/Checks.swift"
cat > "$CHECK_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AnalyticsChecks",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../SourcePackages/checkouts/SwiftSDK")],
    targets: [
        .binaryTarget(name: "Sparkle", path: "Sparkle.xcframework"),
        .executableTarget(name: "AnalyticsChecks", dependencies: [
            .product(name: "TelemetryDeck", package: "SwiftSDK"), "Sparkle"
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
codesign --force --deep --sign - "$APP" > "$CHECK_DIR/sign.log" 2>&1
for MODE in enabled disabled; do
  REPORT="$CHECK_DIR/$MODE.txt"
  rm -f "$REPORT" "$CHECK_DIR/$MODE.stdout" "$CHECK_DIR/$MODE.stderr"
  /usr/bin/open -n -W --stdout "$CHECK_DIR/$MODE.stdout" --stderr "$CHECK_DIR/$MODE.stderr" "$APP" --args "--$MODE" "$REPORT"
  [[ -f "$REPORT" ]] || { cat "$CHECK_DIR/$MODE.stderr" >&2; echo "Analytics checks exited without a report" >&2; exit 1; }
  cat "$REPORT"
  [[ "$(head -c 4 "$REPORT")" == PASS ]] || exit 1
done
