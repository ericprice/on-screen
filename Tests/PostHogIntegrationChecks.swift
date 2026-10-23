import Foundation
import PostHog
import zlib

private struct PostHogIntegrationFailure: Error { let message: String }

/// Includes gzip so the production wrapper uses its normal SDK configuration.
private final class PostHogIntegrationTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String] = []
    nonisolated(unsafe) private static var events: [[String: Any]] = []
    nonisolated(unsafe) private static var logs: [[String: Any]] = []
    nonisolated(unsafe) private static var failures: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
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
            if request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" {
                data = try Self.inflateGzip(data)
            }
            let body = data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            Self.lock.lock()
            Self.requests.append(request.url!.absoluteString)
            Self.events.append(contentsOf: body["batch"] as? [[String: Any]] ?? [])
            let resources = body["resourceLogs"] as? [[String: Any]] ?? []
            Self.logs.append(contentsOf: resources.flatMap { $0["scopeLogs"] as? [[String: Any]] ?? [] }
                .flatMap { $0["logRecords"] as? [[String: Any]] ?? [] })
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            Self.lock.lock()
            Self.failures.append(String(describing: error))
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    static func snapshot() -> (requests: [String], events: [[String: Any]], logs: [[String: Any]], failures: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (requests, events, logs, failures)
    }

    private static func inflateGzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PostHogIntegrationFailure(message: "Unable to initialize intercepted gzip decoding")
        }
        defer { inflateEnd(&stream) }
        // Test payloads are small. A fixed limit also rejects malformed/unbounded data.
        let capacity = 1_048_576
        var result = Data(count: capacity)
        let status = data.withUnsafeBytes { input in
            result.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else {
            throw PostHogIntegrationFailure(message: "Unable to decode intercepted gzip payload")
        }
        result.count = Int(stream.total_out)
        return result
    }
}

