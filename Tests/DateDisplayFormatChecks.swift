import Foundation
import CoreText

@main
enum DateDisplayFormatChecks {
    @MainActor static func main() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let parser = ISO8601DateFormatter()
        func date(_ text: String) -> Date { parser.date(from: text)! }
        let sample = date("2026-06-20T12:00:00Z")
        var checks = 0
        func expect(_ format: DateDisplayFormat, _ expected: String, at instant: Date? = nil,
                    zone: TimeZone? = nil, time: Bool = false) {
            let actual = format.string(from: instant ?? sample, timeZone: zone ?? utc, includeTime: time)
            precondition(actual == expected, "\(format): expected \(expected), got \(actual)")
            checks += 1
        }
        let samples: [(DateDisplayFormat, String)] = [
            (.iso8601, "2026-06-20"),
            (.monthDayYear, "06/20/2026"), (.dayMonthYear, "20/06/2026"), (.dotted, "20.06.2026"),
            (.shortMonth, "20 JUN 2026"), (.longMonth, "JUNE 20, 2026"),
            (.fullDate, "SATURDAY, JUNE 20, 2026"), (.kawara, "JUN.20,2026"),
            (.dayOfWeek, "Saturday"), (.dayOfMonth, "20"),
            (.compactISO, "20260620"), (.isoWeek, "2026-W25-6"), (.ordinal, "2026-171"),
            (.romanNumerals, "XX.VI.MMXXVI"), (.romanCountdown, "XII KAL. IVL. MMXXVI"),
            (.julianCalendar, "7 JUN 2026"), (.julianDate, "2461212.000000"),
            (.modifiedJulianDate, "61211.500000"), (.unixTimestamp, "1781956800"),
            (.binary, "11111101010-110-10100"), (.hexadecimal, "07EA-06-14")
        ]
        precondition(samples.count == DateDisplayFormat.allCases.count)
        for (format, expected) in samples {
            expect(format, expected)
            if format.alwaysIncludesTime {
                expect(format, expected, time: true)
            } else if [.monthDayYear, .dayMonthYear, .dotted, .shortMonth, .longMonth, .fullDate, .kawara, .julianCalendar, .dayOfWeek, .dayOfMonth].contains(format) {
                expect(format, expected + " 12:00PM", time: true)
            } else if ![.iso8601, .isoWeek, .ordinal, .compactISO].contains(format) {
                expect(format, expected + " 12:00:00", time: true)
            }
        }
        expect(.iso8601, "2026-06-20T12:00:00Z", time: true)
        expect(.isoWeek, "2026-W25-6T12:00:00Z", time: true)
        expect(.ordinal, "2026-171T12:00:00Z", time: true)
        expect(.compactISO, "20260620T120000Z", time: true)

        // ISO week years differ from calendar years around New Year.
        expect(.isoWeek, "2020-W53-5", at: date("2021-01-01T12:00:00Z"))
        expect(.isoWeek, "2019-W01-1", at: date("2018-12-31T12:00:00Z"))
        expect(.ordinal, "2024-060", at: date("2024-02-29T12:00:00Z"))
        expect(.ordinal, "2023-365", at: date("2023-12-31T12:00:00Z"))

        // Nones/Ides, inclusive counting, leap February, and next-year Kalends.
        for (day, expected) in [("2026-03-01", "KAL. MAR. MMXXVI"), ("2026-03-06", "PRID. NON. MAR. MMXXVI"),
                                ("2026-03-07", "NON. MAR. MMXXVI"), ("2026-03-15", "ID. MAR. MMXXVI"),
                                ("2026-04-13", "ID. APR. MMXXVI"), ("2024-02-28", "III KAL. MAR. MMXXIV"),
                                ("2024-02-29", "PRID. KAL. MAR. MMXXIV"), ("2026-12-31", "PRID. KAL. IAN. MMXXVII")] {
            expect(.romanCountdown, expected, at: date(day + "T12:00:00Z"))
        }
        expect(.kawara, "JAN.4,2026", at: date("2026-01-04T12:00:00Z"))
        expect(.julianCalendar, "19 DEC 1999", at: date("2000-01-01T12:00:00Z"))
        expect(.julianCalendar, "1 MAR 1900", at: date("1900-03-14T12:00:00Z"))
        expect(.julianCalendar, "1 MAR 2100", at: date("2100-03-15T12:00:00Z"))
        expect(.julianDate, "2451545.000000", at: date("2000-01-01T12:00:00Z"))
        expect(.modifiedJulianDate, "0.000000", at: date("1858-11-17T00:00:00Z"))
        expect(.unixTimestamp, "0", at: date("1970-01-01T00:00:00Z"))
        expect(.unixTimestamp, "-1", at: Date(timeIntervalSince1970: -0.1))

