import AppKit
import Foundation
import ServiceManagement
import Sparkle
import PostHog

// Intercept the real SDK transport; fake credentials never reach a server.
final class AnalyticsCaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var postHogEvents: [[String: Any]] = []
    nonisolated(unsafe) private static var postHogLogs: [[String: Any]] = []
    nonisolated(unsafe) private static var requests: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let batch = body["batch"] as? [[String: Any]] { Self.postHogEvents.append(contentsOf: batch) }
            if body["resourceLogs"] != nil { Self.postHogLogs.append(body) }
        }
        Self.requests.append(request.url!.absoluteString)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func snapshot() -> (postHogEvents: [[String: Any]], postHogLogs: [[String: Any]], requests: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (postHogEvents, postHogLogs, requests)
    }
}

@MainActor
final class WebsiteDelegateCheck: NSObject, NSTextViewDelegate {
    var clicks = 0
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        clicks += 1
        return true // Keep the test from opening a browser.
    }
    func textShouldBeginEditing(_ textObject: NSText) -> Bool { false }
}

private struct CheckFailure: Error { let message: String }
private struct CapturedAction { let event: String; let properties: [String: String] }

@main
enum AnalyticsChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let report = URL(fileURLWithPath: CommandLine.arguments.last!)
        Task { @MainActor in
            do {
                let result = try await run()
                try result.write(to: report, atomically: true, encoding: .utf8)
            } catch {
                try? "FAIL: \(error)\n".write(to: report, atomically: true, encoding: .utf8)
            }
            exit(0)
        }
        NSApp.run()
    }

    @MainActor
    static func run() async throws -> String {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try check(Bundle.main.bundleIdentifier == "info.ericprice.on-screen.analytics-checks", "Must use an isolated test app")
        guard let testHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw CheckFailure(message: "Must launch with an isolated Foundation home")
        }
        let isolatedHome = URL(fileURLWithPath: testHome, isDirectory: true).standardizedFileURL.path + "/"
        for directory in [FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory] {
            try check(FileManager.default.urls(for: directory, in: .userDomainMask).first!.standardizedFileURL.path.hasPrefix(isolatedHome),
                      "SDK storage escaped the isolated test home")
        }
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        defaults.removePersistentDomain(forName: domain)
        defer {
            defaults.removePersistentDomain(forName: domain)
            for window in NSApp.windows { window.orderOut(nil) }
        }
        defaults.set("iso8601", forKey: "dateFormat")
        defaults.set(true, forKey: "includeTime")
        defaults.set(false, forKey: "updateDaily")
        defaults.set(false, forKey: "randomizeFormat")
        let disabled = CommandLine.arguments.contains("--disabled")
        defaults.set(!disabled, forKey: "shareUsageStatistics")
        unsetenv("POSTHOG_PROJECT_TOKEN")
        unsetenv("POSTHOG_HOST")
        unsetenv("ON_SCREEN_ANALYTICS_TEST_MODE")
        unsetenv("ON_SCREEN_ANALYTICS_INTERNAL")
        try checkContext()
        try check(AnalyticsContext.current.environment == "test" && AnalyticsContext.current.isInternal,
                  "Harness must bundle test/internal provenance before either SDK starts")
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [AnalyticsCaptureProtocol.self]
        let postHogToken = "phc_on_screen_analytics_checks_" + UUID().uuidString
        let postHogConfig = PostHogConfiguration.makeConfig(
            projectToken: postHogToken, host: "https://posthog.analytics.invalid",
            defaults: defaults, sessionConfiguration: session
        )
        try check(postHogConfig.optOut == disabled, "PostHog consent must be configured before setup")
        try check(postHogConfig.personProfiles == .never, "PostHog must not create person profiles")
        try check(!postHogConfig.captureApplicationLifecycleEvents && !postHogConfig.captureScreenViews && !postHogConfig.enableSwizzling,
                  "PostHog automatic lifecycle/screen capture must be disabled")
        try check(!postHogConfig.errorTrackingConfig.autoCapture && !postHogConfig.errorTrackingConfig.exceptionSteps.enabled,
                  "PostHog must not capture raw native errors or breadcrumbs")
        try check(!postHogConfig.preloadFeatureFlags && !postHogConfig.sendFeatureFlagEvent,
                  "PostHog must not request unused feature flags")
        postHogConfig.compression = .none
        postHogConfig.flushAt = 100
        postHogConfig.flushIntervalSeconds = 60
        let postHog = PostHogSDK.with(postHogConfig)
        defer {
            postHog.close()
            let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(domain).appendingPathComponent(postHogToken)
            try? FileManager.default.removeItem(at: storage)
        }
        var expectedActions: [CapturedAction] = []
        var expectedPostHogEvents = 0
        var expectedPostHogLogs = 0
        let analytics = AppAnalytics(defaults: defaults, postHogCapture: {
            expectedActions.append(CapturedAction(event: $0, properties: $1))
            expectedPostHogEvents += 1
            postHog.capture($0, properties: $1)
        })
        let delegate = DesktopAppDelegate(analytics: analytics)
        let display = AppAnalytics.DisplayState(dateFormat: .iso8601, includeTime: true, updateDaily: false, randomizeFormat: false, isCustomText: false)
        let preferences = AppAnalytics.Preferences(loginStatus: .requiresApproval, automaticUpdateChecks: true, automaticUpdates: false)
        analytics.recordLaunch(preferences: preferences, display: display)
        analytics.recordRunningDaily(preferences: preferences, display: display, reason: "launch")
        analytics.recordRunningDaily(preferences: preferences, display: display, reason: "PRIVATE SENTINEL")
        let beforeUnchangedState = expectedActions.count
        for setting in [AppAnalytics.DisplaySetting.dateFormat, .includeTime, .updateDaily, .randomizeFormat] {
            analytics.recordDisplaySettingChanged(setting, previous: display, display: display)
        }
        try check(expectedActions.count == beforeUnchangedState, "Unchanged display state generated a setting event")

        func action(_ name: String, _ sender: Any? = nil) {
            delegate.perform(NSSelectorFromString(name), with: sender)
        }
        func format(_ value: DateDisplayFormat) {
            let item = NSMenuItem()
            item.representedObject = value.rawValue
            action("selectDateFormat:", item)
        }
        func count(_ type: String) -> Int { events(type).count }
        func payloads(_ type: String) -> [[String: String]] {
            events(type).compactMap { $0["properties"] as? [String: Any] }
                .map { $0.compactMapValues { $0 as? String } }
        }
        func only(_ type: String, matching fields: [String: String] = [:]) throws -> [String: String] {
            let matching = payloads(type).filter { payload in fields.allSatisfy { payload[$0.key] == $0.value } }
            guard matching.count == 1, let payload = matching.first else {
                throw CheckFailure(message: "Expected one \(type) matching \(fields), found \(matching.count)")
            }
            return payload
        }
        func flush() async throws {
            postHog.flush()
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            var nextFlush = clock.now + .milliseconds(100)
            var readySince: ContinuousClock.Instant?
            var counts = (postHog: 0, logs: 0)
            while clock.now < deadline {
                if clock.now >= nextFlush {
                    postHog.flush()
                    nextFlush = clock.now + .milliseconds(100)
                }
                let capture = AnalyticsCaptureProtocol.snapshot()
                let resources = capture.postHogLogs.flatMap { $0["resourceLogs"] as? [[String: Any]] ?? [] }
                let logs = resources.flatMap { $0["scopeLogs"] as? [[String: Any]] ?? [] }
                    .flatMap { $0["logRecords"] as? [[String: Any]] ?? [] }
                counts = (capture.postHogEvents.count, logs.count)
                if counts.postHog == expectedPostHogEvents && counts.logs == expectedPostHogLogs {
                    if let readySince, clock.now - readySince >= .milliseconds(100) { return }
                    if readySince == nil { readySince = clock.now }
                } else {
                    readySince = nil
                }
                try check(counts.postHog <= expectedPostHogEvents && counts.logs <= expectedPostHogLogs,
                          "Unexpected SDK records: \(counts), expected \(expectedPostHogEvents)/\(expectedPostHogLogs)")
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CheckFailure(message: "SDK delivery timed out: \(counts), expected \(expectedPostHogEvents)/\(expectedPostHogLogs)")
        }

        format(.romanCountdown)
        action("toggleIncludeTime")
        action("toggleUpdateDaily:", NSMenuItem())
        action("toggleRandomizeFormat")
        // Make the following manual selection a real change even if randomization
        // happened to choose Kawara. The separate no-op check below remains explicit.
        let initialRandomizationChoseKawara = defaults.string(forKey: "dateFormat") == DateDisplayFormat.kawara.rawValue
        if initialRandomizationChoseKawara { format(.romanCountdown) }
        format(.kawara) // Manual selection must preserve randomization.
        try check(defaults.bool(forKey: "randomizeFormat"), "Manual format selection disabled randomization")
        action("toggleRandomizeFormat")
        action("didWake")
        action("clockChanged")

        // Fire the actual delegate's midnight timer, exercising its real callback.
        let scheduler = Mirror(reflecting: delegate).children.compactMap { $0.value as? DailyUpdateScheduler }.first
        try check(scheduler?.timer != nil, "Daily updates were not scheduled")
        scheduler?.timer?.fire()
        action("resetTimestamp")
        try await flush()

        if !disabled {
            // Match the exact expected actions without relying on batch order.
            let selectedFormats = payloads("display_setting_changed:dateFormat")
            let expectedFormats = [DateDisplayFormat.romanCountdown.rawValue, DateDisplayFormat.kawara.rawValue] +
                (initialRandomizationChoseKawara ? [DateDisplayFormat.romanCountdown.rawValue] : [])
            try check(selectedFormats.compactMap { $0["dateFormat"] }.sorted() == expectedFormats.sorted(), "Selected formats missing")
            try check(try only("display_setting_changed:includeTime")["includeTime"] == "false", "Include Time missing")
            try check(try only("display_setting_changed:updateDaily")["dailyUpdatesActive"] == "true", "Daily update toggle missing")
            try check(try only("display_setting_changed:includeTime")["previousValue"] == "true" &&
                      only("display_setting_changed:includeTime")["value"] == "false", "Include Time before/after values incorrect")
            try check(try only("display_setting_changed:updateDaily")["previousValue"] == "false" &&
                      only("display_setting_changed:updateDaily")["value"] == "true", "Daily Updates before/after values incorrect")
            try check(count("display_setting_changed:randomizeFormat") == 2, "Both randomization toggle directions must be recorded")
            try check(count("app_woke") == 1 && count("timestamp_refreshed") == 3, "Wake, clock, midnight, or reset event count incorrect")
            let reasons = Set(payloads("timestamp_refreshed").compactMap { $0["reason"] })
            try check(reasons == ["clock/time-zone-changed", "midnight", "reset"], "Refresh reasons incorrect")
        }

        action("toggleRandomizeFormat")
        format(.kawara)
        scheduler?.timer?.fire()
        try await flush()
        if !disabled {
            let randomized = try only("timestamp_refreshed", matching: ["reason": "midnight", "randomized": "true"])
            try check(randomized["reason"] == "midnight" && randomized["randomized"] == "true", "Automatic randomization was not distinguished")
            try check(randomized["previousDateFormat"] == "kawara" && randomized["dateFormat"] != "kawara", "Randomized format metadata incorrect")
            let selection = try only("date_format_randomized", matching: ["reason": "midnight"])
            try check(selection["reason"] == "midnight" && selection["dateFormat"] != "kawara", "Random selection event missing")
        }
        action("toggleRandomizeFormat")
        format(.kawara)
        action("willSleep")
        try check(scheduler?.timer == nil, "Sleep did not cancel the daily timer")
        action("didWake")
        try check(scheduler?.timer != nil, "Wake did not restore the daily timer")
        try await flush()

        let beforeNoop = count("display_setting_changed:dateFormat")
        format(.kawara)
        try await flush()
        try check(count("display_setting_changed:dateFormat") == beforeNoop, "No-op selection produced an event")
        format(.unixTimestamp)
        action("toggleIncludeTime") // Disabled for formats that inherently include time.
        try await flush()
        if !disabled {
            try check(try only("display_setting_changed:dateFormat", matching: ["dateFormat": DateDisplayFormat.unixTimestamp.rawValue])["timeIncluded"] == "true", "Inherent time not reported")
            try check(count("display_setting_changed:includeTime") == 1, "Disabled Include Time toggle produced an event")
        }

        // Confirm custom text through the real modal path, without recording its value.
        let privateText = "PRIVATE SENTINEL"
        let confirmText = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow, let view = window.contentView else { return }
                let field = descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable }
                field?.stringValue = privateText
                descendants(view).compactMap { $0 as? NSButton }.first { $0.title == "Set Text" }?.performClick(nil)
            }
        }
        RunLoop.main.add(confirmText, forMode: .common)
        action("showCustomText")
        try check(defaults.string(forKey: "customText") == privateText, "Custom text modal path failed")
        try check(scheduler?.timer == nil, "Custom text must pause daily updates")
        let beforeCustomWake = count("app_woke")
        let beforeHiddenRefresh = count("timestamp_refreshed")
        action("didWake")
        action("clockChanged")
        action("toggleUpdateDaily:", NSMenuItem())
        try await flush()
        try check(defaults.bool(forKey: "updateDaily"), "Disabled daily-update toggle changed the saved setting")
        if !disabled {
            try check(count("app_woke") == beforeCustomWake + 1, "Wake with custom text missing")
            try check(count("timestamp_refreshed") == beforeHiddenRefresh, "Hidden timestamp refresh was reported")
            let custom = try only("custom_text_changed")
            try check(custom["mode"] == "custom" && custom["dailyUpdatesActive"] == "false", "Custom text state incorrect")
            let wake = try only("app_woke", matching: ["mode": "custom"])
            try check(wake["openAtLoginStatus"] != nil && wake["automaticUpdateChecks"] != nil && wake["automaticUpdates"] != nil, "Wake preference snapshot incomplete")
        }
        action("resetTimestamp")
        try check(defaults.string(forKey: "customText") == nil && scheduler?.timer != nil, "Reset did not resume daily updates")
        action("toggleUpdateDaily:", NSMenuItem())
        try await flush()
        try check(scheduler?.timer == nil, "Disabling daily updates did not cancel the timer")
        if !disabled {
            _ = try only("display_setting_changed:updateDaily", matching: ["dailyUpdatesActive": "false"])
        }

        // Open the stock About panel and exercise its actual link delegate twice.
        action("showAbout")
        guard let credits = NSApp.windows.compactMap(\.contentView).flatMap({ descendants($0) })
            .compactMap({ $0 as? NSTextView }).first(where: { $0.delegate is AboutWebsiteLinkTracker }) else {
            throw CheckFailure(message: "Website tracker did not attach to the native About panel")
        }
        let websiteDelegate = WebsiteDelegateCheck()
        credits.delegate = websiteDelegate
        action("showAbout")
        let tracker = credits.delegate
        let website = URL(string: "https://onscreen.ericprice.info")!
        credits.clicked(onLink: website, at: 0)
        action("showAbout")
        credits.clicked(onLink: website.absoluteString, at: 0)
        credits.clicked(onLink: URL(string: "https://example.invalid")!, at: 0)
        try check(websiteDelegate.clicks == 3, "Original link handling was not preserved")
        try check(tracker?.textShouldBeginEditing?(credits) == false, "Original delegate callbacks were not forwarded")
        analytics.recordUpdatesChecked()
        analytics.recordColorChanged(color: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1), mode: .custom)
        let changed = AppAnalytics.Preferences(loginStatus: .enabled, automaticUpdateChecks: false, automaticUpdates: true)
        analytics.recordPreferencesChanged(changed)
        analytics.recordPreferencesChanged(changed)
        let reversed = AppAnalytics.Preferences(loginStatus: .disabled, automaticUpdateChecks: true, automaticUpdates: false)
        analytics.recordPreferencesChanged(reversed)
        analytics.recordPreferencesChanged(reversed)

        let errorDetails: [String: Any] = [NSLocalizedDescriptionKey: privateText, "path": "/private/\(privateText)"]
        let loginCases: [(Int, String)] = [
            (kSMErrorInvalidSignature, "signature"), (kSMErrorAuthorizationFailure, "permission"),
            (kSMErrorToolNotValid, "notFound"), (kSMErrorServiceUnavailable, "unavailable"),
            (kSMErrorInvalidPlist, "configuration"), (kSMErrorInternalFailure, "internal"), (999, "other")
        ]
        for (code, _) in loginCases {
            analytics.recordLoginFailure(NSError(domain: SMAppServiceErrorDomain, code: code, userInfo: errorDetails), operation: .automaticRegistration)
        }
        analytics.recordLoginFailure(NSError(domain: SMAppServiceErrorDomain, code: kSMErrorAuthorizationFailure, userInfo: errorDetails), operation: .disable)
        analytics.recordLoginFailure(NSError(domain: SMAppServiceErrorDomain, code: kSMErrorAlreadyRegistered), operation: .enable)
        analytics.recordLoginFailure(NSError(domain: SMAppServiceErrorDomain, code: kSMErrorJobNotFound), operation: .disable)
        guard let updater = Mirror(reflecting: delegate).children.compactMap({ $0.value as? SPUStandardUpdaterController }).first?.updater else {
            throw CheckFailure(message: "Updater not initialized")
        }
        var expectedUpdateOutcomes: [String] = []
        let availableItem = SUAppcastItem(dictionary: [
            "title": "Analytics check update",
            "enclosure": ["url": "https://example.invalid/update.zip", "sparkle:version": "999"]
        ])
        try check(availableItem != nil, "Unable to construct isolated Sparkle update metadata")
        func complete(_ source: SPUUpdateCheck, error: Error?, outcome: AppAnalytics.UpdateOutcome,
                      foundUpdate: Bool = false, cancelled: Bool = false) throws {
            try delegate.updater(updater, mayPerform: source)
            if foundUpdate { delegate.updater(updater, didFindValidUpdate: availableItem!) }
            if cancelled { delegate.userDidCancelDownload(updater) }
            delegate.updater(updater, didFinishUpdateCycleFor: source, error: error)
            // A duplicate terminal callback must not create another completion or failure.
            delegate.updater(updater, didFinishUpdateCycleFor: source, error: error)
            let sourceName: String
            switch source {
            case .updates: sourceName = "manual"
            case .updatesInBackground: sourceName = "automatic"
            case .updateInformation: sourceName = "information"
            @unknown default: sourceName = "unknown"
            }
            expectedUpdateOutcomes.append(sourceName + ":" + outcome.rawValue)
        }
        let updateCases: [(String, Int, String)] = [
            (NSURLErrorDomain, NSURLErrorNotConnectedToInternet, "network"),
            (SUSparkleErrorDomain, Int(SUError.appcastParseError.rawValue), "feed"),
            (SUSparkleErrorDomain, Int(SUError.downloadError.rawValue), "download"),
            (SUSparkleErrorDomain, Int(SUError.signatureError.rawValue), "signature"),
            (SUSparkleErrorDomain, Int(SUError.invalidFeedURLError.rawValue), "configuration"),
            (SUSparkleErrorDomain, Int(SUError.installationError.rawValue), "installation"),
            ("private.error.domain", 123, "other")
        ]
        for (domain, code, _) in updateCases {
            try complete(.updatesInBackground, error: NSError(domain: domain, code: code, userInfo: errorDetails), outcome: .failed)
        }
        try complete(.updates, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: errorDetails), outcome: .failed)
        try complete(.updates, error: nil, outcome: .unknown)
        for (normal, outcome) in [(SUError.noUpdateError, AppAnalytics.UpdateOutcome.unknown), (.installationCanceledError, .cancelled), (.installationAuthorizeLaterError, .unknown)] {
            try complete(.updates, error: NSError(domain: SUSparkleErrorDomain, code: Int(normal.rawValue), userInfo: errorDetails), outcome: outcome)
        }
        let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: errorDetails)
        try complete(.updates, error: cancellation, outcome: .cancelled)
        try complete(.updates, error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue), userInfo: [NSUnderlyingErrorKey: cancellation]), outcome: .cancelled)
        for reason in [SPUNoUpdateFoundReason.onLatestVersion, .onNewerThanLatestVersion, .systemIsTooOld] {
            let outcome: AppAnalytics.UpdateOutcome = reason == .systemIsTooOld ? .unknown : .upToDate
            try complete(.updates, error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                                                  userInfo: [SPUNoUpdateFoundReasonKey: reason.rawValue]), outcome: outcome)
        }
        try complete(.updates, error: nil, outcome: .updateAvailable, foundUpdate: true)
        try complete(.updates, error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationAuthorizeLaterError.rawValue)),
                     outcome: .updateAvailable, foundUpdate: true)
        try complete(.updates, error: nil, outcome: .cancelled, foundUpdate: true, cancelled: true)
        try complete(.updateInformation, error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                                                        userInfo: [SPUNoUpdateFoundReasonKey: SPUNoUpdateFoundReason.onLatestVersion.rawValue]), outcome: .upToDate)
        let hiddenDisplay = AppAnalytics.DisplayState(dateFormat: display.dateFormat, includeTime: display.includeTime,
                                                     updateDaily: display.updateDaily, randomizeFormat: display.randomizeFormat, isCustomText: true)
        analytics.recordDisplaySettingChanged(.dateFormat, previous: hiddenDisplay, display: display)
        try await flush()
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        let capture = AnalyticsCaptureProtocol.snapshot()
        if disabled {
            postHog.capture("about_opened") // Exercise the SDK's own startup opt-out, too.
            postHog.captureLog("PRIVATE SENTINEL")
            try await flush()
            let disabledCapture = AnalyticsCaptureProtocol.snapshot()
            try check(disabledCapture.postHogEvents.isEmpty && disabledCapture.requests.isEmpty,
                      "Opt-out must make zero requests for every action")
            defaults.set(true, forKey: "shareUsageStatistics")
            postHog.optIn()
            analytics.recordAboutOpened()
            try await flush()
            let resumed = AnalyticsCaptureProtocol.snapshot()
            try check(resumed.postHogEvents.count == 1 && count("about_opened") == 1,
                      "Enabling analytics after opted-out startup did not resume SDK capture exactly once")
            defaults.set(false, forKey: "shareUsageStatistics")
            postHog.optOut()
            return "PASS: all native actions and direct PostHog capture made zero startup-opt-out requests; later opt-in delivered exactly one action.\n"
        }
        try check(count("about_opened") == 3 && count("website_clicked") == 2, "About or website counts incorrect")
        let presence = try only("app_running_daily")
        try check(presence["reason"] == "launch" && presence["mode"] == "timestamp" &&
                  presence["openAtLoginStatus"] == "requiresApproval", "Daily presence snapshot missing or accepted an unbounded reason")
        try check(count("updates_checked") == 1 && count("preferences_changed") == 6, "Updater settings or deduplication incorrect")
        for name in ["openAtLogin", "automaticUpdateChecks", "automaticUpdates"] {
            let values = payloads("preferences_changed").filter { $0["changedPreference"] == name }
            try check(values.count == 2 && Set(values.compactMap { $0["value"] }) == ["true", "false"], "Changed preference or resulting value missing")
            try check(values.allSatisfy { $0["previousValue"] != $0["value"] }, "Previous preference value incorrect")
        }
        try check(count("open_at_login_failed") == loginCases.count + 1, "Expected-state login errors were counted as failures")
        try check(Set(payloads("open_at_login_failed").compactMap { $0["category"] }) == Set(loginCases.map(\.1)), "Login failure categories incorrect")
        try check(count("update_check_failed") == updateCases.count + 1, "Normal updater results were counted as failures")
        try check(Set(payloads("update_check_failed").compactMap { $0["category"] }) == Set(updateCases.map(\.2)), "Update failure categories incorrect")
        let actualUpdateSources = payloads("update_check_failed").map { ($0["source"] ?? "missing") + ":" + ($0["category"] ?? "missing") }.sorted()
        let expectedUpdateSources = (updateCases.map { "automatic:" + $0.2 } + ["manual:network"]).sorted()
        try check(actualUpdateSources == expectedUpdateSources, "Update check source/category pairs incorrect: \(actualUpdateSources)")
        let actualUpdateOutcomes = payloads("update_check_completed").map { ($0["source"] ?? "missing") + ":" + ($0["outcome"] ?? "missing") }.sorted()
        try check(actualUpdateOutcomes == expectedUpdateOutcomes.sorted(), "Update completion outcomes/source pairs or deduplication incorrect: \(actualUpdateOutcomes)")
        for (event, field) in [("display_setting_changed:dateFormat", "dateFormat"), ("display_setting_changed:includeTime", "includeTime"),
                               ("display_setting_changed:updateDaily", "updateDaily"), ("display_setting_changed:randomizeFormat", "randomizeFormat")] {
            for payload in payloads(event) {
                try check(payload["previousValue"] != nil && payload["value"] == payload[field], "Display-setting before/after value missing")
                try check(payload["previousValue"] != payload["value"] || payload["previousMode"] != payload["mode"],
                          "Unchanged setting and display mode emitted a change event")
            }
        }
        _ = try only("display_setting_changed:dateFormat", matching: ["previousMode": "custom", "mode": "timestamp", "previousValue": display.dateFormat.rawValue, "value": display.dateFormat.rawValue])
        try check(try only("text_color_changed")["color"] == "#FF8000", "Color tracking regressed")
        try check(capture.requests.allSatisfy { request in
            guard let url = URL(string: request), url.host == "posthog.analytics.invalid" else { return false }
            return url.path == "/batch" || url.path == "/array/\(postHogToken)/config"
        }, "Unexpected analytics endpoint or unused PostHog request: \(capture.requests)")
        try checkPostHog(capture.postHogEvents, expectedActions: expectedActions, privateText: privateText)

        let logCases = ["desktop_app_ready": "desktop app ready", "update_check_requested": "manual update check requested",
                        "update_check_failed": "update check failed"]
        expectedPostHogLogs += logCases.count
        for (event, message) in logCases {
            postHog.captureLog(message, attributes: ["event": event, "source": "manual", "text": privateText])
        }
        postHog.captureLog(privateText, attributes: ["event": "update_check_failed"])
        postHog.captureLog("unapproved log")
        try await flush()
        let logCapture = AnalyticsCaptureProtocol.snapshot()
        let resources = logCapture.postHogLogs.flatMap { $0["resourceLogs"] as? [[String: Any]] ?? [] }
        let logRecords = resources.flatMap { $0["scopeLogs"] as? [[String: Any]] ?? [] }
            .flatMap { $0["logRecords"] as? [[String: Any]] ?? [] }
        try check(logRecords.count == logCases.count, "PostHog log allowlist accepted an unknown message or dropped an approved log")
        try check(Set(logRecords.compactMap { ($0["body"] as? [String: Any])?["stringValue"] as? String }) == Set(logCases.values),
                  "PostHog operational log messages changed")
        for record in logRecords {
            let attributes = record["attributes"] as? [[String: Any]] ?? []
            for (key, value) in AnalyticsContext.current.properties {
                let actual = attributes.first { $0["key"] as? String == key }?["value"] as? [String: Any]
                try check(actual?["stringValue"] as? String == value, "PostHog log provenance missing or incorrect: " + key)
            }
        }
        let logEncoded = String(decoding: try JSONSerialization.data(withJSONObject: logCapture.postHogLogs), as: UTF8.self)
        try check(logEncoded.contains("on-screen-macos") && !logEncoded.contains(privateText) &&
                  !logEncoded.contains("posthogDistinctId") && !logEncoded.contains("sessionId"),
                  "PostHog logs lost service context or included private text/identifiers")

        // Guard against future accidental raw capture outside the typed app boundary.
        let beforePrivacyCheck = capture.postHogEvents.count
        postHog.capture("unapproved_event", properties: ["text": privateText])
        postHog.capture("$screen", properties: ["$screen_name": privateText])
        postHog.capture("$exception", properties: ["$exception_message": privateText])
        expectedPostHogEvents += 1
        postHog.capture("about_opened", properties: ["text": privateText, "path": "/private/" + privateText,
                                                    "analytics_environment": "production", "is_internal": "false", "app_version": "999"])
        try await flush()
        let privacyCapture = AnalyticsCaptureProtocol.snapshot()
        try check(privacyCapture.postHogEvents.count == beforePrivacyCheck + 1, "PostHog accepted an event outside the approved plan")
        let privacyEncoded = String(decoding: try JSONSerialization.data(withJSONObject: privacyCapture.postHogEvents), as: UTF8.self)
        try check(!privacyEncoded.contains(privateText) && !privacyEncoded.contains("/private/"), "PostHog leaked unknown text or file paths")
        for (key, value) in AnalyticsContext.current.properties {
            try check((privacyCapture.postHogEvents.last?["properties"] as? [String: Any])?[key] as? String == value,
                      "PostHog accepted spoofed analytics context: " + key)
        }

        postHog.optOut()
        let beforeOptOut = AnalyticsCaptureProtocol.snapshot()
        postHog.capture("about_opened")
        postHog.captureLog(privateText)
        try await flush()
        let afterOptOut = AnalyticsCaptureProtocol.snapshot()
        try check(afterOptOut.postHogEvents.count == beforeOptOut.postHogEvents.count && afterOptOut.requests.count == beforeOptOut.requests.count,
                  "PostHog runtime opt-out still transmitted analytics")
        postHog.optIn()
        expectedPostHogEvents += 1
        postHog.capture("about_opened")
        try await flush()
        try check(AnalyticsCaptureProtocol.snapshot().postHogEvents.count == beforeOptOut.postHogEvents.count + 1,
                  "PostHog runtime opt-in did not resume capture")
        // Queue while allowed, then revoke the app preference before upload. SDK optOut()
        // alone does not stop an existing queue, so the app transport must also enforce consent.
        postHog.capture("about_opened")
        defaults.set(false, forKey: "shareUsageStatistics")
        let beforeBlockedFlush = AnalyticsCaptureProtocol.snapshot()
        try await flush()
        let afterBlockedFlush = AnalyticsCaptureProtocol.snapshot()
        try check(afterBlockedFlush.requests.count == beforeBlockedFlush.requests.count &&
                  afterBlockedFlush.postHogEvents.count == beforeBlockedFlush.postHogEvents.count,
                  "PostHog transmitted a queued upload after the app preference opted out")
        defaults.set(true, forKey: "shareUsageStatistics")
        expectedPostHogEvents += 1
        try await flush()
        try check(AnalyticsCaptureProtocol.snapshot().postHogEvents.count == afterBlockedFlush.postHogEvents.count + 1,
                  "PostHog did not resume the blocked queued event after opt-in")
        defaults.set(false, forKey: "shareUsageStatistics")
        postHog.optOut()
        return "PASS: real SDK transport; exact native action payloads, display before/after values, update completion outcomes/deduplication, daily presence, authoritative provenance, privacy filters, operational logs, opt-out including queued uploads, and no automatic capture/feature-flag traffic.\n"
    }

    private static func checkPostHog(_ postHogEvents: [[String: Any]], expectedActions: [CapturedAction], privateText: String) throws {
        let expectedNames: Set<String> = ["app_launched", "app_running_daily", "app_woke", "timestamp_refreshed", "custom_text_changed",
            "display_setting_changed", "date_format_randomized", "about_opened", "website_clicked", "updates_checked", "update_check_completed",
            "text_color_changed", "preferences_changed", "open_at_login_failed", "update_check_failed"]
        try check(Set(postHogEvents.compactMap { $0["event"] as? String }) == expectedNames, "A native event type was missing or unapproved")
        let appKeys = Set(["dateFormat", "includeTime", "timeIncluded", "updateDaily", "dailyUpdatesActive", "randomizeFormat", "mode",
                           "reason", "previousDateFormat", "randomized", "source", "color", "openAtLogin", "openAtLoginStatus",
                           "automaticUpdateChecks", "automaticUpdates", "changedPreference", "previousValue", "value", "category",
                           "operation", "changedSetting", "previousMode", "outcome", "analytics_environment", "is_internal",
                           "app_version", "app_build", "analytics_schema_version"])
        func canonical(_ properties: [String: String]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: properties, options: .sortedKeys), as: UTF8.self)
        }
        let expectedPayloads = try expectedActions.map { action in
            var properties = action.properties
            properties["event"] = action.event
            return try canonical(properties)
        }.sorted()
        let actualPayloads = try postHogEvents.map { event in
            let sdkProperties = event["properties"] as! [String: Any]
            try check(Set(sdkProperties.keys.filter { !$0.hasPrefix("$") && $0 != "distinct_id" }).isSubset(of: appKeys),
                      "PostHog included an unexpected custom property")
            var properties = sdkProperties.filter { appKeys.contains($0.key) }.compactMapValues { $0 as? String }
            properties["event"] = event["event"] as? String
            return try canonical(properties)
        }.sorted()
        try check(actualPayloads == expectedPayloads, "PostHog lost or changed bounded native-event properties")
        let settings = postHogEvents.filter { $0["event"] as? String == "display_setting_changed" }
        try check(Set(settings.compactMap { ($0["properties"] as? [String: Any])?["changedSetting"] as? String }) ==
                  ["dateFormat", "includeTime", "updateDaily", "randomizeFormat"], "PostHog display setting changes are indistinguishable")
        for event in postHogEvents {
            let properties = event["properties"] as! [String: Any]
            try check(properties["$process_person_profile"] as? Bool == false, "PostHog person profile processing was enabled")
            try check(properties["$geoip_disable"] as? Bool == true, "PostHog GeoIP processing was enabled")
            try check(properties["$is_identified"] as? Bool != true, "PostHog identified a user")
            for (key, value) in AnalyticsContext.current.properties {
                try check(properties[key] as? String == value, "PostHog provenance missing or incorrect: " + key)
            }
            for key in ["$set", "$set_once", "$ip", "$current_url", "$pathname"] {
                try check(properties[key] == nil, "PostHog included private metadata: " + key)
            }
        }
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: postHogEvents), as: UTF8.self)
        try check(!encoded.contains(privateText) && !encoded.contains("private.error.domain"), "PostHog transmitted custom text or raw error details")
    }

    static func checkContext() throws {
        let production = ["ON_SCREEN_ANALYTICS_ENVIRONMENT": "production", "ON_SCREEN_ANALYTICS_INTERNAL": "false"]
        func context(_ bundled: [String: String], _ process: [String: String] = [:], internalTesting: Bool = false) -> AnalyticsContext {
            AnalyticsContext.resolve(bundled: bundled, processEnvironment: process, internalTesting: internalTesting, appVersion: "1.4", appBuild: "14")
        }
        let publicRelease = context(production)
        try check(publicRelease.environment == "production" && !publicRelease.isInternal &&
                  publicRelease.properties["analytics_schema_version"] == "2" && publicRelease.properties["app_build"] == "14",
                  "Production provenance was not resolved from bundled metadata")
        for bundled in [[:], ["ON_SCREEN_ANALYTICS_ENVIRONMENT": "development", "ON_SCREEN_ANALYTICS_INTERNAL": "false"],
                        ["ON_SCREEN_ANALYTICS_ENVIRONMENT": "invalid", "ON_SCREEN_ANALYTICS_INTERNAL": "false"]] {
            let result = context(bundled, ["ON_SCREEN_ANALYTICS_ENVIRONMENT": "production", "ON_SCREEN_ANALYTICS_INTERNAL": "false"])
            try check(result.environment == "development" && result.isInternal, "Runtime environment promoted a local/missing build to public production")
        }
        try check(context(production, internalTesting: true).isInternal, "Internal-testing preference was ignored")
        try check(context(production, ["ON_SCREEN_ANALYTICS_INTERNAL": "true"]).isInternal, "Runtime internal-testing override was ignored")
        let markedInternal = ["ON_SCREEN_ANALYTICS_ENVIRONMENT": "production", "ON_SCREEN_ANALYTICS_INTERNAL": "true"]
        try check(context(markedInternal, ["ON_SCREEN_ANALYTICS_INTERNAL": "false"]).isInternal,
                  "Runtime environment cleared bundled internal provenance")
        let test = context(production, ["ON_SCREEN_ANALYTICS_TEST_MODE": "1"])
        try check(test.environment == "test" && test.isInternal, "Test mode did not mark traffic as test/internal")
    }

    static func events(_ selector: String) -> [[String: Any]] {
        let components = selector.split(separator: ":", maxSplits: 1).map(String.init)
        return AnalyticsCaptureProtocol.snapshot().postHogEvents.filter { event in
            guard event["event"] as? String == components[0] else { return false }
            return components.count == 1 || (event["properties"] as? [String: Any])?["changedSetting"] as? String == components[1]
        }
    }

    @MainActor
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }
}
