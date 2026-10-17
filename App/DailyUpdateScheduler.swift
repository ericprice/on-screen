import Foundation

@MainActor
final class DailyUpdateScheduler {
    private(set) var timer: Timer?
    private let onUpdate: @MainActor () -> Void

    init(onUpdate: @escaping @MainActor () -> Void) {
        self.onUpdate = onUpdate
    }

    static func nextMidnight(after date: Date, timeZone: TimeZone = .current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Calendar boundaries account for short/long days and time-zone changes.
        return calendar.dateInterval(of: .day, for: date)?.end
    }

    func schedule(enabled: Bool, now: Date = Date(), timeZone: TimeZone = .current) {
        cancel()
        guard enabled, let midnight = Self.nextMidnight(after: now, timeZone: timeZone) else { return }
        let timer = Timer(fire: midnight, interval: 0, repeats: false) { [weak self] firedTimer in
            let timerID = ObjectIdentifier(firedTimer)
            MainActor.assumeIsolated {
                guard let self, self.timer.map(ObjectIdentifier.init) == timerID else { return }
                self.timer = nil
                // The refresh captures a new date and schedules the following midnight.
                self.onUpdate()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