        let ny = TimeZone(identifier: "America/New_York")!
        expect(.iso8601, "2026-06-20T08:00:00-04:00", zone: ny, time: true)
        expect(.compactISO, "20260620T080000-0400", zone: ny, time: true)
        expect(.iso8601, "2026-03-08T01:59:59-05:00", at: date("2026-03-08T06:59:59Z"), zone: ny, time: true)
        expect(.iso8601, "2026-03-08T03:00:00-04:00", at: date("2026-03-08T07:00:00Z"), zone: ny, time: true)
        expect(.iso8601, "2026-06-20T17:45:00+05:45", zone: TimeZone(identifier: "Asia/Kathmandu")!, time: true)
        let la = TimeZone(identifier: "America/Los_Angeles")!
        expect(.isoWeek, "2020-W53-7", at: date("2021-01-04T01:00:00Z"), zone: la)
        expect(.julianCalendar, "6 JUN 2026 6:00PM", at: date("2026-06-20T01:00:00Z"), zone: la, time: true)
        for format in DateDisplayFormat.allCases where format.alwaysIncludesTime {
            expect(format, format.string(from: sample, timeZone: utc), zone: ny)
        }

        // Casual time omits seconds and leading zeros, including at midnight/noon.
        expect(.kawara, "JUN.20,2026 4:57PM", at: date("2026-06-20T20:57:15Z"), zone: ny, time: true)
        expect(.kawara, "JUN.20,2026 12:00AM", at: date("2026-06-20T04:00:59Z"), zone: ny, time: true)
        expect(.kawara, "JUN.20,2026 12:00PM", at: date("2026-06-20T16:00:15Z"), zone: ny, time: true)
        expect(.kawara, "JUN.20,2026 9:05AM", at: date("2026-06-20T13:05:59Z"), zone: ny, time: true)
        expect(.kawara, "JUN.19,2026 11:59PM", at: date("2026-06-20T03:59:59Z"), zone: ny, time: true)
        let october = date("2026-10-17T21:09:15Z")
        expect(.dayOfWeek, "Saturday 5:09PM", at: october, zone: ny, time: true)
        expect(.dayOfMonth, "17 5:09PM", at: october, zone: ny, time: true)
        expect(.dayOfMonth, "1", at: date("2026-11-01T12:00:00Z"))
        expect(.dayOfWeek, "Sunday", at: date("2026-10-18T04:00:00Z"), zone: ny)
        expect(.dayOfMonth, "18 12:00AM", at: date("2026-10-18T04:00:00Z"), zone: ny, time: true)

        for format in DateDisplayFormat.allCases {
            let alternative = format.randomAlternative()
            precondition(alternative != format && DateDisplayFormat.allCases.contains(alternative))
            checks += 1
        }

