import AppKit
import ServiceManagement
import Sparkle

/// Only these typed actions and fixed fields can enter analytics; custom text never does.
@MainActor
final class AppAnalytics {
    enum ColorMode: String { case white, black, custom }
    enum LoginStatus: String { case enabled, disabled, requiresApproval, notFound, unknown }
    enum LoginOperation: String { case automaticRegistration, enable, disable }
    enum UpdateOutcome: String {
        case upToDate = "up_to_date"
        case updateAvailable = "update_available"
        case cancelled, failed, unknown
    }
    enum DisplaySetting: String {
        case dateFormat, includeTime, updateDaily, randomizeFormat

        var property: String { rawValue }
    }
    enum RefreshReason: String {
        case launch = "launch/login", midnight, wake, reset
        case clockChanged = "clock/time-zone-changed"
        case customTextCleared = "custom-text-cleared"
        case randomizationEnabled = "randomize-format-enabled"
    }

    struct DisplayState: Equatable {
        let dateFormat: DateDisplayFormat
        let includeTime: Bool
        let updateDaily: Bool
        let randomizeFormat: Bool
        let isCustomText: Bool

        var parameters: [String: String] {
            [
                "dateFormat": dateFormat.rawValue,
                "includeTime": String(includeTime),
                "timeIncluded": String(!isCustomText && (includeTime || dateFormat.alwaysIncludesTime)),
                "updateDaily": String(updateDaily),
                "dailyUpdatesActive": String(updateDaily && !isCustomText),
                "randomizeFormat": String(randomizeFormat),
                "mode": isCustomText ? "custom" : "timestamp"
            ]
        }
    }

    struct Preferences: Equatable {
        let loginStatus: LoginStatus
        let automaticUpdateChecks: Bool
        let automaticUpdates: Bool

        var parameters: [String: String] {
            [
                "openAtLogin": String(loginStatus == .enabled),
                "openAtLoginStatus": loginStatus.rawValue,
                "automaticUpdateChecks": String(automaticUpdateChecks),
                "automaticUpdates": String(automaticUpdates)
            ]
        }
    }

    private enum Event: String {
        case launched = "app_launched"
        case runningDaily = "app_running_daily"
        case textChanged = "custom_text_changed"
        case colorChanged = "text_color_changed"
        case preferencesChanged = "preferences_changed"
        case displaySettingChanged = "display_setting_changed"
        case woke = "app_woke"
        case timestampRefreshed = "timestamp_refreshed"
        case aboutOpened = "about_opened"
        case websiteClicked = "website_clicked"
        case updatesChecked = "updates_checked"
        case updateCompleted = "update_check_completed"
        case loginFailed = "open_at_login_failed"
        case updateFailed = "update_check_failed"
        case formatRandomized = "date_format_randomized"
    }

    private let defaults: UserDefaults
    private let postHogCapture: (String, [String: String]) -> Void
    private let contextProperties: () -> [String: String]
    private var lastPreferences: Preferences?

    init(
        defaults: UserDefaults = .standard,
        postHogCapture: @escaping (String, [String: String]) -> Void = { PostHogConfiguration.capture($0, properties: $1) },
        contextProperties: @escaping () -> [String: String] = { AnalyticsContext.current.properties }
    ) {
        self.defaults = defaults
        self.postHogCapture = postHogCapture
        self.contextProperties = contextProperties
    }

    var isEnabled: Bool {
        defaults.object(forKey: "shareUsageStatistics") == nil || defaults.bool(forKey: "shareUsageStatistics")
    }

    func recordLaunch(preferences: Preferences, display: DisplayState) {
        lastPreferences = preferences
        send(.launched, parameters: preferences.parameters.merging(display.parameters) { _, new in new })
    }

    func recordRunningDaily(preferences: Preferences, display: DisplayState, reason: String) {
        guard ["launch", "wake", "daily_boundary", "clock_change", "consent_enabled"].contains(reason) else { return }
        let parameters = preferences.parameters.merging(display.parameters) { _, new in new }
            .merging(["reason": reason]) { _, new in new }
        send(.runningDaily, parameters: parameters)
    }

    func recordTextChanged(display: DisplayState) {
        send(.textChanged, parameters: display.parameters)
    }

    func recordDisplaySettingChanged(_ setting: DisplaySetting, previous: DisplayState, display: DisplayState) {
        guard previous != display else { return }
        send(.displaySettingChanged, parameters: display.parameters.merging([
            "changedSetting": setting.property,
            "previousValue": previous.parameters[setting.property]!,
            "value": display.parameters[setting.property]!,
            "previousMode": previous.parameters["mode"]!
        ]) { _, new in new })
    }

    func recordFormatRandomized(reason: RefreshReason, previousFormat: DateDisplayFormat, display: DisplayState) {
        guard !display.isCustomText else { return }
        send(.formatRandomized, parameters: display.parameters.merging([
            "reason": reason.rawValue, "previousDateFormat": previousFormat.rawValue
        ]) { _, new in new })
    }

    func recordTimestampRefresh(reason: RefreshReason, previousFormat: DateDisplayFormat, display: DisplayState) {
        // These actions have their own launch, wake, toggle, or confirmed text-change event.
        guard !display.isCustomText,
              reason != .launch, reason != .wake,
              reason != .randomizationEnabled, reason != .customTextCleared else { return }
        send(.timestampRefreshed, parameters: display.parameters.merging([
            "reason": reason.rawValue,
            "previousDateFormat": previousFormat.rawValue,
            "randomized": String(previousFormat != display.dateFormat)
        ]) { _, new in new })
    }

