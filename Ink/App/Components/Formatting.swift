import Foundation

/// Date strings for lists and headers. Formatters are cached: creating them per row would
/// cost frames while scrolling.
enum InkDate {
    private static let time: DateFormatter = make("j:mm")
    private static let weekday: DateFormatter = make("EEE")
    private static let monthDay: DateFormatter = make("MMM d")
    private static let monthDayYear: DateFormatter = make("MMM d, y")
    private static let monthYear: DateFormatter = make("MMMM y")
    private static let month: DateFormatter = make("MMMM")
    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()
    private static let readerFormatter: DateFormatter = make("EEE, MMM d · j:mm")
    private static let weekdayTime: DateFormatter = make("EEE j:mm")

    private static func make(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    /// Trailing timestamp in a list row: "9:41 AM", "Tue", "Oct 3", "Oct 3, 2024".
    static func listTimestamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day {
            if days == 1 { return "Yesterday" }
            if days > 1 && days < 7 { return weekday.string(from: date) }
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return monthDay.string(from: date) }
        return monthDayYear.string(from: date)
    }

    /// When a snoozed conversation comes back, short enough for a row's trailing edge:
    /// "6:00 PM" (today), "Wed 8:00 AM" (this coming week), "Oct 28", "Jan 5, 2027".
    /// `listTimestamp` is for the past and would drop the time of tomorrow's snooze.
    static func snoozeTimestamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days >= 1 && days < 7 { return weekdayTime.string(from: date) }
        if days < 0 { return listTimestamp(date, now: now, calendar: calendar) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return monthDay.string(from: date) }
        return monthDayYear.string(from: date)
    }

    /// Section header for grouping a list by day: "Today", "Yesterday", "This Week", "Last Week",
    /// "Earlier This Month", "October", "March 2024". Weeks follow the calendar, so on a Monday
    /// last Thursday reads "Last Week", not "This Week". Each title covers an older span than the
    /// one before, so newest-first lists never interleave them.
    static func sectionTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        // Mail dated in the future (a sender's clock running fast) belongs with today's.
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "This Week" }
        if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
           calendar.isDate(date, equalTo: lastWeek, toGranularity: .weekOfYear) {
            return "Last Week"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "Earlier This Month" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return month.string(from: date) }
        return monthYear.string(from: date)
    }

    /// "Tue, Oct 14 · 9:41 AM" for message headers in the reader.
    static func reader(_ date: Date) -> String { readerFormatter.string(from: date) }

    /// "Tuesday, October 14, 2026 at 9:41 AM" for the details popover.
    static func full(_ date: Date) -> String { fullFormatter.string(from: date) }
}

enum InkFormat {
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// "1.2 MB".
    static func fileSize(_ count: Int) -> String { bytes.string(fromByteCount: Int64(count)) }

    /// "99+" style badge text.
    static func badge(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }
}
