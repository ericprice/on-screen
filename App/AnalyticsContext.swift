import Foundation

/// Build provenance is bundled before signing. Runtime overrides can only mark
/// traffic as internal/test, never turn a development build into production.
struct AnalyticsContext: Sendable, Equatable {
    let environment: String
    let isInternal: Bool
    let appVersion: String
    let appBuild: String

    var properties: [String: String] {
        ["analytics_environment": environment,
         "is_internal": String(isInternal),
         "app_version": appVersion,
         "app_build": appBuild,
         "analytics_schema_version": "2"]
    }

    static var current: AnalyticsContext {
        resolve(
            bundled: bundledConfiguration,
            processEnvironment: ProcessInfo.processInfo.environment,
            internalTesting: UserDefaults.standard.bool(forKey: "analyticsInternalTesting"),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
    }

    static func resolve(
        bundled: [String: String], processEnvironment: [String: String],
        internalTesting: Bool, appVersion: String, appBuild: String
    ) -> AnalyticsContext {
        let declared = bundled["ON_SCREEN_ANALYTICS_ENVIRONMENT"] ?? "development"
        var environment = ["production", "development", "test"].contains(declared) ? declared : "development"
        // This override is useful for a production binary tested by its developer.
        // It cannot promote a local binary to production traffic.
        if processEnvironment["ON_SCREEN_ANALYTICS_TEST_MODE"] == "1" {
            environment = "test"
        }
        let internalOverride = ["1", "true"].contains(processEnvironment["ON_SCREEN_ANALYTICS_INTERNAL"] ?? "")
        let isInternal = environment != "production"
            || bundled["ON_SCREEN_ANALYTICS_INTERNAL"] != "false"
            || internalTesting || internalOverride
        return .init(environment: environment, isInternal: isInternal, appVersion: appVersion, appBuild: appBuild)
    }

    private static let bundledConfiguration: [String: String] = {
        guard let url = Bundle.main.url(forResource: "PostHogConfiguration", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            return [:]
        }
        return values
    }()
}
