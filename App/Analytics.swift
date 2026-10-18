import AppKit
import ServiceManagement
import Sparkle
import TelemetryDeck

/// Only these typed actions and fixed fields can enter analytics; custom text never does.
@MainActor
final class AppAnalytics {
    enum ColorMode: String { case white, black, custom }
    enum LoginStatus: String { case enabled, disabled, requiresApproval, notFound, unknown }
    enum LoginOperation: String { case automaticRegistration, enable, disable }
    enum DisplaySetting: String {
        case dateFormat = "DateFormat.changed"
        case includeTime = "IncludeTime.changed"
        case updateDaily = "DailyUpdates.changed"
        case randomizeFormat = "Randomization.changed"
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
        case launched = "App.launched"
        case textChanged = "Text.changed"
        case colorChanged = "Color.changed"
        case preferencesChanged = "Preferences.changed"
        case woke = "App.woke"
        case timestampRefreshed = "Timestamp.refreshed"
        case aboutOpened = "About.opened"
        case websiteClicked = "Website.clicked"
        case updatesChecked = "Updates.checked"
        case loginFailed = "OpenAtLogin.failed"
        case updateFailed = "Updates.failed"
        case formatRandomized = "DateFormat.randomized"
    }

    private let defaults: UserDefaults
    private let sessionConfiguration: URLSessionConfiguration
    private let transmitInterval: TimeInterval
    private var configuration: TelemetryDeck.Config?
    private var lastPreferences: Preferences?

    init(defaults: UserDefaults = .standard, sessionConfiguration: URLSessionConfiguration = .ephemeral, transmitInterval: TimeInterval = 60) {
        self.defaults = defaults
        self.sessionConfiguration = sessionConfiguration
        self.transmitInterval = transmitInterval
    }

    var isEnabled: Bool {
        defaults.object(forKey: "shareUsageStatistics") == nil || defaults.bool(forKey: "shareUsageStatistics")
    }

    func start() {
        guard isEnabled, configuration == nil else { return }
        let config = TelemetryDeck.Config(
            appID: "56092A55-E45A-41D9-A104-36566909C5BD",
            namespace: "info.ericprice"
        )
        config.defaultSignalPrefix = "OnScreen."
        config.defaultParameterPrefix = "OnScreen."
        // This desktop utility needs action counts, without foreground/session events
        // or the SDK's once-per-second session-duration persistence.
        config.sendNewSessionBeganSignal = false
        config.sessionStatsEnabled = false
        config.transmitInterval = transmitInterval
        config.cacheLimit = 100
        if ProcessInfo.processInfo.environment["ON_SCREEN_ANALYTICS_TEST_MODE"] == "1" {
            config.testMode = true
        }
        config.urlSession = makeSession()
        configuration = config
        TelemetryDeck.initialize(config: config)
    }

    func recordLaunch(preferences: Preferences, display: DisplayState) {
        lastPreferences = preferences
        send(.launched, parameters: preferences.parameters.merging(display.parameters) { _, new in new })
    }

    func recordTextChanged(display: DisplayState) {
        send(.textChanged, parameters: display.parameters)
    }

    func recordDisplaySettingChanged(_ setting: DisplaySetting, display: DisplayState) {
        send(setting.rawValue, parameters: display.parameters)
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
        let source: String
        switch check {
        case .updates: source = "manual"
        case .updatesInBackground: source = "automatic"
        case .updateInformation: source = "information"
        @unknown default: source = "unknown"
        }
        send(.updateFailed, parameters: ["source": source, "category": category])
    }

    private func send(_ event: Event, parameters: [String: String] = [:]) {
        send(event.rawValue, parameters: parameters)
    }

    private func send(_ name: String, parameters: [String: String]) {
        guard isEnabled, configuration != nil else { return }
        TelemetryDeck.signal(name, parameters: parameters)
    }

    private func makeSession() -> URLSession {
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        return URLSession(configuration: sessionConfiguration)
    }
}
