import Foundation

// MARK: - Countdown & Duration Formatter (AIQuota Style)

enum CountdownTextFormatter {
    enum Style: Sendable {
        case full
        case compact
    }

    static func duration(_ seconds: Int, style: Style = .full) -> String {
        let clampedSeconds = max(0, seconds)
        let days = clampedSeconds / 86_400
        let hours = (clampedSeconds % 86_400) / 3_600
        let minutes = (clampedSeconds % 3_600) / 60

        if days > 0 {
            let components = [unit(days, singular: "day", style: style), optionalUnit(hours, singular: "hour", style: style)]
            return join(components, style: style)
        }

        if hours > 0 {
            let components = [unit(hours, singular: "hour", style: style), optionalUnit(minutes, singular: "minute", style: style)]
            return join(components, style: style)
        }

        if minutes > 0 {
            return unit(minutes, singular: "minute", style: style)
        }

        return style == .full ? "less than a minute" : "<1m"
    }

    private static func optionalUnit(_ value: Int, singular: String, style: Style) -> String? {
        value > 0 ? unit(value, singular: singular, style: style) : nil
    }

    private static func unit(_ value: Int, singular: String, style: Style) -> String {
        switch style {
        case .full:
            let plural = value == 1 ? singular : "\(singular)s"
            return "\(value) \(plural)"
        case .compact:
            let suffix: String = switch singular {
            case "day": "d"
            case "hour": "h"
            default: "m"
            }
            return "\(value)\(suffix)"
        }
    }

    private static func join(_ components: [String?], style: Style) -> String {
        let values = components.compactMap { $0 }
        switch style {
        case .full:
            return values.joined(separator: ", ")
        case .compact:
            return values.joined(separator: " ")
        }
    }
}

// MARK: - Calendar Reset Time Text Formatter (AIQuota Style)

enum ResetTimeTextFormatter {
    static func windowCaption(
        _ windowLabel: String,
        resetAt: Date?,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        "\(windowLabel) resets \(resetPhrase(resetAt: resetAt, now: now, calendar: calendar, locale: locale))"
    }

    static func compactWindowCaption(
        _ windowLabel: String,
        resetAt: Date?,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        "\(windowLabel) resets \(compactResetPhrase(resetAt: resetAt, now: now, calendar: calendar, locale: locale))"
    }

    static func resetPhrase(
        resetAt: Date?,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let resetAt, resetAt != .distantFuture, resetAt != .distantPast else {
            return "soon"
        }

        if resetAt <= now {
            return "now"
        }

        let time = timeText(for: resetAt, locale: locale)
        if calendar.isDate(resetAt, inSameDayAs: now) {
            return "Today \(time)"
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(resetAt, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }

        return "\(weekdayAbbrev(for: resetAt, calendar: calendar)) \(time)"
    }

    static func compactResetPhrase(
        resetAt: Date?,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let resetAt, resetAt != .distantFuture, resetAt != .distantPast else {
            return "soon"
        }

        if resetAt <= now {
            return "now"
        }

        let time = timeText(for: resetAt, locale: locale)
        if calendar.isDate(resetAt, inSameDayAs: now) {
            return "today \(time)"
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(resetAt, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }

        return "\(weekdayAbbrev(for: resetAt, calendar: calendar)) \(time)"
    }

    private static func timeText(for date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("j:mm")

        return formatter.string(from: date)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    private static func weekdayAbbrev(for date: Date, calendar: Calendar) -> String {
        switch calendar.component(.weekday, from: date) {
        case 1: return "Sun."
        case 2: return "Mon."
        case 3: return "Tues."
        case 4: return "Wed."
        case 5: return "Thurs."
        case 6: return "Fri."
        case 7: return "Sat."
        default: return ""
        }
    }
}

// MARK: - Date Parser Helpers

enum DateParsingHelper {
    static func parseISO8601(_ string: String?) -> Date? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }

        let iso1 = ISO8601DateFormatter()
        iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso1.date(from: string) { return d }

        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        if let d = iso2.date(from: string) { return d }

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: string) { return d }
        }
        return nil
    }
}
