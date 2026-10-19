import Foundation

/// Reports observed running presence, without measuring foreground use or duration.
@MainActor
final class AppRunningDailyReporter {
    enum Trigger: String {
        case launch, wake
        case dailyBoundary = "daily_boundary"
        case clockChange = "clock_change"
        case consentEnabled = "consent_enabled"
    }

    private static let lastDayKey = "analyticsLastRunningUTCDay"
    private static let secondsPerDay: TimeInterval = 86_400

    private let defaults: UserDefaults
    private let now: () -> Date
    private let enabled: () -> Bool
    private let record: (Trigger) -> Void
    private var preferenceObserver: NSObjectProtocol?
    private var isStarted = false
    private var isAwake = false
    private var wasEnabled = false
    private(set) var timer: Timer?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        enabled: @escaping () -> Bool,
        record: @escaping (Trigger) -> Void
    ) {
        self.defaults = defaults
        self.now = now
        self.enabled = enabled
        self.record = record
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        isAwake = true
        wasEnabled = enabled()
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.consentChanged() }
        }
        recordIfNeeded(trigger: .launch)
        schedule()
    }

    func resume() {
        guard isStarted else { return }
        isAwake = true
        wasEnabled = enabled()
        recordIfNeeded(trigger: .wake)
        schedule()
    }

    func suspend() {
        isAwake = false
        cancelTimer()
    }

    func clockChanged() {
        guard isStarted else { return }
        recordIfNeeded(trigger: .clockChange)
        schedule()
    }

    func stop() {
        isStarted = false
        isAwake = false
        cancelTimer()
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
            self.preferenceObserver = nil
        }
    }

    private func consentChanged() {
        guard isStarted else { return }
        let isEnabled = enabled()
        let becameEnabled = isEnabled && !wasEnabled
        // Update before recording because persisting the accepted day can notify observers.
        wasEnabled = isEnabled
        if !isEnabled {
            cancelTimer()
        } else if becameEnabled {
            recordIfNeeded(trigger: .consentEnabled)
            schedule()
        }
    }

    private func recordIfNeeded(trigger: Trigger) {
        guard isStarted, isAwake, enabled() else { return }
        let day = Int(floor(now().timeIntervalSince1970 / Self.secondsPerDay))
        if defaults.object(forKey: Self.lastDayKey) != nil,
           day <= defaults.integer(forKey: Self.lastDayKey) { return }
        // Persist first so synchronous record/defaults callbacks cannot report the day twice.
        defaults.set(day, forKey: Self.lastDayKey)
        record(trigger)
    }

    private func schedule() {
        cancelTimer()
        guard isStarted, isAwake, enabled() else { return }
        let day = floor(now().timeIntervalSince1970 / Self.secondsPerDay)
        let nextBoundary = Date(timeIntervalSince1970: (day + 1) * Self.secondsPerDay + 1)
        let timer = Timer(fire: nextBoundary, interval: 0, repeats: false) { [weak self] firedTimer in
            let timerID = ObjectIdentifier(firedTimer)
            MainActor.assumeIsolated {
                guard let self, self.timer.map(ObjectIdentifier.init) == timerID else { return }
                self.timer = nil
                self.recordIfNeeded(trigger: .dailyBoundary)
                self.schedule()
            }
        }
        timer.tolerance = 60
        self.timer = timer
        // A run-loop timer only runs while the process is awake; it does not wake hardware.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }
}
