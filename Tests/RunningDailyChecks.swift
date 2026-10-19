import Foundation

@main
enum RunningDailyChecks {
    @MainActor static func main() {
        let domain = "info.ericprice.on-screen.running-daily-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let key = "analyticsLastRunningUTCDay"
        let parser = ISO8601DateFormatter()
        func date(_ value: String) -> Date { parser.date(from: value)! }
        func utcDay(_ value: Date) -> Int { Int(floor(value.timeIntervalSince1970 / 86_400)) }
        func notifyPreferences() {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        var instant = date("2030-06-20T12:00:00Z")
        var isEnabled = true
        var triggers: [AppRunningDailyReporter.Trigger] = []
        let reporter = AppRunningDailyReporter(defaults: defaults, now: { instant }, enabled: { isEnabled }) { trigger in
            expect(defaults.integer(forKey: key) == utcDay(instant), "Persist the accepted day before recording")
            triggers.append(trigger)
            // A synchronous defaults callback must not duplicate the accepted day.
            notifyPreferences()
        }
        reporter.start()
        expect(triggers == [.launch], "Record launch on the first observed day")
        expect(reporter.timer?.fireDate == date("2030-06-21T00:00:01Z"), "Schedule one second after the next UTC boundary")
        expect(reporter.timer?.tolerance == 60, "Use a coarse daily timer tolerance")
        let initialTimer = reporter.timer!
        reporter.start()
        expect(triggers == [.launch] && reporter.timer === initialTimer, "Repeated start must be idempotent")
        reporter.resume()
        reporter.clockChanged()
        expect(triggers.count == 1, "Wake and clock notifications must deduplicate the same UTC day")

        instant = date("2030-06-21T00:00:01Z")
        let boundaryTimer = reporter.timer!
        boundaryTimer.fire()
        expect(triggers == [.launch, .dailyBoundary], "A running process records a new UTC day")
        expect(reporter.timer?.fireDate == date("2030-06-22T00:00:01Z"), "A daily tick schedules the following boundary")
        boundaryTimer.fire()
        expect(triggers.count == 2, "A stale timer cannot duplicate a report")

        reporter.suspend()
        expect(reporter.timer == nil, "Sleep cancels the timer")
        instant = date("2030-06-25T14:00:00Z")
        reporter.clockChanged()
        expect(triggers.count == 2 && defaults.integer(forKey: key) == utcDay(date("2030-06-21T00:00:01Z")), "Suspended processes neither record nor advance the accepted day")
        reporter.resume()
        expect(triggers == [.launch, .dailyBoundary, .wake], "Wake records only the currently observed day, without backfill")
        expect(defaults.integer(forKey: key) == utcDay(instant), "Wake persists only the current day")

        instant = date("2030-06-23T12:00:00Z")
        reporter.clockChanged()
        reporter.resume()
        expect(triggers.count == 3 && defaults.integer(forKey: key) == utcDay(date("2030-06-25T14:00:00Z")), "A backward clock change cannot repeat or lower the accepted day")
        instant = date("2030-06-25T23:00:00Z")
        reporter.clockChanged()
        expect(triggers.count == 3, "Returning to the accepted day still cannot duplicate it")
        instant = date("2030-06-26T00:00:01Z")
        reporter.clockChanged()
        expect(triggers.last == .clockChange && triggers.count == 4, "A clock change into a genuinely new day can record")

        isEnabled = false
        notifyPreferences()
        expect(reporter.timer == nil, "Opting out cancels the pending timer")
        let acceptedBeforeOptOut = defaults.integer(forKey: key)
        instant = date("2030-06-28T12:00:00Z")
        reporter.resume()
        reporter.clockChanged()
        notifyPreferences()
        expect(triggers.count == 4 && defaults.integer(forKey: key) == acceptedBeforeOptOut, "Opt-out makes no reports or day bookkeeping")
        isEnabled = true
        notifyPreferences()
        expect(triggers.last == .consentEnabled && triggers.count == 5, "Enabling consent records the current day only")
        expect(reporter.timer != nil, "Enabling consent schedules future presence checks")
        notifyPreferences()
        expect(triggers.count == 5, "Unrelated defaults changes cannot duplicate the consent report")
        isEnabled = false
        notifyPreferences()
        isEnabled = true
        notifyPreferences()
        expect(triggers.count == 5, "Consent toggles within the accepted day remain deduplicated")

        reporter.suspend()
        instant = date("2030-06-29T12:00:00Z")
        isEnabled = false
        notifyPreferences()
        isEnabled = true
        notifyPreferences()
        expect(triggers.count == 5 && reporter.timer == nil, "Enabling consent during suspension cannot claim awake presence")
        reporter.resume()
        expect(triggers.last == .wake && triggers.count == 6, "Resuming after suspended consent records wake once")

        instant = date("2030-07-04T12:00:00Z")
        reporter.timer!.fire()
        expect(triggers.last == .dailyBoundary && triggers.count == 7, "A delayed timer reports only the current day, without backfill")
        let stoppedTimer = reporter.timer!
        reporter.stop()
        reporter.stop()
        expect(reporter.timer == nil && !stoppedTimer.isValid, "Stop is idempotent and invalidates the timer")
        instant = date("2030-07-05T12:00:00Z")
        isEnabled = false
        notifyPreferences()
        isEnabled = true
        notifyPreferences()
        reporter.resume()
        reporter.clockChanged()
        stoppedTimer.fire()
        expect(triggers.count == 7 && reporter.timer == nil, "Stopped reporters cannot respond to defaults, wake, clocks, or stale timers")

        instant = date("2030-07-04T23:00:00Z")
        var relaunched: [AppRunningDailyReporter.Trigger] = []
        let nextProcess = AppRunningDailyReporter(defaults: defaults, now: { instant }, enabled: { isEnabled }) { relaunched.append($0) }
        nextProcess.start()
        expect(relaunched.isEmpty, "Persisted UTC day deduplicates a same-day relaunch")
        instant = date("2030-07-06T00:00:01Z")
        nextProcess.resume()
        expect(relaunched == [.wake], "A relaunched process still accepts the next observed day")
        nextProcess.stop()

        defaults.removeObject(forKey: key)
        isEnabled = false
        var firstConsent: [AppRunningDailyReporter.Trigger] = []
        let optedOutStart = AppRunningDailyReporter(defaults: defaults, now: { instant }, enabled: { isEnabled }) { firstConsent.append($0) }
        optedOutStart.start()
        expect(firstConsent.isEmpty && optedOutStart.timer == nil && defaults.object(forKey: key) == nil, "An opted-out launch creates no report, timer, or accepted-day key")
        instant = date("2030-07-10T12:00:00Z")
        isEnabled = true
        notifyPreferences()
        expect(firstConsent == [.consentEnabled] && defaults.integer(forKey: key) == utcDay(instant), "First consent after multiple opted-out days reports only today")
        optedOutStart.stop()

        expect(AppRunningDailyReporter.Trigger.dailyBoundary.rawValue == "daily_boundary"
               && AppRunningDailyReporter.Trigger.clockChange.rawValue == "clock_change"
               && AppRunningDailyReporter.Trigger.consentEnabled.rawValue == "consent_enabled", "Trigger values remain fixed")
        print("PASS: \(checks) running-daily checks covering UTC boundaries, relaunch/wake deduplication, delayed timers, backward clocks, consent, reentrancy, sleep, and cleanup.")
    }
}
