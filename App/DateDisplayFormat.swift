import Foundation

enum DateDisplayFormat: String, CaseIterable {
    case iso8601, monthDayYear, dayMonthYear, dotted
    case shortMonth, longMonth, fullDate, kawara, dayOfWeek, dayOfMonth
    case compactISO, isoWeek, ordinal, romanNumerals, romanCountdown
    case julianCalendar, julianDate, modifiedJulianDate, unixTimestamp, binary, hexadecimal

    var title: String {
        switch self {
        case .iso8601: "ISO 8601"
        case .monthDayYear: "Month/Day/Year"
        case .dayMonthYear: "Day/Month/Year"
        case .dotted: "Dotted"
        case .shortMonth: "Short Month"
        case .longMonth: "Long Month"
        case .fullDate: "Full Date"
        case .kawara: "Kawara"
        case .dayOfWeek: "Day of Week"
        case .dayOfMonth: "Day of Month"
        case .compactISO: "Compact ISO"
        case .isoWeek: "ISO Week"
        case .ordinal: "Ordinal Date"
        case .romanNumerals: "Roman Numerals"
        case .romanCountdown: "Roman Countdown"
        case .julianCalendar: "Julian Calendar"
        case .julianDate: "Astronomical Julian Date"
        case .modifiedJulianDate: "Modified Julian Date"
        case .unixTimestamp: "Unix Timestamp"
        case .binary: "Binary"
        case .hexadecimal: "Hexadecimal"
        }
    }

    var alwaysIncludesTime: Bool {
        switch self {
        case .julianDate, .modifiedJulianDate, .unixTimestamp: true
        default: false
        }
    }

    var usesCasualTime: Bool {
        switch self {
        case .monthDayYear, .dayMonthYear, .dotted, .shortMonth, .longMonth, .fullDate, .kawara, .julianCalendar, .dayOfWeek, .dayOfMonth: true
        default: false
        }
    }

    func randomAlternative() -> DateDisplayFormat {
        Self.allCases.filter { $0 != self }.randomElement() ?? self
    }

