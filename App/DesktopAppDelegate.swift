import AppKit
import CoreText
import ServiceManagement
import OSLog
import Sparkle

@MainActor
final class DesktopAppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate, NSMenuItemValidation, SPUUpdaterDelegate {
    private enum TextColorMode: Int { case white, black, custom }
    // Start after duplicate-instance detection; Sparkle owns persisted update preferences.
    private lazy var updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private let analytics: AppAnalytics
    private lazy var aboutLinkTracker = AboutWebsiteLinkTracker { [weak self] in
        self?.analytics.recordWebsiteClicked()
    }
    private var updatePreferenceObservations: [NSKeyValueObservation] = []
    private var updateCycleActive = false
    private var updateFound = false
    private var updateDownloadCancelled = false
    private static let customTextLimit = 24
    // Resolve after the bundled font has been registered, without font fallback.
    private lazy var supportedCharacters = CTFontCopyCharacterSet(CTFontCreateWithName("ISO8601Kawara-Regular" as CFString, 100, nil))
    private let logger = Logger(subsystem: "info.ericprice.on-screen", category: "desktop")
    private var window: DesktopWindow?
    private var statusItem: NSStatusItem?
    private var dateFormatMenu: NSMenu?
    private var timestamp = ""
    private var dateFormat = UserDefaults.standard.string(forKey: "dateFormat").flatMap(DateDisplayFormat.init(rawValue:)) ?? .iso8601
    private var includeTime = UserDefaults.standard.bool(forKey: "includeTime")
    private var updateDaily = UserDefaults.standard.bool(forKey: "updateDaily")
    private var randomizeFormat = UserDefaults.standard.bool(forKey: "randomizeFormat")
    private lazy var dailyUpdateScheduler = DailyUpdateScheduler { [weak self] in
        self?.refreshTimestamp(reason: .midnight)
    }
    private var textColorMode = TextColorMode(rawValue: UserDefaults.standard.integer(forKey: "textColorMode")) ?? .white
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
    private var colorPersistenceTimer: Timer?
    private var pendingColorAnalytics = false
    private var lastReportedColor: NSColor?
    private var lastReportedColorMode: TextColorMode?
    private lazy var runningDailyReporter = AppRunningDailyReporter(
        enabled: { [weak self] in self?.analytics.isEnabled == true },
        record: { [weak self] trigger in
            guard let self else { return }
            analytics.recordRunningDaily(preferences: analyticsPreferences, display: analyticsDisplayState, reason: trigger.rawValue)
        }
    )