enum PostHogIntegrationChecks {
    @MainActor
    static func run(startDisabled: Bool) async throws -> String {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw PostHogIntegrationFailure(message: message) }
        }
        try check(Bundle.main.bundleIdentifier == "info.ericprice.on-screen.analytics-checks",
                  "Wrapper checks require the isolated test app")
        guard let testHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw PostHogIntegrationFailure(message: "Wrapper checks require an isolated Foundation home")
        }
        let isolatedHome = URL(fileURLWithPath: testHome, isDirectory: true).standardizedFileURL.path + "/"
        for directory in [FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory] {
            try check(FileManager.default.urls(for: directory, in: .userDomainMask).first!.standardizedFileURL.path.hasPrefix(isolatedHome),
                      "Wrapper SDK storage escaped the isolated home")
        }
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        defaults.removePersistentDomain(forName: domain)
        defaults.set(!startDisabled, forKey: "shareUsageStatistics")
        let token = "phc_wrapper_checks_" + UUID().uuidString
        setenv("POSTHOG_PROJECT_TOKEN", token, 1)
        setenv("POSTHOG_HOST", "https://wrapper.analytics.invalid", 1)
        defer {
            defaults.set(false, forKey: "shareUsageStatistics")
            _ = PostHogConfiguration.flushForTermination()
            PostHogSDK.shared.close()
            defaults.removePersistentDomain(forName: domain)
        }
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [PostHogIntegrationTransport.self]
        let config = PostHogConfiguration.makeConfig(projectToken: token, host: "https://wrapper.analytics.invalid",
                                                     sessionConfiguration: session)
        try check(config.flushIntervalSeconds == 300 && config.logs.flushIntervalSeconds == 300,
                  "Idle event/replay/log batching must use five-minute intervals")
        let worker = DispatchQueue(label: "info.ericprice.on-screen.wrapper-checks", qos: .utility)
        PostHogConfiguration.setup(sessionConfiguration: session, workQueue: worker)
        let analytics = AppAnalytics()

        func waitUntil(_ message: String, condition: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try check(condition(), message)
        }
        func notifyConsent(_ enabled: Bool) {
            defaults.set(enabled, forKey: "shareUsageStatistics")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        func flushUntil(events: Int, logs: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                PostHogConfiguration.flush()
                let snapshot = PostHogIntegrationTransport.snapshot()
                try check(snapshot.failures.isEmpty, "Intercepted transport failed: \(snapshot.failures)")
                try check(snapshot.events.count <= events && snapshot.logs.count <= logs, "Wrapper generated duplicate records")
                if snapshot.events.count == events && snapshot.logs.count == logs { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw PostHogIntegrationFailure(message: "Wrapper delivery did not reach \(events) events / \(logs) logs")
        }

        if startDisabled {
            analytics.recordAboutOpened()
            PostHogExportLogger.info("desktop app ready", attributes: ["event": "desktop_app_ready"])
            try check(PostHogConfiguration.flushForTermination(), "Disabled startup drain failed")
            try await Task.sleep(for: .milliseconds(150))
            try check(PostHogIntegrationTransport.snapshot().requests.isEmpty,
                      "Disabled production setup/capture/log/flush must make zero requests")
            // Only the installed production observer can initialize this SDK here.
            notifyConsent(true)
        }
        try await waitUntil("Production setup did not request intercepted configuration") {
            PostHogIntegrationTransport.snapshot().requests.contains { $0.contains("/array/\(token)/config") }
        }
        try await waitUntil("App consent did not opt the configured SDK in") { !PostHogSDK.shared.isOptOut() }

        analytics.recordAboutOpened()
        analytics.recordWebsiteClicked()
        analytics.recordUpdatesChecked()
        PostHogExportLogger.info("desktop app ready", attributes: ["event": "desktop_app_ready", "daily_updates_enabled": true])
        PostHogExportLogger.info("manual update check requested", attributes: ["event": "update_check_requested", "source": "manual"])
        analytics.recordUpdateFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                                             userInfo: [NSLocalizedDescriptionKey: "PRIVATE WRAPPER SENTINEL"]), check: .updates)
        try await flushUntil(events: 4, logs: 3)
        let initial = PostHogIntegrationTransport.snapshot()
        try check(initial.events.compactMap { $0["event"] as? String } ==
                  ["about_opened", "website_clicked", "updates_checked", "update_check_failed"],
                  "Background persistence changed native event order")
        let bodies = initial.logs.compactMap { ($0["body"] as? [String: Any])?["stringValue"] as? String }
        try check(Set(bodies) == ["desktop app ready", "manual update check requested", "update check failed"],
                  "Production log wrapper did not export the three fixed messages")
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: initial.events + initial.logs), as: UTF8.self)
        try check(!encoded.contains("PRIVATE WRAPPER SENTINEL"), "Production wrapper leaked raw error details")
        for event in initial.events {
            let properties = event["properties"] as? [String: Any] ?? [:]
            try check(properties["analytics_environment"] as? String == "test" && properties["is_internal"] as? String == "true",
                      "Production wrapper did not retain isolated test provenance")
        }

        notifyConsent(false)
        try await waitUntil("Preference observer did not opt the SDK out") { PostHogSDK.shared.isOptOut() }
        let beforeOptOut = PostHogIntegrationTransport.snapshot().requests.count
        analytics.recordAboutOpened()
        PostHogExportLogger.info("desktop app ready", attributes: ["event": "desktop_app_ready"])
        try check(PostHogConfiguration.flushForTermination(), "Opted-out drain failed")
        try await Task.sleep(for: .milliseconds(150))
        try check(PostHogIntegrationTransport.snapshot().requests.count == beforeOptOut,
                  "Production wrapper transmitted after runtime opt-out")
        notifyConsent(true)
        try await waitUntil("Preference observer did not opt the SDK back in") { !PostHogSDK.shared.isOptOut() }

        // A real pending worker proves that the termination timeout is bounded,
        // and that a successful drain waits behind the final capture. Merely
        // calling flushUntil afterward would hide a missing drain/flush.
        let workerBlocked = DispatchSemaphore(value: 0)
        let releaseWorker = DispatchSemaphore(value: 0)
        worker.async {
            workerBlocked.signal()
            _ = releaseWorker.wait(timeout: .now() + 5)
        }
        defer { releaseWorker.signal() }
        try check(workerBlocked.wait(timeout: .now() + 1) == .success, "Unable to hold the injected worker")
        analytics.recordAboutOpened()
        let timeoutStart = ContinuousClock.now
        let timedOutDrain = PostHogConfiguration.flushForTermination(timeout: 0.05)
        let timeoutElapsed = ContinuousClock.now - timeoutStart
        try check(!timedOutDrain, "Termination claimed a successful drain while capture was blocked")
        try check(timeoutElapsed >= .milliseconds(40) && timeoutElapsed < .seconds(1),
                  "Termination did not respect its bounded wait")
        try check(PostHogIntegrationTransport.snapshot().events.count == 4,
                  "The held worker unexpectedly persisted/transmitted the final event")
        releaseWorker.signal()
        try check(PostHogConfiguration.flushForTermination(), "Termination did not drain pending background persistence")
        try await waitUntil("Termination flush did not deliver the drained event") {
            PostHogIntegrationTransport.snapshot().events.count == 5
        }
        let final = PostHogIntegrationTransport.snapshot()
        try check(final.failures.isEmpty && final.events.count == 5 && final.logs.count == 3,
                  "Termination flush failed or duplicated records")
        try check(final.requests.filter { $0.contains("/array/") }.count == 1,
                  "Consent toggles initialized the SDK more than once")
        try check(final.requests.allSatisfy { URL(string: $0)?.host == "wrapper.analytics.invalid" },
                  "Wrapper requested a non-test endpoint")
        return "PASS: production wrapper \(startDisabled ? "disabled" : "enabled") startup, deferred setup, observer-driven consent, fixed logs, FIFO background persistence, bounded termination drain, five-minute batching, and intercepted gzip transport.\n"
    }
}
