import AppKit
import CoreText
import ServiceManagement
import OSLog

@MainActor
final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "dev.ericprice.iso8601-on-kawara", category: "desktop")
    private var window: DesktopWindow?
    private var statusItem: NSStatusItem?
    private var timestamp = ""
    private var updatedAt = Date()
    private var reason = "launch"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate windows/menu items if the bundle is launched again.
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
        if duplicates.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        guard let fontURL = Bundle.main.url(forResource: "ISO8601Kawara-Regular", withExtension: "otf") else {
            logger.error("Bundled font is missing")
            NSApp.terminate(nil)
            return
        }
        var fontError: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &fontError) else {
            logger.error("Could not register the bundled font")
            NSApp.terminate(nil)
            return
        }
        let window = DesktopWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "ISO 8601 Kawara"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.contentView = TimestampView()
        self.window = window

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let iconURL = Bundle.main.url(forResource: "kawara-menu-icon", withExtension: "pdf"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            icon.accessibilityDescription = "ISO 8601 Kawara"
            item.button?.image = icon
        }
        let menu = NSMenu()
        let about = NSMenuItem(title: "About ISO 8601 Kawara", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset", action: #selector(resetTimestamp), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        registerAtLogin()
        refreshTimestamp(reason: "launch/login")
    }

    private func registerAtLogin() {
        let service = SMAppService.mainApp
        let defaults = UserDefaults.standard
        let bundlePath = Bundle.main.bundlePath
        let renamedEnabledApp = service.status == .enabled && defaults.string(forKey: "registeredBundlePath") != bundlePath
        // Respect a later user decision to disable the item in System Settings.
        if !defaults.bool(forKey: "loginRegistrationAttempted") || renamedEnabledApp {
            do {
                if renamedEnabledApp {
                    try service.unregister()
                    defaults.set(false, forKey: "loginRegistrationAttempted")
                }
                try service.register()
                defaults.set(true, forKey: "loginRegistrationAttempted")
                defaults.set(bundlePath, forKey: "registeredBundlePath")
            } catch {
                logger.error("Login registration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        logger.info("Login item status: \(service.status.rawValue)")
    }

    private func refreshTimestamp(reason: String) {
        updatedAt = Date()
        self.reason = reason
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        timestamp = formatter.string(from: updatedAt)
        positionArtwork()
    }

    private func positionArtwork() {
        guard let window, let view = window.contentView as? TimestampView else { return }
        let primaryID = CGMainDisplayID()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == primaryID
        }) else {
            window.orderOut(nil)
            return
        }
        let artwork = TimestampArtwork.make(timestamp, width: screen.frame.width * 0.75)
        // Even point dimensions avoid asymmetric frame rounding by NSWindow.
        // The glyph bounds remain at exactly 75%; only transparent padding grows.
        let size = NSSize(width: ceil((artwork.inkBounds.width + 4) / 2) * 2,
                          height: ceil((artwork.inkBounds.height + 4) / 2) * 2)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2, width: size.width, height: size.height)
        window.setFrame(frame, display: false)
        view.artwork = artwork
        window.orderFrontRegardless()
        writeDiagnostics(screen: screen, artwork: artwork)
        logger.info("Timestamp updated: \(self.timestamp, privacy: .public), reason: \(self.reason, privacy: .public)")
    }

    private func writeDiagnostics(screen: NSScreen, artwork: TimestampArtwork) {
        guard let window else { return }
        let values: [String: Any] = [
            "timestamp": timestamp,
            "updatedAt": updatedAt.timeIntervalSince1970,
            "reason": reason,
            "primaryDisplayID": CGMainDisplayID(),
            "screenFrame": NSStringFromRect(screen.frame),
            "windowFrame": NSStringFromRect(window.frame),
            "inkWidthRatio": artwork.inkBounds.width / screen.frame.width,
            "centerErrorX": window.frame.midX - screen.frame.midX,
            "centerErrorY": window.frame.midY - screen.frame.midY,
            "windowLevel": window.level.rawValue,
            "desktopIconLevel": CGWindowLevelForKey(.desktopIconWindow),
            "ignoresMouseEvents": window.ignoresMouseEvents,
            "hasShadow": window.hasShadow,
            "isOpaque": window.isOpaque,
            "loginItemStatus": SMAppService.mainApp.status.rawValue
        ]
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ISO8601OnKawara")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        } catch {
            logger.error("Could not write diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func didWake() { refreshTimestamp(reason: "wake") }
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: "1.0",
            .version: "",
            .credits: NSAttributedString(string: "")
        ])
    }

    @objc private func resetTimestamp() { refreshTimestamp(reason: "reset") }
    @objc private func displaysChanged() { positionArtwork() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
