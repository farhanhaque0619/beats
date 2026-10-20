import Foundation

/// IMAP date formats, done by hand so they're fast, locale-proof and identical on every platform.
enum IMAPDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Parses an INTERNALDATE such as `17-Jul-1996 02:44:25 -0700` (day may be space-padded or
    /// one digit; a missing zone means UTC). Nil when it doesn't look like one.
    static func parseInternalDate(_ string: String) -> Date? {
        var reader = DateReader(Array(string.utf8))
        reader.skipSpaces()
        guard let day = reader.number(maxDigits: 2), reader.consume(UInt8(ascii: "-")) else { return nil }
        guard let monthToken = reader.letters(), let monthIndex = months.firstIndex(of: monthToken.lowercased()) else { return nil }
        guard reader.consume(UInt8(ascii: "-")), let year = reader.number(maxDigits: 4) else { return nil }
        reader.skipSpaces()
        guard let hour = reader.number(maxDigits: 2), reader.consume(UInt8(ascii: ":")),
              let minute = reader.number(maxDigits: 2) else { return nil }
        var second = 0
        if reader.consume(UInt8(ascii: ":")) {
            guard let value = reader.number(maxDigits: 2) else { return nil }
            second = value
        }
        reader.skipSpaces()
        var offsetSeconds = 0
        if let sign = reader.peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
            reader.index += 1
            guard let zone = reader.number(maxDigits: 4) else { return nil }
            offsetSeconds = (zone / 100) * 3600 + (zone % 100) * 60
            if sign == UInt8(ascii: "-") { offsetSeconds = -offsetSeconds }
        }
        guard (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second),
              year >= 1900, year <= 9999 else { return nil }
        let days = daysFromCivil(year: year, month: monthIndex + 1, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// `"05-Oct-2026 14:03:09 +0000"`, the form APPEND takes (always UTC).
    static func formatInternalDate(_ date: Date) -> String {
        let total = Int(floor(date.timeIntervalSince1970))
        let days = Int((Double(total) / 86_400).rounded(.down))
        let secondsOfDay = total - days * 86_400
        let (year, month, day) = civilFromDays(days)
        return "\(pad2(day))-\(monthNames[month - 1])-\(year) \(pad2(secondsOfDay / 3600)):\(pad2(secondsOfDay / 60 % 60)):\(pad2(secondsOfDay % 60)) +0000"
    }

    /// `"5-Oct-2026"`, the form SEARCH dates take (the UTC calendar day).
    static func formatSearchDate(_ date: Date) -> String {
        let days = Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
        let (year, month, day) = civilFromDays(days)
        return "\(day)-\(monthNames[month - 1])-\(year)"
    }

    private static func pad2(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    private struct DateReader {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipSpaces() {
            while index < bytes.count, bytes[index] == Byte.space { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func number(maxDigits: Int) -> Int? {
            var value = 0
            var count = 0
            while index < bytes.count, count < maxDigits, Byte.isDigit(bytes[index]) {
                value = value * 10 + Int(bytes[index] - Byte.zero)
                index += 1
                count += 1
            }
            return count > 0 ? value : nil
        }

        mutating func letters() -> String? {
            let start = index
            while index < bytes.count, (bytes[index] | 0x20) >= UInt8(ascii: "a"), (bytes[index] | 0x20) <= UInt8(ascii: "z") { index += 1 }
            return index > start ? String(decoding: bytes[start..<index], as: UTF8.self) : nil
        }
    }
}
