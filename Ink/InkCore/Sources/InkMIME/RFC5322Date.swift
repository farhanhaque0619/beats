import Foundation

/// RFC 5322 dates, parsed the way real mail writes them.
public enum RFC5322Date {
    /// Parses a Date header value. Accepts the RFC 5322 form plus what mailers actually send:
    /// optional or full day names, missing seconds, single-digit fields, two- and three-digit years,
    /// obsolete and common zone names (`EST`, `PDT`, `GMT`, `UT`, `Z`, `CEST`, …), military zones,
    /// `+02:00`, `GMT+0200`, comments such as `(UTC)`, dashes (`20-Oct-2026`), asctime order
    /// (`Tue Oct 20 09:15:00 2026`), AM/PM and ISO 8601 (`2026-10-20T09:15:00Z`). A missing zone
    /// means UTC. Returns nil when no day, month and year can be found.
    public static func parse(_ s: String) -> Date? {
        let b = stripComments(Array(s.utf8))
        if let iso = parseISO(b) { return iso }
        var fields = Fields()
        var tokens: [ArraySlice<UInt8>] = []
        var i = 0
        while i < b.count {
            while i < b.count && (isASCIIWhitespace(b[i]) || b[i] == ASCII.comma) { i += 1 }
            let start = i
            while i < b.count && !isASCIIWhitespace(b[i]) && b[i] != ASCII.comma { i += 1 }
            if i > start { tokens.append(b[start..<i]) }
        }
        for token in tokens { fields.consume(token) }
        return fields.date()
    }

    /// Formats a date for a Date header in the current time zone: `Tue, 20 Oct 2026 09:15:00 +0200`.
    public static func format(_ d: Date) -> String {
        format(d, timeZone: .current)
    }

    /// Formats a date for a Date header in `timeZone`.
    public static func format(_ d: Date, timeZone: TimeZone) -> String {
        let offset = timeZone.secondsFromGMT(for: d)
        let local = Int64((d.timeIntervalSince1970).rounded(.down)) + Int64(offset)
        var days = local / 86_400
        var secs = local % 86_400
        if secs < 0 { secs += 86_400; days -= 1 }
        let (y, m, day) = civil(fromDays: days)
        let weekday = Int(((days % 7) + 11) % 7)   // 1970-01-01 was a Thursday
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let sign = offset < 0 ? "-" : "+"
        let absOffset = abs(offset) / 60
        return "\(names[weekday]), \(day) \(months[m - 1]) \(y) \(pad(Int(secs / 3600))):\(pad(Int(secs % 3600 / 60))):\(pad(Int(secs % 60))) \(sign)\(pad(absOffset / 60))\(pad(absOffset % 60))"
    }

    static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    // MARK: Fields

    struct Fields {
        var day: Int?
        var month: Int?
        var year: Int?
        var yearDigits = 0
        var hour: Int?
        var minute: Int?
        var second = 0
        var offsetMinutes: Int?
        var pm: Bool?

        mutating func consume(_ token: ArraySlice<UInt8>) {
            guard let first = token.first else { return }
            if isASCIIDigit(first) {
                if token.contains(ASCII.colon) { consumeTime(token); return }
                if token.contains(ASCII.dash) || token.contains(ASCII.slash) || token.contains(ASCII.dot) {
                    // "20-Oct-2026", "20/10/2026" or "20.10.2026"
                    let parts = token.split(whereSeparator: { $0 == ASCII.dash || $0 == ASCII.slash || $0 == ASCII.dot })
                    if parts.count == 3, parts.allSatisfy({ $0.allSatisfy(isASCIIDigit) }), month == nil,
                       let d = number(parts[0]), let mo = number(parts[1]), (1...12).contains(mo) {
                        day = d
                        month = mo
                        setYear(parts[2])
                        return
                    }
                    for part in parts { consume(part) }
                    return
                }
                if token.allSatisfy(isASCIIDigit) { consumeNumber(token) }
                return
            }
            if first == 0x2B || first == ASCII.dash {
                if offsetMinutes == nil, let off = numericOffset(token.dropFirst(), negative: first == ASCII.dash) { offsetMinutes = off }
                return
            }
            let word = String(decoding: token.map(asciiLower), as: UTF8.self)
            if month == nil, let m = RFC5322Date.month(word) { month = m; return }
            if word == "am" || word == "a.m." { pm = false; return }
            if word == "pm" || word == "p.m." { pm = true; return }
            // "GMT+0200", "UTC-5", "UT+02:00"
            for prefix in ["gmt", "utc", "ut"] where word.hasPrefix(prefix) && word.count > prefix.count {
                let rest = token.dropFirst(prefix.count)
                if let sign = rest.first, sign == 0x2B || sign == ASCII.dash, offsetMinutes == nil,
                   let off = numericOffset(rest.dropFirst(), negative: sign == ASCII.dash) {
                    offsetMinutes = off
                }
                return
            }
            if offsetMinutes == nil, let off = RFC5322Date.zones[word] { offsetMinutes = off; return }
            if offsetMinutes == nil, word.count == 1, let c = word.unicodeScalars.first, ("a"..."z").contains(c), c != "j" {
                // Military zones: RFC 5322 §4.3 says to read them as -0000 (RFC 822 had the signs backwards).
                offsetMinutes = 0
            }
        }

