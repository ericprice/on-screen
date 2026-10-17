import AppKit

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        UserDefaults.standard.register(defaults: ["dateFormat": DateDisplayFormat.iso8601.rawValue,
                                                 "includeTime": true, "updateDaily": false, "randomizeFormat": false])
        let delegate = DesktopAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
