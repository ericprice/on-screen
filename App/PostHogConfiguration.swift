import Foundation
import OSLog
import PostHog

/// Also blocks queued uploads: SDK optOut() stops capture, but not queue timers.
final class PostHogConsentURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var consentDefaults: UserDefaults = .standard

    static func use(_ defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        consentDefaults = defaults
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return consentDefaults.object(forKey: "shareUsageStatistics") != nil
            && !consentDefaults.bool(forKey: "shareUsageStatistics")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    override func stopLoading() {}
}

@MainActor
enum PostHogConfiguration {
    private static let logger = Logger(subsystem: "info.ericprice.on-screen", category: "analytics")
    private static var isConfigured = false
    private static var isStarting = false
    private static var preferenceObserver: NSObjectProtocol?
    private static var sessionConfiguration = URLSessionConfiguration.ephemeral
    private static var captureQueue = DispatchQueue(label: "info.ericprice.on-screen.analytics", qos: .utility)
    static var isEnabled: Bool { usageStatisticsEnabled(in: .standard) }

    /// Isolated checks can inject transport and a serial work queue to exercise this
    /// exact startup/consent/drain path. Retain them through deferred opt-in setup.
    static func setup(sessionConfiguration: URLSessionConfiguration? = nil, workQueue: DispatchQueue? = nil) {
        if let sessionConfiguration, !isConfigured, !isStarting {
            self.sessionConfiguration = sessionConfiguration.copy() as! URLSessionConfiguration
        }
        if let workQueue, !isConfigured, !isStarting { captureQueue = workQueue }
        if preferenceObserver == nil {
            preferenceObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { synchronizeUsageStatisticsPreference() }
            }
        }
        // Even setup requests remote configuration, so defer it entirely while opted out.
        guard isEnabled else {
            if isConfigured { synchronizeSDKConsent() }
            return
        }
        guard !isConfigured, !isStarting else { return }
        let bundled = Bundle.main.url(forResource: "PostHogConfiguration", withExtension: "plist")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: String] } ?? [:]
        let environment = ProcessInfo.processInfo.environment
        guard let projectToken = environment["POSTHOG_PROJECT_TOKEN"] ?? bundled["POSTHOG_PROJECT_TOKEN"],
              projectToken.hasPrefix("phc_"), projectToken.count > 4,
              let host = environment["POSTHOG_HOST"] ?? bundled["POSTHOG_HOST"],
              let url = URL(string: host), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            logger.error("PostHog configuration is missing or invalid; analytics disabled")
            return
        }
        // SDK persistence can synchronously notify UserDefaults observers during setup.
        isStarting = true
        defer { isStarting = false }
        PostHogSDK.shared.setup(makeConfig(projectToken: projectToken, host: host,
                                          sessionConfiguration: self.sessionConfiguration))
        isConfigured = true
        // The app preference owns consent, including after a previous SDK opt-out.
        synchronizeSDKConsent()
        logger.info("PostHog initialized from app configuration")
    }

    // SDK hooks execute on the capture caller's thread, including our utility queue.
    // Build them outside MainActor so nested filtering closures inherit no executor.
    nonisolated static func makeConfig(
        projectToken: String, host: String, defaults: UserDefaults = .standard,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) -> PostHogConfig {
        let config = PostHogConfig(projectToken: projectToken, host: host)
        config.optOut = !usageStatisticsEnabled(in: defaults)
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        config.disableGeoIp = true
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.capturePushNotificationSubscriptions = false
        config.capturePushNotificationOpened = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        // Native exceptions can include text, error descriptions, and local paths.
        // Categorized operational failures still pass through the typed event boundary.
        config.errorTrackingConfig.autoCapture = false
        config.errorTrackingConfig.exceptionSteps.enabled = false
        config.maxQueueSize = 100
        // This mostly idle utility does not need minute-by-minute uploads. The SDK
        // also uses this interval for its empty replay queue, reducing all idle ticks.
        config.flushIntervalSeconds = 300
        let session = sessionConfiguration.copy() as! URLSessionConfiguration
        session.httpShouldSetCookies = false
        session.httpCookieStorage = nil
        session.urlCredentialStorage = nil
        session.urlCache = nil
        PostHogConsentURLProtocol.use(defaults)
        session.protocolClasses = [PostHogConsentURLProtocol.self] + (session.protocolClasses ?? [])
        config.urlSessionConfiguration = session
        config.setBeforeSend { event in
            guard usageStatisticsEnabled(in: defaults), eventNames.contains(event.event) else { return nil }
            event.properties = event.properties.filter { eventProperties.contains($0.key) }
            for (key, value) in AnalyticsContext.current.properties { event.properties[key] = value }
            event.properties["$process_person_profile"] = false
            event.properties["$geoip_disable"] = true
            return event
        }
        config.logs.serviceName = "on-screen-macos"
        config.logs.maxBufferSize = 100
        config.logs.flushIntervalSeconds = 300
        config.logs.setBeforeSend { record in
            guard usageStatisticsEnabled(in: defaults),
                  let event = record.attributes["event"] as? String,
                  let message = logMessages[event], record.body == message else { return nil }
            record.attributes = record.attributes.filter { ["event", "source", "category", "daily_updates_enabled"].contains($0.key) }
            for (key, value) in AnalyticsContext.current.properties { record.attributes[key] = value }
            record.distinctId = nil
            record.sessionId = nil
            record.screenName = nil
            record.featureFlagKeys = []
            return record
        }
        return config
    }

    static func capture(_ event: String, properties: [String: String]) {
        synchronizeUsageStatisticsPreference()
        guard isEnabled, isConfigured else { return }
        captureQueue.async {
            guard usageStatisticsEnabled(in: .standard) else { return }
            PostHogSDK.shared.capture(event, properties: properties)
        }
    }

    static func flush() {
        synchronizeUsageStatisticsPreference()
        guard isEnabled, isConfigured else { return }
        captureQueue.async {
            guard usageStatisticsEnabled(in: .standard) else { return }
            PostHogSDK.shared.flush()
        }
    }

    /// Wait only for queued capture writes, never for network delivery. The SDK's
    /// durable queue retains undelivered events for the next launch.
    @discardableResult
    static func flushForTermination(timeout: TimeInterval = 1) -> Bool {
        synchronizeUsageStatisticsPreference()
        guard isConfigured else { return true }
        let drained = DispatchSemaphore(value: 0)
        captureQueue.async {
            if usageStatisticsEnabled(in: .standard) { PostHogSDK.shared.flush() }
            drained.signal()
        }
        return drained.wait(timeout: .now() + max(0, timeout)) == .success
    }

    static func synchronizeUsageStatisticsPreference() {
        // The app delegate owns initialization; isolated checks can use their own SDK.
        guard preferenceObserver != nil, !isStarting else { return }
        if !isEnabled {
            if isConfigured { synchronizeSDKConsent() }
        } else if !isConfigured {
            setup()
        } else {
            synchronizeSDKConsent()
        }
    }

    private static func synchronizeSDKConsent() {
        captureQueue.async {
            if usageStatisticsEnabled(in: .standard) {
                PostHogSDK.shared.optIn()
            } else {
                PostHogSDK.shared.optOut()
            }
        }
    }

    fileprivate static func log(_ event: String, attributes: [String: Any], isError: Bool) {
        synchronizeUsageStatisticsPreference()
        guard isEnabled, isConfigured, let message = logMessages[event] else { return }
        // Copy only the supported scalar fields across the concurrency boundary.
        let source = attributes["source"] as? String
        let category = attributes["category"] as? String
        let dailyUpdates = attributes["daily_updates_enabled"] as? Bool
        captureQueue.async {
            guard usageStatisticsEnabled(in: .standard) else { return }
            var properties: [String: Any] = ["event": event]
            if let source { properties["source"] = source }
            if let category { properties["category"] = category }
            if let dailyUpdates { properties["daily_updates_enabled"] = dailyUpdates }
            PostHogSDK.shared.captureLog(message, level: isError ? .error : .info, attributes: properties)
        }
    }

    nonisolated private static func usageStatisticsEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "shareUsageStatistics") == nil || defaults.bool(forKey: "shareUsageStatistics")
    }
    nonisolated private static let eventNames: Set<String> = [
        "app_launched", "app_woke", "timestamp_refreshed", "custom_text_changed",
        "display_setting_changed", "date_format_randomized", "about_opened", "website_clicked",
        "updates_checked", "text_color_changed", "preferences_changed", "open_at_login_failed", "update_check_failed",
        "update_check_completed", "app_running_daily"
    ]
    nonisolated private static let eventProperties: Set<String> = [
        "dateFormat", "includeTime", "timeIncluded", "updateDaily", "dailyUpdatesActive", "randomizeFormat",
        "mode", "reason", "previousDateFormat", "randomized", "source", "color", "openAtLogin",
        "openAtLoginStatus", "automaticUpdateChecks", "automaticUpdates", "changedPreference",
        "previousValue", "value", "category", "operation", "changedSetting", "previousMode", "outcome",
        "analytics_environment", "is_internal", "app_version", "app_build", "analytics_schema_version",
        "$lib", "$lib_version", "$app_name", "$app_version", "$app_build", "$app_namespace",
        "$os_name", "$os_version", "$device_type", "$device_manufacturer", "$device_model",
        "$process_person_profile", "$geoip_disable", "$is_identified"
    ]
    nonisolated private static let logMessages = [
        "desktop_app_ready": "desktop app ready",
        "update_check_requested": "manual update check requested",
        "update_check_failed": "update check failed"
    ]
}

@MainActor
enum PostHogExportLogger {
    static func info(_ message: String, attributes: [String: Any]) {
        guard let event = attributes["event"] as? String else { return }
        PostHogConfiguration.log(event, attributes: attributes, isError: false)
    }
    static func error(_ message: String, attributes: [String: Any]) {
        guard let event = attributes["event"] as? String else { return }
        PostHogConfiguration.log(event, attributes: attributes, isError: true)
    }
}