        mutating func consumeTime(_ token: ArraySlice<UInt8>) {
            guard hour == nil else { return }
            // Split off a glued zone ("09:15:00+0200", "09:15:00Z").
            var timePart = token
            if let zi = token.firstIndex(where: { $0 == 0x2B || $0 == ASCII.dash }) {
                timePart = token[token.startIndex..<zi]
                if offsetMinutes == nil { offsetMinutes = numericOffset(token[(zi + 1)...], negative: token[zi] == ASCII.dash) }
            } else if let last = token.last, isASCIILetter(last) {
                let letters = token.reversed().prefix(while: isASCIILetter).count
                timePart = token.dropLast(letters)
                let zone = String(decoding: token.suffix(letters).map(asciiLower), as: UTF8.self)
                if offsetMinutes == nil { offsetMinutes = RFC5322Date.zones[zone] }
            }
            let pieces = timePart.split(separator: ASCII.colon, omittingEmptySubsequences: false)
            guard pieces.count >= 2, let h = number(pieces[0]), let m = number(pieces[1].prefix(while: isASCIIDigit)) else { return }
            hour = h
            minute = m
            if pieces.count >= 3, let s = number(pieces[2].prefix(while: isASCIIDigit)) { second = s }
        }

        mutating func consumeNumber(_ token: ArraySlice<UInt8>) {
            guard let value = number(token) else { return }
            if token.count >= 3 || value > 31 {
                if year == nil { setYear(token) }
                return
            }
            if day == nil {
                day = value
            } else if year == nil {
                setYear(token)
            }
        }

        mutating func setYear(_ token: ArraySlice<UInt8>) {
            guard let value = number(token) else { return }
            year = value
            yearDigits = token.count
        }

        func number(_ token: ArraySlice<UInt8>) -> Int? {
            guard !token.isEmpty, token.count <= 9, token.allSatisfy(isASCIIDigit) else { return nil }
            var v = 0
            for c in token { v = v * 10 + Int(c - 0x30) }
            return v
        }

        func numericOffset(_ digits: ArraySlice<UInt8>, negative: Bool) -> Int? {
            RFC5322Date.numericOffset(digits, negative: negative)
        }

        func date() -> Date? {
            guard let day, let month, var year else { return nil }
            if yearDigits <= 2 {
                year += year < 50 ? 2000 : 1900
            } else if yearDigits == 3 {
                year += 1900
            }
            guard (1...31).contains(day), (1...12).contains(month), (1000...9999).contains(year) else { return nil }
            var h = hour ?? 0
            let m = minute ?? 0
            if let pm {
                if pm && h < 12 { h += 12 }
                if !pm && h == 12 { h = 0 }
            }
            guard (0...24).contains(h), (0...59).contains(m), (0...61).contains(second) else { return nil }
            let days = RFC5322Date.days(fromCivil: year, month, day)
            let seconds = days * 86_400 + Int64(h * 3600 + m * 60 + min(second, 59)) - Int64((offsetMinutes ?? 0) * 60)
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
    }

    /// "0200", "02:00", "2", "02", "530" → minutes.
    static func numericOffset(_ digits: ArraySlice<UInt8>, negative: Bool) -> Int? {
        let clean = digits.filter { $0 != ASCII.colon }
        guard !clean.isEmpty, clean.count <= 4, clean.allSatisfy(isASCIIDigit) else { return nil }
        var v = 0
        for c in clean { v = v * 10 + Int(c - 0x30) }
        let minutes: Int
        if clean.count <= 2 {
            minutes = v * 60
        } else {
            minutes = (v / 100) * 60 + v % 100
        }
        guard minutes <= 18 * 60 else { return nil }
        return negative ? -minutes : minutes
    }

    // MARK: ISO 8601

