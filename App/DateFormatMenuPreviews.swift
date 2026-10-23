import AppKit

/// Preview contents change with the captured date/settings, not mouse movement.
@MainActor
final class DateFormatMenuPreviews {
    private struct Context: Equatable {
        let date: Date
        let includeTime: Bool
        let timeZone: TimeZone
    }
    private var context: Context?
    private var titles: [DateDisplayFormat: (normal: NSAttributedString, highlighted: NSAttributedString)] = [:]

    @discardableResult
    func update(date: Date, includeTime: Bool, timeZone: TimeZone = .current) -> Bool {
        let context = Context(date: date, includeTime: includeTime, timeZone: timeZone)
        guard self.context != context else { return false }
        self.context = context
        for format in DateDisplayFormat.allCases {
            let preview = format.string(from: date, timeZone: timeZone, includeTime: includeTime)
            func title(color: NSColor) -> NSAttributedString {
                let value = NSMutableAttributedString(string: format.title)
                value.append(NSAttributedString(string: " — \(preview)", attributes: [.foregroundColor: color]))
                return NSAttributedString(attributedString: value)
            }
            titles[format] = (title(color: .secondaryLabelColor), title(color: .selectedMenuItemTextColor))
        }
        return true
    }

    func title(for format: DateDisplayFormat, highlighted: Bool) -> NSAttributedString? {
        highlighted ? titles[format]?.highlighted : titles[format]?.normal
    }
}