    func recordWake(preferences: Preferences, display: DisplayState) {
        send(.woke, parameters: preferences.parameters.merging(display.parameters) { _, new in new })
    }
    func recordAboutOpened() { send(.aboutOpened) }
    func recordWebsiteClicked() { send(.websiteClicked, parameters: ["source": "about"]) }
    func recordUpdatesChecked() { send(.updatesChecked) }
    func recordUpdateCheckCompleted(source: SPUUpdateCheck, outcome: UpdateOutcome) {
        send(.updateCompleted, parameters: ["source": updateSource(source), "outcome": outcome.rawValue])
    }

    func recordColorChanged(color: NSColor, mode: ColorMode) {
        guard let color = color.usingColorSpace(.sRGB) else { return }
        let components = [color.redComponent, color.greenComponent, color.blueComponent]
        guard components.allSatisfy(\.isFinite) else { return }
        let rgb = components.map { Int((min(1, max(0, $0)) * 255).rounded()) }
        let hex = String(format: "#%02X%02X%02X", rgb[0], rgb[1], rgb[2])
        send(.colorChanged, parameters: ["color": hex, "mode": mode.rawValue])
    }

    func recordPreferencesChanged(_ preferences: Preferences) {
        guard let previous = lastPreferences else {
            lastPreferences = preferences
            return
        }
        guard preferences != previous else { return }
        lastPreferences = preferences
        let changes: [(name: String, old: Bool, new: Bool, changed: Bool)] = [
            ("openAtLogin", previous.loginStatus == .enabled, preferences.loginStatus == .enabled, previous.loginStatus != preferences.loginStatus),
            ("automaticUpdateChecks", previous.automaticUpdateChecks, preferences.automaticUpdateChecks, previous.automaticUpdateChecks != preferences.automaticUpdateChecks),
            ("automaticUpdates", previous.automaticUpdates, preferences.automaticUpdates, previous.automaticUpdates != preferences.automaticUpdates)
        ]
        for change in changes where change.changed {
            send(.preferencesChanged, parameters: preferences.parameters.merging([
                "changedPreference": change.name,
                "previousValue": String(change.old),
                "value": String(change.new)
            ]) { _, new in new })
        }
    }

    func recordLoginFailure(_ error: Error, operation: LoginOperation) {
        let error = error as NSError
        let category: String
        if error.domain == SMAppServiceErrorDomain {
            if error.code == kSMErrorAlreadyRegistered && operation != .disable { return }
            if error.code == kSMErrorJobNotFound && operation == .disable { return }
            switch error.code {
            case kSMErrorInvalidSignature: category = "signature"
            case kSMErrorAuthorizationFailure, kSMErrorJobMustBeEnabled, kSMErrorLaunchDeniedByUser: category = "permission"
            case kSMErrorToolNotValid, kSMErrorJobNotFound, kSMErrorJobPlistNotFound: category = "notFound"
            case kSMErrorServiceUnavailable: category = "unavailable"
            case kSMErrorInvalidPlist: category = "configuration"
            case kSMErrorInternalFailure: category = "internal"
            default: category = "other"
            }
        } else {
            category = "other"
        }
        send(.loginFailed, parameters: ["operation": operation.rawValue, "category": category])
    }

    func recordUpdateFailure(_ error: Error, check: SPUUpdateCheck) {
        // Sparkle reports an up-to-date app and user cancellation through its error path.
        // Inspect bounded underlying errors for cancellation; never transmit error details.
        var underlying: NSError? = error as NSError
        for _ in 0..<5 {
            guard let current = underlying else { break }
            if current.domain == NSURLErrorDomain && current.code == NSURLErrorCancelled { return }
            if current.domain == SUSparkleErrorDomain && [
                Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue),
                Int(SUError.installationAuthorizeLaterError.rawValue)
            ].contains(current.code) { return }
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let error = error as NSError
        let category: String
        if error.domain == NSURLErrorDomain {
            category = "network"
        } else if error.domain == SUSparkleErrorDomain {
            switch error.code {
            case Int(SUError.appcastParseError.rawValue), Int(SUError.appcastError.rawValue), Int(SUError.resumeAppcastError.rawValue):
                category = "feed"
            case Int(SUError.downloadError.rawValue): category = "download"
            case Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue): category = "signature"
            case 1...7, Int(SUError.incorrectAPIUsageError.rawValue): category = "configuration"
            case Int(SUError.unarchivingError.rawValue), 4000...4012: category = "installation"
            default: category = "other"
            }
        } else {
            category = "other"
        }
        send(.updateFailed, parameters: ["source": updateSource(check), "category": category])
    }

    private func updateSource(_ check: SPUUpdateCheck) -> String {
        switch check {
        case .updates: "manual"
        case .updatesInBackground: "automatic"
        case .updateInformation: "information"
        @unknown default: "unknown"
        }
    }

    private func send(_ event: Event, parameters: [String: String] = [:]) {
        guard isEnabled else { return }
        let parameters = parameters.merging(contextProperties()) { _, context in context }
        postHogCapture(event.rawValue, parameters)
        if event == .updateFailed {
            PostHogExportLogger.error("update check failed", attributes: [
                "event": "update_check_failed",
                "source": parameters["source"] ?? "unknown",
                "category": parameters["category"] ?? "other"
            ])
        }
    }

}
