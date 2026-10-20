import Foundation

/// Something a swipe, button or shortcut can do to a conversation.
public enum SwipeAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case none, archive, trash, toggleRead, flag, snooze, markSpam
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "Nothing"
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .toggleRead: return "Read / Unread"
        case .flag: return "Star"
        case .snooze: return "Snooze"
        case .markSpam: return "Spam"
        }
    }

    public var systemImage: String {
        switch self {
        case .none: return "circle.slash"
        case .archive: return "archivebox.fill"
        case .trash: return "trash.fill"
        case .toggleRead: return "envelope.badge.fill"
        case .flag: return "star.fill"
        case .snooze: return "clock.fill"
        case .markSpam: return "xmark.octagon.fill"
        }
    }

    /// True when the action takes the conversation out of the current list.
    public var removesFromList: Bool {
        switch self {
        case .archive, .trash, .snooze, .markSpam: return true
        case .none, .toggleRead, .flag: return false
        }
    }
}

/// Which action each swipe triggers. "Right" means the finger moves right (revealing the
/// leading edge). "Short" commits past the first threshold, "long" past the second.
public struct SwipeConfiguration: Codable, Hashable, Sendable {
    public var rightShort: SwipeAction
    public var rightLong: SwipeAction
    public var leftShort: SwipeAction
    public var leftLong: SwipeAction

    public init(rightShort: SwipeAction, rightLong: SwipeAction, leftShort: SwipeAction, leftLong: SwipeAction) {
        self.rightShort = rightShort
        self.rightLong = rightLong
        self.leftShort = leftShort
        self.leftLong = leftLong
    }

    /// Swipe right to mark read, keep going to archive; swipe left to snooze, keep going to trash.
    public static let standard = SwipeConfiguration(rightShort: .toggleRead, rightLong: .archive, leftShort: .snooze, leftLong: .trash)
}

/// A ready-made snooze time.
public struct SnoozeOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// e.g. "Tue 8:00 AM".
    public var detail: String
    public var systemImage: String
    public var date: Date

    public init(id: String, title: String, detail: String, systemImage: String, date: Date) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.date = date
    }
}

public enum SnoozePresets {
    /// Later today, this evening, tomorrow morning, this weekend, next week — whichever make
    /// sense at `now`.
    public static func options(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> [SnoozeOption] {
        var result: [SnoozeOption] = []
        let hour = calendar.component(.hour, from: now)

        func at(_ dayOffset: Int, _ hour: Int, from base: Date = now) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: base))!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE j:mm")
        func detail(_ date: Date) -> String { formatter.string(from: date) }

        if hour < 18 {
            var later = calendar.date(byAdding: .hour, value: 3, to: now)!
            later = calendar.date(bySetting: .minute, value: 0, of: later) ?? later
            if calendar.isDate(later, inSameDayAs: now) {
                result.append(SnoozeOption(id: "later", title: "Later today", detail: detail(later), systemImage: "clock", date: later))
            }
        }
        if hour < 17 {
            let evening = at(0, 18)
            result.append(SnoozeOption(id: "evening", title: "This evening", detail: detail(evening), systemImage: "moon", date: evening))
        }
        let tomorrow = at(1, 8)
        result.append(SnoozeOption(id: "tomorrow", title: "Tomorrow", detail: detail(tomorrow), systemImage: "sunrise", date: tomorrow))

        let weekday = calendar.component(.weekday, from: now) // 1 = Sunday
        if (2...5).contains(weekday) { // Monday–Thursday
            let daysToSaturday = 7 - weekday
            let weekend = at(daysToSaturday, 9)
            result.append(SnoozeOption(id: "weekend", title: "This weekend", detail: detail(weekend), systemImage: "sofa", date: weekend))
        }
        let daysToMonday = ((9 - weekday) % 7 == 0) ? 7 : (9 - weekday) % 7
        let nextWeek = at(daysToMonday, 8)
        result.append(SnoozeOption(id: "nextweek", title: "Next week", detail: detail(nextWeek), systemImage: "calendar", date: nextWeek))
        return result
    }
}
