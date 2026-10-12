import AppKit
import TelemetryDeck

/// Only these typed actions and fixed fields can enter analytics; custom text never does.
@MainActor
final class AppAnalytics {
    enum ColorMode: String { case white, black, custom }
    enum LoginStatus: String { case enabled, disabled, requiresApproval, notFound, unknown }

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

    func recordLaunch(preferences: Preferences) {
        lastPreferences = preferences
        send(.launched, parameters: preferences.parameters)
    }

    func recordTextChanged(isCustom: Bool) {
        send(.textChanged, parameters: ["mode": isCustom ? "custom" : "timestamp"])
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
        send(.preferencesChanged, parameters: preferences.parameters)
    }

    private func send(_ event: Event, parameters: [String: String]) {
        guard isEnabled, configuration != nil else { return }
        TelemetryDeck.signal(event.rawValue, parameters: parameters)
    }

    private func makeSession() -> URLSession {
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        return URLSession(configuration: sessionConfiguration)
    }
}