        // Midnight follows local calendar boundaries, including 23/25-hour days.
        var scheduleChecks = 0
        func expectMidnight(after instant: String, _ expected: String, zone: TimeZone = utc) {
            precondition(DailyUpdateScheduler.nextMidnight(after: date(instant), timeZone: zone) == date(expected))
            scheduleChecks += 1
        }
        expectMidnight(after: "2026-10-17T23:59:59Z", "2026-10-18T00:00:00Z")
        expectMidnight(after: "2026-10-18T00:00:00Z", "2026-10-19T00:00:00Z")
        expectMidnight(after: "2026-12-31T12:00:00Z", "2027-01-01T00:00:00Z")
        expectMidnight(after: "2024-02-28T12:00:00Z", "2024-02-29T00:00:00Z")
        expectMidnight(after: "2024-02-29T12:00:00Z", "2024-03-01T00:00:00Z")
        expectMidnight(after: "2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", zone: ny)
        expectMidnight(after: "2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z", zone: ny)
        expectMidnight(after: "2026-10-17T18:14:59Z", "2026-10-17T18:15:00Z", zone: TimeZone(identifier: "Asia/Kathmandu")!)
        expectMidnight(after: "2026-10-17T21:09:15Z", "2026-10-18T04:00:00Z", zone: ny)

        var updates = 0
        let scheduler = DailyUpdateScheduler { updates += 1 }
        let future = date("2030-06-20T12:00:00Z")
        scheduler.schedule(enabled: false, now: future)
        precondition(scheduler.timer == nil && updates == 0)
        scheduleChecks += 1
        scheduler.schedule(enabled: true, now: future, timeZone: utc)
        precondition(scheduler.timer?.fireDate == date("2030-06-21T00:00:00Z"))
        scheduleChecks += 1
        let replaced = scheduler.timer!
        scheduler.schedule(enabled: true, now: future, timeZone: ny)
        precondition(!replaced.isValid && scheduler.timer?.fireDate == date("2030-06-21T04:00:00Z"))
        scheduleChecks += 1
        scheduler.timer!.fire()
        precondition(updates == 1 && scheduler.timer == nil)
        scheduleChecks += 1
        scheduler.schedule(enabled: true, now: future, timeZone: utc)
        let cancelled = scheduler.timer!
        scheduler.schedule(enabled: false, now: future)
        cancelled.fire()
        precondition(updates == 1 && scheduler.timer == nil && !cancelled.isValid)
        scheduleChecks += 1
        scheduler.schedule(enabled: true, now: future)
        scheduler.cancel()
        precondition(scheduler.timer == nil)
        scheduleChecks += 1

        // A due one-shot timer actually fires through the main run loop.
        scheduler.schedule(enabled: true, now: date("2000-01-01T12:00:00Z"), timeZone: utc)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(updates == 2 && scheduler.timer == nil)
        scheduleChecks += 1

        let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ISO8601Kawara-Regular.otf")
        precondition(CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil))
        let font = CTFontCreateWithName("ISO8601Kawara-Regular" as CFString, 100, nil)
        let characters = CTFontCopyCharacterSet(font)
        var renderingChecks = 0
        for format in DateDisplayFormat.allCases {
            for time in [false, true] {
                for zone in [utc, ny, TimeZone(identifier: "Asia/Kathmandu")!] {
                    let text = format.string(from: sample, timeZone: zone, includeTime: time)
                    precondition(text.unicodeScalars.allSatisfy { CFCharacterSetIsLongCharacterMember(characters, $0.value) }, "Missing glyph in \(text)")
                    let artwork = TimestampArtwork.make(text, width: 1200, height: 360)
                    precondition(artwork.inkBounds.width > 0 && artwork.inkBounds.width <= 1200.01)
                    precondition(artwork.inkBounds.height > 0 && artwork.inkBounds.height <= 360.01)
                    for run in CTLineGetGlyphRuns(artwork.line) as! [CTRun] {
                        let attributes = CTRunGetAttributes(run) as NSDictionary
                        let runFont = attributes[kCTFontAttributeName] as! CTFont
                        precondition(CTFontCopyPostScriptName(runFont) as String == "ISO8601Kawara-Regular", "Font fallback in \(text)")
                    }
                    renderingChecks += 1
                }
            }
        }
        print("Passed \(checks) date-format checks, \(scheduleChecks) scheduling checks, and \(renderingChecks) font/layout checks.")
    }
}