    func string(from date: Date, timeZone: TimeZone = .current, includeTime: Bool = false) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        let year = components.year!, month = components.month!, day = components.day!
        let clock = String(format: "%02d:%02d:%02d", components.hour!, components.minute!, components.second!)
        let result: String
        switch self {
        case .iso8601:
            result = String(format: "%04d-%02d-%02d", year, month, day)
        case .monthDayYear:
            result = String(format: "%02d/%02d/%04d", month, day, year)
        case .dayMonthYear:
            result = String(format: "%02d/%02d/%04d", day, month, year)
        case .dotted:
            result = String(format: "%02d.%02d.%04d", day, month, year)
        case .shortMonth:
            result = "\(day) \(Self.shortMonths[month - 1]) \(year)"
        case .longMonth:
            result = "\(Self.months[month - 1]) \(day), \(year)"
        case .fullDate:
            result = "\(Self.weekdays[components.weekday! - 1]), \(Self.months[month - 1]) \(day), \(year)"
        case .kawara:
            result = "\(Self.shortMonths[month - 1]).\(day),\(year)"
        case .dayOfWeek:
            result = Self.weekdays[components.weekday! - 1].capitalized
        case .dayOfMonth:
            result = String(day)
        case .compactISO:
            result = String(format: "%04d%02d%02d", year, month, day)
        case .isoWeek:
            var isoCalendar = Calendar(identifier: .iso8601)
            isoCalendar.timeZone = timeZone
            let week = isoCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear, .weekday], from: date)
            let weekday = (week.weekday! + 5) % 7 + 1
            result = String(format: "%04d-W%02d-%d", week.yearForWeekOfYear!, week.weekOfYear!, weekday)
        case .ordinal:
            result = String(format: "%04d-%03d", year, calendar.ordinality(of: .day, in: .year, for: date)!)
        case .romanNumerals:
            result = "\(Self.roman(day)).\(Self.roman(month)).\(Self.roman(year))"
        case .romanCountdown:
            result = Self.romanCountdown(year: year, month: month, day: day,
                                         daysInMonth: calendar.range(of: .day, in: .month, for: date)!.count)
        case .julianCalendar:
            // Convert the local Gregorian calendar day, rather than the UTC day.
            // Integer Julian day algorithms: USNO, Explanatory Supplement, chapter 15.
            let a = (14 - month) / 12
            let y = year + 4800 - a
            let m = month + 12 * a - 3
            let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
            let c = jdn + 32082
            let d = (4 * c + 3) / 1461
            let e = c - 1461 * d / 4
            let n = (5 * e + 2) / 153
            let julianDay = e - (153 * n + 2) / 5 + 1
            let julianMonth = n + 3 - 12 * (n / 10)
            let julianYear = d - 4800 + n / 10
            result = "\(julianDay) \(Self.shortMonths[julianMonth - 1]) \(julianYear)"
        case .julianDate:
            // UTC-based day counts; six decimal places retain subsecond resolution.
            return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), date.timeIntervalSince1970 / 86400 + 2440587.5)
        case .modifiedJulianDate:
            return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), date.timeIntervalSince1970 / 86400 + 40587)
        case .unixTimestamp:
            return String(Int64(floor(date.timeIntervalSince1970)))
        case .binary:
            result = [year, month, day].map { String($0, radix: 2) }.joined(separator: "-")
        case .hexadecimal:
            result = String(format: "%04X-%02X-%02X", year, month, day)
        }

        guard includeTime else { return result }
        switch self {
        case .iso8601, .isoWeek, .ordinal:
            return result + "T" + clock + Self.utcOffset(for: date, in: timeZone, colon: true)
        case .compactISO:
            return result + "T" + clock.replacingOccurrences(of: ":", with: "") + Self.utcOffset(for: date, in: timeZone, colon: false)
        default:
            if usesCasualTime {
                let hour = components.hour!
                let displayHour = hour % 12 == 0 ? 12 : hour % 12
                return result + String(format: " %d:%02d%@", displayHour, components.minute!, hour < 12 ? "AM" : "PM")
            }
            return result + " " + clock
        }
    }

    private static func utcOffset(for date: Date, in timeZone: TimeZone, colon: Bool) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        guard seconds != 0 else { return "Z" }
        return String(format: colon ? "%@%02d:%02d" : "%@%02d%02d",
                      seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) / 60 % 60)
    }

    private static func roman(_ number: Int) -> String {
        guard number > 0 else { return String(number) }
        var remainder = number
        var result = ""
        for (value, letters) in [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"),
                                 (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            while remainder >= value {
                result += letters
                remainder -= value
            }
        }
        return result
    }

    private static func romanCountdown(year: Int, month: Int, day: Int, daysInMonth: Int) -> String {
        // Roman inclusive counting applied to the modern Gregorian date.
        // https://dcc.dickinson.edu/grammar/latin/reckoning-time
        let nones = [3, 5, 7, 10].contains(month) ? 7 : 5
        let ides = nones + 8
        let marker: String, count: Int, targetMonth: Int, targetYear: Int
        if day == 1 {
            (marker, count, targetMonth, targetYear) = ("KAL.", 1, month, year)
        } else if day <= nones {
            (marker, count, targetMonth, targetYear) = ("NON.", nones - day + 1, month, year)
        } else if day <= ides {
            (marker, count, targetMonth, targetYear) = ("ID.", ides - day + 1, month, year)
        } else {
            (marker, count, targetMonth, targetYear) = ("KAL.", daysInMonth - day + 2, month % 12 + 1, year + (month == 12 ? 1 : 0))
        }
        let prefix = count == 1 ? "" : count == 2 ? "PRID. " : roman(count) + " "
        return "\(prefix)\(marker) \(romanMonths[targetMonth - 1]) \(roman(targetYear))"
    }

    private static let shortMonths = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    private static let months = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"]
    private static let weekdays = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
    private static let romanMonths = ["IAN.", "FEB.", "MAR.", "APR.", "MAI.", "IVN.", "IVL.", "AVG.", "SEP.", "OCT.", "NOV.", "DEC."]
}
