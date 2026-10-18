import AppKit
import Foundation
import ServiceManagement
import Sparkle

// Intercept the real SDK's transport: no test events can reach TelemetryDeck.
final class AnalyticsCaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var events: [[String: Any]] = []
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
        if let batch = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            Self.events.append(contentsOf: batch)
        }
        Self.requests.append(request.url!.absoluteString)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func snapshot() -> (events: [[String: Any]], requests: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (events, requests)
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
        setenv("ON_SCREEN_ANALYTICS_TEST_MODE", "1", 1)
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [AnalyticsCaptureProtocol.self]
        let analytics = AppAnalytics(defaults: defaults, sessionConfiguration: session, transmitInterval: 0.02)
        analytics.start()
        let delegate = DesktopAppDelegate(analytics: analytics)
        let display = AppAnalytics.DisplayState(dateFormat: .iso8601, includeTime: true, updateDaily: false, randomizeFormat: false, isCustomText: false)
        let preferences = AppAnalytics.Preferences(loginStatus: .requiresApproval, automaticUpdateChecks: true, automaticUpdates: false)
        analytics.recordLaunch(preferences: preferences, display: display)

        func action(_ name: String, _ sender: Any? = nil) {
            delegate.perform(NSSelectorFromString(name), with: sender)
        }
        func format(_ value: DateDisplayFormat) {
            let item = NSMenuItem()
            item.representedObject = value.rawValue
            action("selectDateFormat:", item)
        }
        func count(_ type: String) -> Int { events(type).count }
        func last(_ type: String) throws -> [String: String] {
            guard let event = events(type).last, let payload = event["payload"] as? [String: String] else {
                throw CheckFailure(message: "Missing \(type)")
            }
            return payload.filter { $0.key.hasPrefix("OnScreen.") }
        }
        func flush() async throws { try await Task.sleep(for: .milliseconds(180)) }

        format(.romanCountdown)
        action("toggleIncludeTime")
        action("toggleUpdateDaily:", NSMenuItem())
        action("toggleRandomizeFormat")
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
            try check(try last("DateFormat.changed")["OnScreen.dateFormat"] == "kawara", "Selected format missing")
            try check(try last("IncludeTime.changed")["OnScreen.includeTime"] == "false", "Include Time missing")
            try check(try last("DailyUpdates.changed")["OnScreen.dailyUpdatesActive"] == "true", "Daily update toggle missing")
            try check(count("Randomization.changed") == 2, "Both randomization toggle directions must be recorded")
            try check(count("App.woke") == 1 && count("Timestamp.refreshed") == 3, "Wake, clock, midnight, or reset event count incorrect")
            let reasons = Set(events("Timestamp.refreshed").compactMap { ($0["payload"] as? [String: String])?["OnScreen.reason"] })
            try check(reasons == ["clock/time-zone-changed", "midnight", "reset"], "Refresh reasons incorrect")
        }

        action("toggleRandomizeFormat")
        format(.kawara)
        scheduler?.timer?.fire()
        try await flush()
        if !disabled {
            let randomized = try last("Timestamp.refreshed")
            try check(randomized["OnScreen.reason"] == "midnight" && randomized["OnScreen.randomized"] == "true", "Automatic randomization was not distinguished")
            try check(randomized["OnScreen.previousDateFormat"] == "kawara" && randomized["OnScreen.dateFormat"] != "kawara", "Randomized format metadata incorrect")
            let selection = try last("DateFormat.randomized")
            try check(selection["OnScreen.reason"] == "midnight" && selection["OnScreen.dateFormat"] != "kawara", "Random selection event missing")
        }
        action("toggleRandomizeFormat")
        format(.kawara)
        action("willSleep")
        try check(scheduler?.timer == nil, "Sleep did not cancel the daily timer")
        action("didWake")
        try check(scheduler?.timer != nil, "Wake did not restore the daily timer")
        try await flush()

        let beforeNoop = count("DateFormat.changed")
        format(.kawara)
        try await flush()
        try check(count("DateFormat.changed") == beforeNoop, "No-op selection produced an event")
        format(.unixTimestamp)
        action("toggleIncludeTime") // Disabled for formats that inherently include time.
        try await flush()
        if !disabled {
            try check(try last("DateFormat.changed")["OnScreen.timeIncluded"] == "true", "Inherent time not reported")
            try check(count("IncludeTime.changed") == 1, "Disabled Include Time toggle produced an event")
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
        let beforeCustomWake = count("App.woke")
        let beforeHiddenRefresh = count("Timestamp.refreshed")
        action("didWake")
        action("clockChanged")
        action("toggleUpdateDaily:", NSMenuItem())
        try await flush()
        try check(defaults.bool(forKey: "updateDaily"), "Disabled daily-update toggle changed the saved setting")
        if !disabled {
            try check(count("App.woke") == beforeCustomWake + 1, "Wake with custom text missing")
            try check(count("Timestamp.refreshed") == beforeHiddenRefresh, "Hidden timestamp refresh was reported")
            let custom = try last("Text.changed")
            try check(custom["OnScreen.mode"] == "custom" && custom["OnScreen.dailyUpdatesActive"] == "false", "Custom text state incorrect")
            try check(try last("App.woke")["OnScreen.mode"] == "custom", "Wake lost custom-text state")
            let wake = try last("App.woke")
            try check(wake["OnScreen.openAtLoginStatus"] != nil && wake["OnScreen.automaticUpdateChecks"] != nil && wake["OnScreen.automaticUpdates"] != nil, "Wake preference snapshot incomplete")
        }
        action("resetTimestamp")
        try check(defaults.string(forKey: "customText") == nil && scheduler?.timer != nil, "Reset did not resume daily updates")
        action("toggleUpdateDaily:", NSMenuItem())
        try await flush()
        try check(scheduler?.timer == nil, "Disabling daily updates did not cancel the timer")
        if !disabled {
            try check(try last("DailyUpdates.changed")["OnScreen.dailyUpdatesActive"] == "false", "Disabling daily updates was not reported")
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
            delegate.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: NSError(domain: domain, code: code, userInfo: errorDetails))
        }
        delegate.updater(updater, didFinishUpdateCycleFor: .updates, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: errorDetails))
        delegate.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
        for normal in [SUError.noUpdateError, .installationCanceledError, .installationAuthorizeLaterError] {
            delegate.updater(updater, didFinishUpdateCycleFor: .updates, error: NSError(domain: SUSparkleErrorDomain, code: Int(normal.rawValue), userInfo: errorDetails))
        }
        let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: errorDetails)
        delegate.updater(updater, didFinishUpdateCycleFor: .updates, error: cancellation)
        delegate.updater(updater, didFinishUpdateCycleFor: .updates, error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue), userInfo: [NSUnderlyingErrorKey: cancellation]))
        try await flush()
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        let capture = AnalyticsCaptureProtocol.snapshot()
        if disabled {
            try check(capture.events.isEmpty && capture.requests.isEmpty, "Opt-out must make zero requests for every action")
            return "PASS: all actions exercised with hidden opt-out; zero SDK requests.\n"
        }
        try check(count("About.opened") == 3 && count("Website.clicked") == 2, "About or website counts incorrect")
        try check(count("Updates.checked") == 1 && count("Preferences.changed") == 6, "Updater settings or deduplication incorrect")
        for name in ["openAtLogin", "automaticUpdateChecks", "automaticUpdates"] {
            let values = events("Preferences.changed").compactMap { $0["payload"] as? [String: String] }
                .filter { $0["OnScreen.changedPreference"] == name }
            try check(values.count == 2 && Set(values.compactMap { $0["OnScreen.value"] }) == ["true", "false"], "Changed preference or resulting value missing")
            try check(values.allSatisfy { $0["OnScreen.previousValue"] != $0["OnScreen.value"] }, "Previous preference value incorrect")
        }
        try check(count("OpenAtLogin.failed") == loginCases.count + 1, "Expected-state login errors were counted as failures")
        try check(Set(events("OpenAtLogin.failed").compactMap { ($0["payload"] as? [String: String])?["OnScreen.category"] }) == Set(loginCases.map(\.1)), "Login failure categories incorrect")
        try check(count("Updates.failed") == updateCases.count + 1, "Normal updater results were counted as failures")
        try check(Set(events("Updates.failed").compactMap { ($0["payload"] as? [String: String])?["OnScreen.category"] }) == Set(updateCases.map(\.2)), "Update failure categories incorrect")
        try check(try last("Updates.failed")["OnScreen.source"] == "manual", "Update check source missing")
        try check(try last("Color.changed")["OnScreen.color"] == "#FF8000", "Color tracking regressed")
        try check(capture.requests.allSatisfy { $0 == "https://nom.telemetrydeck.com/v2/namespace/info.ericprice/" }, "Namespace endpoint incorrect")
        try check(capture.events.allSatisfy { $0["appID"] as? String == "56092A55-E45A-41D9-A104-36566909C5BD" && $0["isTestMode"] as? String == "true" }, "App ID or test mode incorrect")
        let allowed = Set(["dateFormat", "includeTime", "timeIncluded", "updateDaily", "dailyUpdatesActive", "randomizeFormat", "mode", "reason", "previousDateFormat", "randomized", "source", "color", "openAtLogin", "openAtLoginStatus", "automaticUpdateChecks", "automaticUpdates", "changedPreference", "previousValue", "value", "category", "operation"].map { "OnScreen." + $0 })
        for event in capture.events {
            let payload = event["payload"] as! [String: String]
            try check(Set(payload.keys.filter { $0.hasPrefix("OnScreen.") }).isSubset(of: allowed), "Unexpected custom payload field")
        }
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: capture.events), as: UTF8.self)
        try check(!encoded.contains(privateText) && !encoded.contains("App.active") && !encoded.contains("sessionBegan"), "Private text or unwanted periodic/session event emitted")
        return "PASS: real SDK payloads and native actions; changed-preference values, failure classification and exclusions, complete wake snapshots, format provenance, text/error privacy, About links, and no heartbeat.\n"
    }

    static func events(_ type: String) -> [[String: Any]] {
        AnalyticsCaptureProtocol.snapshot().events.filter { $0["type"] as? String == "OnScreen." + type }
    }

    @MainActor
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }
}
