import Foundation
import OSLog

/// Keep atomic diagnostics writes ordered without blocking menu and color actions.
enum DiagnosticsWriter {
    private static let queue = DispatchQueue(label: "info.ericprice.on-screen.diagnostics", qos: .utility)
    private static let logger = Logger(subsystem: "info.ericprice.on-screen", category: "diagnostics")

    static func write(_ data: Data) {
        queue.async {
            do {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true).appendingPathComponent("On Screen")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
            } catch {
                logger.error("Could not write diagnostics: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @discardableResult
    static func flush(timeout: TimeInterval = 1) -> Bool {
        let drained = DispatchSemaphore(value: 0)
        queue.async { drained.signal() }
        return drained.wait(timeout: .now() + timeout) == .success
    }
}
