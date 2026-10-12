import AppKit

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = DesktopAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