    /// "2026-10-20T09:15:00Z", "2026-10-20 09:15:00 +0200", "2026-10-20T09:15:00.123+02:00".
    static func parseISO(_ b: [UInt8]) -> Date? {
        var i = 0
        while i < b.count && isASCIIWhitespace(b[i]) { i += 1 }
        func digits(_ count: Int) -> Int? {
            guard i + count <= b.count else { return nil }
            var v = 0
            for k in 0..<count {
                let c = b[i + k]
                guard isASCIIDigit(c) else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            i += count
            return v
        }
        guard let y = digits(4), i < b.count, b[i] == ASCII.dash else { return nil }
        i += 1
        guard let mo = digits(2), i < b.count, b[i] == ASCII.dash else { return nil }
        i += 1
        guard let d = digits(2) else { return nil }
        var h = 0, mi = 0, s = 0
        var offset = 0
        if i < b.count && (b[i] == 0x54 || b[i] == 0x74 || b[i] == ASCII.space) {
            i += 1
            guard let hh = digits(2), i < b.count, b[i] == ASCII.colon else { return nil }
            i += 1
            guard let mm = digits(2) else { return nil }
            h = hh
            mi = mm
            if i < b.count && b[i] == ASCII.colon {
                i += 1
                s = digits(2) ?? 0
                if i < b.count && (b[i] == ASCII.dot || b[i] == ASCII.comma) {
                    i += 1
                    while i < b.count && isASCIIDigit(b[i]) { i += 1 }
                }
            }
            while i < b.count && b[i] == ASCII.space { i += 1 }
            if i < b.count {
                let c = b[i]
                if c == 0x5A || c == 0x7A {
                    offset = 0
                } else if c == 0x2B || c == ASCII.dash {
                    let end = b[(i + 1)...].firstIndex(where: { !isASCIIDigit($0) && $0 != ASCII.colon }) ?? b.count
                    offset = RFC5322Date.numericOffset(b[(i + 1)..<end], negative: c == ASCII.dash) ?? 0
                } else {
                    let word = String(decoding: b[i...].prefix(while: isASCIILetter).map(asciiLower), as: UTF8.self)
                    offset = zones[word] ?? 0
                }
            }
        }
        guard (1...12).contains(mo), (1...31).contains(d), h <= 24, mi <= 59, s <= 61 else { return nil }
        let days = days(fromCivil: y, mo, d)
        let seconds = days * 86_400 + Int64(h * 3600 + mi * 60 + min(s, 59)) - Int64(offset * 60)
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // MARK: Tables and calendar arithmetic

    static func month(_ word: String) -> Int? {
        let key = word.trimmingCharacters(in: CharacterSet(charactersIn: ".")).prefix(3)
        switch key {
        case "jan": return 1
        case "feb": return 2
        case "mar", "mär", "mrz": return 3
        case "apr": return 4
        case "may", "mai": return 5
        case "jun": return 6
        case "jul": return 7
        case "aug": return 8
        case "sep": return 9
        case "oct", "okt": return 10
        case "nov": return 11
        case "dec", "dez": return 12
        default: return nil
        }
    }

    /// Zone abbreviations → minutes east of UTC. The RFC 822 US zones plus the ones mailers emit.
    static let zones: [String: Int] = [
        "ut": 0, "utc": 0, "gmt": 0, "z": 0, "wet": 0, "bst": 60, "ist": 330, "cet": 60, "met": 60, "cest": 120, "mest": 120,
        "eet": 120, "eest": 180, "msk": 180, "msd": 240, "west": 60,
        "est": -300, "edt": -240, "cst": -360, "cdt": -300, "mst": -420, "mdt": -360, "pst": -480, "pdt": -420,
        "akst": -540, "akdt": -480, "hst": -600, "ast": -240, "adt": -180, "nst": -210, "ndt": -150,
        "jst": 540, "kst": 540, "hkt": 480, "sgt": 480, "awst": 480, "acst": 570, "acdt": 630, "aest": 600, "aedt": 660,
        "nzst": 720, "nzdt": 780, "pht": 480, "wib": 420, "ict": 420,
    ]

    /// Removes `( … )` comments (nested) from a header value.
    static func stripComments(_ b: [UInt8]) -> [UInt8] {
        guard b.contains(ASCII.lparen) else { return b }
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var depth = 0
        for c in b {
            if c == ASCII.lparen { depth += 1; out.append(ASCII.space); continue }
            if c == ASCII.rparen && depth > 0 { depth -= 1; continue }
            if depth == 0 { out.append(c) }
        }
        return out
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func days(fromCivil year: Int, _ month: Int, _ day: Int) -> Int64 {
        let y = Int64(month <= 2 ? year - 1 : year)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let m = Int64(month)
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + Int64(day) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays z0: Int64) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (Int(m <= 2 ? y + 1 : y), Int(m), Int(d))
    }
}
