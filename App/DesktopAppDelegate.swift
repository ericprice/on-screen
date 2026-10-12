import AppKit
import CoreText
import ServiceManagement
import OSLog
import Sparkle

@MainActor
final class DesktopAppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private enum TextColorMode: Int { case white, black, custom }
    // Start after duplicate-instance detection; Sparkle owns persisted update preferences.
    private let updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private static let customTextLimit = 24
    // Resolve after the bundled font has been registered, without font fallback.
    private lazy var supportedCharacters = CTFontCopyCharacterSet(CTFontCreateWithName("ISO8601Kawara-Regular" as CFString, 100, nil))
    private let logger = Logger(subsystem: "dev.ericprice.iso8601-on-kawara", category: "desktop")
    private var window: DesktopWindow?
    private var statusItem: NSStatusItem?
    private var timestamp = ""
    private var textColorMode: TextColorMode = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "textColorMode") != nil {
            return TextColorMode(rawValue: defaults.integer(forKey: "textColorMode")) ?? .white
        }
        return defaults.bool(forKey: "blackText") ? .black : .white
    }()
    private var customColor: NSColor = {
        guard let components = UserDefaults.standard.array(forKey: "customColor") as? [Double],
              components.count == 3,
              components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return .white }
        return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1)
    }()
    private var textColor: NSColor {
        switch textColorMode {
        case .white: return .white
        case .black: return .black
        case .custom: return customColor
        }
    }
    private var customText: String? = UserDefaults.standard.string(forKey: "customText").map { String($0.prefix(customTextLimit)) }
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
        if let customText {
            let filtered = filteredCustomText(customText)
            if filtered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearCustomText()
            } else {
                self.customText = filtered
                UserDefaults.standard.set(filtered, forKey: "customText")
            }
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

        updaterController.startUpdater()

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
        let checkForUpdates = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdates.target = updaterController
        menu.addItem(checkForUpdates)
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom Text…", action: #selector(showCustomText), keyEquivalent: "t")
        custom.keyEquivalentModifierMask = .command
        custom.target = self
        custom.state = customText == nil ? .off : .on
        menu.addItem(custom)
        let reset = NSMenuItem(title: "Reset to Current Timestamp", action: #selector(resetTimestamp), keyEquivalent: "r")
        reset.keyEquivalentModifierMask = .command
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        for (tag, title) in ["White Text", "Black Text", "Custom Text Color…"].enumerated() {
            let color = NSMenuItem(title: title, action: #selector(selectTextColor(_:)), keyEquivalent: String(tag + 1))
            color.keyEquivalentModifierMask = .command
            color.target = self
            color.tag = tag
            color.state = textColorMode.rawValue == tag ? .on : .off
            menu.addItem(color)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ISO 8601 Kawara", action: #selector(quitApp), keyEquivalent: "q")
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
        statusItem?.menu?.items.first(where: { $0.action == #selector(showCustomText) })?.state = customText == nil ? .off : .on
        guard let window, let view = window.contentView as? TimestampView else { return }
        let primaryID = CGMainDisplayID()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == primaryID
        }) else {
            window.orderOut(nil)
            return
        }
        let artwork = TimestampArtwork.make(customText ?? timestamp,
                                            width: screen.frame.width * 0.75,
                                            height: screen.frame.height * 0.50,
                                            color: textColor)
        // Even point dimensions avoid asymmetric frame rounding by NSWindow.
        // The glyph bounds fit within 75% of display width and 50% of height.
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
            "textColorMode": String(describing: textColorMode),
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
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: "",
            .credits: NSAttributedString(string: "")
        ])
    }

    @objc private func showCustomText() {
        let alert = NSAlert()
        alert.messageText = "Enter Custom Text"
        alert.informativeText = "24 characters maximum. Leave blank to show the timestamp."
        alert.addButton(withTitle: "Set Text")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: customText ?? "")
        field.usesSingleLineMode = true
        field.frame.size = NSSize(width: 228, height: field.intrinsicContentSize.height)
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = self
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clearCustomText()
            refreshTimestamp(reason: "custom-text-cleared")
        } else {
            customText = field.stringValue
            UserDefaults.standard.set(customText, forKey: "customText")
            positionArtwork()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let original = field.stringValue
        let filtered = filteredCustomText(original)
        guard filtered != original else { return }
        let editor = field.currentEditor()
        let selection = editor?.selectedRange
        field.stringValue = filtered
        if let selection {
            let length = field.stringValue.utf16.count
            let prefixRange = Range(NSRange(location: 0, length: selection.location), in: original)
            let location = prefixRange.map { filteredCustomText(String(original[$0])).utf16.count } ?? length
            editor?.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
        }
    }

    private func filteredCustomText(_ text: String) -> String {
        let supported = text.filter { character in
            let scalars = character.unicodeScalars
            let inFont = scalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) &&
                CFCharacterSetIsLongCharacterMember(supportedCharacters, $0.value)
            }
            // ASCII digits also have the emoji property; only keycap sequences
            // should use it to qualify as emoji. Keep the entire sequence intact.
            let hasEmoji = scalars.contains {
                ($0.properties.isEmoji && $0.value > 0x7F) || $0.value == 0x20E3
            }
            let isEmoji = hasEmoji && scalars.allSatisfy {
                $0.properties.isEmoji || $0.value == 0x200D ||
                $0.value == 0xFE0E || $0.value == 0xFE0F ||
                $0.value == 0x20E3 || (0xE0020...0xE007F).contains($0.value)
            }
            return inFont || isEmoji
        }
        return String(supported.prefix(Self.customTextLimit))
    }

    private func clearCustomText() {
        customText = nil
        UserDefaults.standard.removeObject(forKey: "customText")
    }

    @objc private func resetTimestamp() {
        clearCustomText()
        refreshTimestamp(reason: "reset")
    }
    @objc private func selectTextColor(_ sender: NSMenuItem) {
        guard let mode = TextColorMode(rawValue: sender.tag) else { return }
        textColorMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "textColorMode")
        for item in sender.menu?.items ?? [] where item.action == #selector(selectTextColor(_:)) {
            item.state = mode.rawValue == item.tag ? .on : .off
        }
        positionArtwork()
        let panel = NSColorPanel.shared
        if mode == .custom {
            panel.title = "Custom Text Color"
            panel.showsAlpha = false
            panel.isContinuous = true
            panel.color = customColor
            panel.setTarget(self)
            panel.setAction(#selector(customColorChanged(_:)))
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderOut(nil)
        }
    }
    @objc private func customColorChanged(_ sender: NSColorPanel) {
        guard textColorMode == .custom,
              let color = sender.color.usingColorSpace(.sRGB) else { return }
        customColor = color.withAlphaComponent(1)
        UserDefaults.standard.set([color.redComponent, color.greenComponent, color.blueComponent], forKey: "customColor")
        positionArtwork()
    }
    @objc private func displaysChanged() { positionArtwork() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