    init(analytics: AppAnalytics = AppAnalytics()) {
        self.analytics = analytics
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate windows/menu items if the bundle is launched again.
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
        if duplicates.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        PostHogConfiguration.setup()
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
        window.title = "On Screen"
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
        if let iconURL = Bundle.main.url(forResource: "on-screen-menu-icon", withExtension: "pdf"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            icon.accessibilityDescription = "On Screen"
            item.button?.image = icon
        }
        let menu = NSMenu()
        menu.delegate = self
        let about = NSMenuItem(title: "About On Screen", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let openAtLogin = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")
        openAtLogin.target = self
        menu.addItem(openAtLogin)
        let checkForUpdates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdates.target = self
        menu.addItem(checkForUpdates)
        menu.addItem(.separator())
        let formats = NSMenu(title: "Date Format")
        formats.delegate = self
        formats.autoenablesItems = false
        for format in DateDisplayFormat.allCases.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
            let option = NSMenuItem(title: format.title, action: #selector(selectDateFormat(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = format.rawValue
            formats.addItem(option)
        }
        formats.addItem(.separator())
        let time = NSMenuItem(title: "Include Time", action: #selector(toggleIncludeTime), keyEquivalent: "t")
        time.keyEquivalentModifierMask = [.command, .shift]
        time.target = self
        formats.addItem(time)
        let randomize = NSMenuItem(title: "Randomize Format", action: #selector(toggleRandomizeFormat), keyEquivalent: "r")
        randomize.keyEquivalentModifierMask = [.command, .shift]
        randomize.target = self
        formats.addItem(randomize)
        let formatItem = NSMenuItem(title: "Date Format", action: nil, keyEquivalent: "")
        formatItem.submenu = formats
        menu.addItem(formatItem)
        dateFormatMenu = formats
        let custom = NSMenuItem(title: "Custom Text…", action: #selector(showCustomText), keyEquivalent: "t")
        custom.keyEquivalentModifierMask = .command
        custom.target = self
        custom.state = customText == nil ? .off : .on
        menu.addItem(custom)
        let reset = NSMenuItem(title: "Reset to Current Timestamp", action: #selector(resetTimestamp), keyEquivalent: "r")
        reset.keyEquivalentModifierMask = .command
        reset.target = self
        menu.addItem(reset)
        let daily = NSMenuItem(title: "Update Daily", action: #selector(toggleUpdateDaily(_:)), keyEquivalent: "d")
        daily.keyEquivalentModifierMask = .command
        daily.target = self
        daily.state = updateDaily ? .on : .off
        daily.isEnabled = customText == nil
        menu.addItem(daily)
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
        let quit = NSMenuItem(title: "Quit On Screen", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: .NSSystemClockDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: .NSSystemTimeZoneDidChange, object: nil)
        registerAtLogin()
        refreshTimestamp(reason: .launch)
        lastReportedColor = textColor
        lastReportedColorMode = textColorMode
        analytics.recordLaunch(preferences: analyticsPreferences, display: analyticsDisplayState)
        runningDailyReporter.start()
        observeUpdatePreferences()
        PostHogExportLogger.info("desktop app ready", attributes: [
            "event": "desktop_app_ready",
            "daily_updates_enabled": updateDaily
        ])
    }

    func applicationWillTerminate(_ notification: Notification) {
        dailyUpdateScheduler.cancel()
        runningDailyReporter.stop()
        persistColorChanges()
        PostHogConfiguration.flush()
    }

    private func registerAtLogin() {
        let service = SMAppService.mainApp
        let defaults = UserDefaults.standard
        // Respect a later user decision to disable the item in System Settings.
        if !defaults.bool(forKey: "loginRegistrationAttempted") {
            do {
                try service.register()
                defaults.set(true, forKey: "loginRegistrationAttempted")
            } catch {
                analytics.recordLoginFailure(error, operation: .automaticRegistration)
                logger.error("Login registration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        logger.info("Login item status: \(service.status.rawValue)")
        updateLoginItemMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateDateFormatMenu()
        updateLoginItemMenu()
        analytics.recordPreferencesChanged(analyticsPreferences)
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === dateFormatMenu else { return }
        updateDateFormatMenu(highlightedItem: item)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return updaterController.updater.canCheckForUpdates
        }
        return menuItem.action != #selector(toggleUpdateDaily(_:)) || customText == nil
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        analytics.recordUpdatesChecked()
        PostHogExportLogger.info("manual update check requested", attributes: [
            "event": "update_check_requested",
            "source": "manual"
        ])
        updaterController.checkForUpdates(sender)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        updateCycleActive = true
        updateFound = false
        updateDownloadCancelled = false
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateFound = true
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        updateDownloadCancelled = true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard updateCycleActive else { return }
        updateCycleActive = false
        let outcome = Self.updateOutcome(error: error, foundUpdate: updateFound, cancelled: updateDownloadCancelled)
        analytics.recordUpdateCheckCompleted(source: updateCheck, outcome: outcome)
        if let error { analytics.recordUpdateFailure(error, check: updateCheck) }
        updateFound = false
        updateDownloadCancelled = false
    }

    // Sparkle finishes some dismissed or deferred cycles without an error. Only
    // positive callbacks or bounded error codes establish a specific result.
    static func updateOutcome(error: Error?, foundUpdate: Bool, cancelled: Bool) -> AppAnalytics.UpdateOutcome {
        if cancelled { return .cancelled }
        guard let error else { return foundUpdate ? .updateAvailable : .unknown }
        var current = error as NSError
        for _ in 0..<5 {
            if current.domain == NSURLErrorDomain && current.code == NSURLErrorCancelled { return .cancelled }
            if current.domain == SUSparkleErrorDomain {
                switch current.code {
                case Int(SUError.installationCanceledError.rawValue): return .cancelled
                case Int(SUError.installationAuthorizeLaterError.rawValue): return foundUpdate ? .updateAvailable : .unknown
                case Int(SUError.noUpdateError.rawValue):
                    let reason = (current.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
                    return reason == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
                        || reason == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) ? .upToDate : .unknown
                default: break
                }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return .failed
    }

    private func updateDateFormatMenu(highlightedItem: NSMenuItem? = nil) {
        for item in dateFormatMenu?.items ?? [] {
            if let value = item.representedObject as? String, let format = DateDisplayFormat(rawValue: value) {
                let preview = format.string(from: updatedAt, includeTime: includeTime)
                let title = NSMutableAttributedString(string: format.title)
                title.append(NSAttributedString(string: " — \(preview)", attributes: [
                    .foregroundColor: item === highlightedItem ? NSColor.selectedMenuItemTextColor : NSColor.secondaryLabelColor
                ]))
                item.attributedTitle = title
                item.state = customText == nil && dateFormat == format ? .on : .off
            } else if item.action == #selector(toggleIncludeTime) {
                item.state = includeTime || dateFormat.alwaysIncludesTime ? .on : .off
                item.isEnabled = !dateFormat.alwaysIncludesTime
            } else if item.action == #selector(toggleRandomizeFormat) {
                item.state = randomizeFormat ? .on : .off
            }
        }
    }

    @objc private func selectDateFormat(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let format = DateDisplayFormat(rawValue: value) else { return }
        let previous = analyticsDisplayState
        dateFormat = format
        UserDefaults.standard.set(format.rawValue, forKey: "dateFormat")
        clearCustomText()
        renderTimestamp(reason: "date-format-changed")
        if analyticsDisplayState != previous {
            analytics.recordDisplaySettingChanged(.dateFormat, previous: previous, display: analyticsDisplayState)
        }
    }

    @objc private func toggleIncludeTime() {
        guard !dateFormat.alwaysIncludesTime else { return }
        let previous = analyticsDisplayState
        includeTime.toggle()
        UserDefaults.standard.set(includeTime, forKey: "includeTime")
        clearCustomText()
        renderTimestamp(reason: "include-time-changed")
        analytics.recordDisplaySettingChanged(.includeTime, previous: previous, display: analyticsDisplayState)
    }

    @objc private func toggleUpdateDaily(_ sender: NSMenuItem) {
        guard customText == nil else { return }
        let previous = analyticsDisplayState
        updateDaily.toggle()
        UserDefaults.standard.set(updateDaily, forKey: "updateDaily")
        sender.state = updateDaily ? .on : .off
        dailyUpdateScheduler.schedule(enabled: updateDaily)
        positionArtwork()
        analytics.recordDisplaySettingChanged(.updateDaily, previous: previous, display: analyticsDisplayState)
    }

    @objc private func toggleRandomizeFormat() {
        let previous = analyticsDisplayState
        randomizeFormat.toggle()
        UserDefaults.standard.set(randomizeFormat, forKey: "randomizeFormat")
        if randomizeFormat {
            clearCustomText()
            refreshTimestamp(reason: .randomizationEnabled)
        } else {
            updateDateFormatMenu()
            positionArtwork()
        }
        analytics.recordDisplaySettingChanged(.randomizeFormat, previous: previous, display: analyticsDisplayState)
    }

    private var analyticsDisplayState: AppAnalytics.DisplayState {
        .init(dateFormat: dateFormat, includeTime: includeTime, updateDaily: updateDaily,
              randomizeFormat: randomizeFormat, isCustomText: customText != nil)
    }

    private var analyticsPreferences: AppAnalytics.Preferences {
        let loginStatus: AppAnalytics.LoginStatus
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = .enabled
        case .notRegistered: loginStatus = .disabled
        case .requiresApproval: loginStatus = .requiresApproval
        case .notFound: loginStatus = .notFound
        @unknown default: loginStatus = .unknown
        }
        let updater = updaterController.updater
        return .init(loginStatus: loginStatus,
                     automaticUpdateChecks: updater.automaticallyChecksForUpdates,
                     automaticUpdates: updater.automaticallyDownloadsUpdates)
    }

    private func observeUpdatePreferences() {
        let updater = updaterController.updater
        updatePreferenceObservations = [
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.analytics.recordPreferencesChanged(self.analyticsPreferences)
                }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.analytics.recordPreferencesChanged(self.analyticsPreferences)
                }
            }
        ]
    }

    private func updateLoginItemMenu() {
        statusItem?.menu?.items.first(where: { $0.action == #selector(toggleOpenAtLogin(_:)) })?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleOpenAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        let operation: AppAnalytics.LoginOperation = service.status == .enabled ? .disable : .enable
        defer {
            updateLoginItemMenu()
            analytics.recordPreferencesChanged(analyticsPreferences)
        }
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                // macOS requires the user to grant or restore consent in Settings.
                SMAppService.openSystemSettingsLoginItems()
                return
            default:
                try service.register()
            }
            UserDefaults.standard.set(true, forKey: "loginRegistrationAttempted")
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            analytics.recordLoginFailure(error, operation: operation)
            logger.error("Could not change login item: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Could Not Change Open at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func refreshTimestamp(reason: AppAnalytics.RefreshReason, allowRandomization: Bool = true) {
        let previousFormat = dateFormat
        updatedAt = Date()
        if randomizeFormat && allowRandomization {
            dateFormat = dateFormat.randomAlternative()
            UserDefaults.standard.set(dateFormat.rawValue, forKey: "dateFormat")
        }
        renderTimestamp(reason: reason.rawValue)
        dailyUpdateScheduler.schedule(enabled: updateDaily && customText == nil, now: updatedAt)
        if randomizeFormat && allowRandomization {
            analytics.recordFormatRandomized(reason: reason, previousFormat: previousFormat, display: analyticsDisplayState)
        }
        analytics.recordTimestampRefresh(reason: reason, previousFormat: previousFormat, display: analyticsDisplayState)
    }

    private func renderTimestamp(reason: String) {
        self.reason = reason
        timestamp = dateFormat.string(from: updatedAt, includeTime: includeTime)
        updateDateFormatMenu()
        positionArtwork()
    }

    private func positionArtwork() {
        statusItem?.menu?.items.first(where: { $0.action == #selector(showCustomText) })?.state = customText == nil ? .off : .on
        statusItem?.menu?.items.first(where: { $0.action == #selector(toggleUpdateDaily(_:)) })?.isEnabled = customText == nil
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
                                            height: screen.frame.height * 0.50)
        // Even point dimensions avoid asymmetric frame rounding by NSWindow.
        // The glyph bounds fit within 75% of display width and 50% of height.
        let size = NSSize(width: ceil((artwork.inkBounds.width + 4) / 2) * 2,
                          height: ceil((artwork.inkBounds.height + 4) / 2) * 2)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2, width: size.width, height: size.height)
        window.setFrame(frame, display: false)
        view.textColor = textColor
        view.artwork = artwork
        window.orderFrontRegardless()
        writeDiagnostics(screen: screen, artwork: artwork)
        logger.info("Timestamp updated: \(self.timestamp, privacy: .public), reason: \(self.reason, privacy: .public)")
    }

    private func writeDiagnostics(screen: NSScreen, artwork: TimestampArtwork) {
        guard let window else { return }
        let values: [String: Any] = [
            "timestamp": timestamp,
            "dateFormat": dateFormat.rawValue,
            "includeTime": includeTime || dateFormat.alwaysIncludesTime,
            "updateDaily": updateDaily,
            "randomizeFormat": randomizeFormat,
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
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("On Screen")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        } catch {
            logger.error("Could not write diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func didWake() {
        runningDailyReporter.resume()
        refreshTimestamp(reason: .wake)
        analytics.recordWake(preferences: analyticsPreferences, display: analyticsDisplayState)
    }
    @objc private func willSleep() {
        dailyUpdateScheduler.cancel()
        runningDailyReporter.suspend()
    }
    @objc private func clockChanged() {
        runningDailyReporter.clockChanged()
        guard updateDaily && customText == nil else { return }
        refreshTimestamp(reason: .clockChanged)
    }
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let credits = NSAttributedString(string: "onscreen.ericprice.info", attributes: [
            .link: URL(string: "https://onscreen.ericprice.info")!,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: paragraphStyle
        ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: "",
            .credits: credits
        ])
        for window in NSApp.windows where window.isVisible {
            if let view = window.contentView, aboutLinkTracker.install(in: view) { break }
        }
        analytics.recordAboutOpened()
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
        let previousText = customText
        let previousTimestamp = timestamp
        if field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clearCustomText()
            refreshTimestamp(reason: .customTextCleared)
        } else {
            customText = field.stringValue
            UserDefaults.standard.set(customText, forKey: "customText")
            dailyUpdateScheduler.cancel()
            positionArtwork()
        }
        if customText != previousText || (customText == nil && timestamp != previousTimestamp) {
            analytics.recordTextChanged(display: analyticsDisplayState)
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
        dailyUpdateScheduler.schedule(enabled: updateDaily)
    }

    @objc private func resetTimestamp() {
        let previousText = customText
        clearCustomText()
        refreshTimestamp(reason: .reset, allowRandomization: previousText != nil)
    }
    @objc private func selectTextColor(_ sender: NSMenuItem) {
        guard let mode = TextColorMode(rawValue: sender.tag) else { return }
        textColorMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "textColorMode")
        for item in sender.menu?.items ?? [] where item.action == #selector(selectTextColor(_:)) {
            item.state = mode.rawValue == item.tag ? .on : .off
        }
        pendingColorAnalytics = true
        updateArtworkColor()
        if mode == .custom {
            let panel = NSColorPanel.shared
            panel.title = "Custom Text Color"
            panel.showsAlpha = false
            panel.isContinuous = true
            panel.color = customColor
            panel.setTarget(self)
            panel.setAction(#selector(customColorChanged(_:)))
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else if NSColorPanel.sharedColorPanelExists {
            NSColorPanel.shared.orderOut(nil)
        }
    }
    @objc private func customColorChanged(_ sender: NSColorPanel) {
        guard textColorMode == .custom,
              let color = sender.color.usingColorSpace(.sRGB) else { return }
        customColor = color.withAlphaComponent(1)
        pendingColorAnalytics = true
        updateArtworkColor()
    }

    private func updateArtworkColor() {
        (window?.contentView as? TimestampView)?.textColor = textColor
        // Keep live feedback immediate, but save only once a drag has paused.
        colorPersistenceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistColorChanges() }
        }
        colorPersistenceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func persistColorChanges() {
        guard let timer = colorPersistenceTimer else { return }
        timer.invalidate()
        colorPersistenceTimer = nil
        if pendingColorAnalytics {
            pendingColorAnalytics = false
            if textColorMode != lastReportedColorMode || textColor != lastReportedColor {
                let mode: AppAnalytics.ColorMode
                switch textColorMode {
                case .white: mode = .white
                case .black: mode = .black
                case .custom: mode = .custom
                }
                analytics.recordColorChanged(color: textColor, mode: mode)
                lastReportedColor = textColor
                lastReportedColorMode = textColorMode
            }
        }
        if let color = customColor.usingColorSpace(.sRGB) {
            UserDefaults.standard.set([color.redComponent, color.greenComponent, color.blueComponent], forKey: "customColor")
        }
        if let screen = window?.screen,
           let artwork = (window?.contentView as? TimestampView)?.artwork {
            writeDiagnostics(screen: screen, artwork: artwork)
        }
    }
    @objc private func displaysChanged() { positionArtwork() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

/// Observe the stock About panel's fixed website link and retain AppKit's handling.
@MainActor
final class AboutWebsiteLinkTracker: NSObject, NSTextViewDelegate {
    private let onClick: () -> Void
    // Objective-C forwarding is nonisolated; AppKit invokes these hooks on the main actor.
    nonisolated(unsafe) private weak var originalDelegate: (any NSTextViewDelegate)?
    private static let website = URL(string: "https://onscreen.ericprice.info")!

    init(onClick: @escaping () -> Void) { self.onClick = onClick }

    @discardableResult
    func install(in view: NSView) -> Bool {
        if let textView = view as? NSTextView, let storage = textView.textStorage {
            var containsWebsite = false
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                if Self.url(from: value) == Self.website {
                    containsWebsite = true
                    stop.pointee = true
                }
            }
            if containsWebsite {
                if textView.delegate !== self {
                    originalDelegate = textView.delegate
                    textView.delegate = self
                }
                return true
            }
        }
        return view.subviews.contains { install(in: $0) }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if Self.url(from: link) == Self.website { onClick() }
        return originalDelegate?.textView?(textView, clickedOnLink: link, at: charIndex) ?? false
    }

    override nonisolated func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return MainActor.assumeIsolated { originalDelegate?.responds(to: selector) ?? false }
    }

    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
        MainActor.preconditionIsolated()
        return originalDelegate
    }

    private static func url(from value: Any?) -> URL? {
        if let url = value as? URL { return url }
        return (value as? String).flatMap(URL.init(string:))
    }
}
