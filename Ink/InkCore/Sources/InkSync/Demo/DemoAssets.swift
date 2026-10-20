import Foundation

/// Small, valid, deterministic files for the demo inbox's attachments: PNG "photos", one-page
/// PDFs and an iCalendar invite. Generated in code so the package ships no binary resources.
enum DemoAssets {
    // MARK: PNG

    struct Palette {
        var skyTop: (Double, Double, Double)
        var skyBottom: (Double, Double, Double)
        var sun: (Double, Double, Double)
        var far: (Double, Double, Double)
        var near: (Double, Double, Double)
        var water: (Double, Double, Double)?
        var sunX: Double
        var sunY: Double
    }

    static let dusk = Palette(skyTop: (38, 52, 112), skyBottom: (246, 166, 120), sun: (255, 224, 170),
                              far: (120, 96, 140), near: (52, 46, 78), water: nil, sunX: 0.68, sunY: 0.52)
    static let lake = Palette(skyTop: (120, 180, 230), skyBottom: (226, 240, 248), sun: (255, 252, 230),
                              far: (110, 150, 160), near: (46, 92, 74), water: (70, 130, 170), sunX: 0.25, sunY: 0.22)
    static let meadow = Palette(skyTop: (250, 214, 160), skyBottom: (255, 240, 214), sun: (255, 250, 236),
                                far: (196, 150, 120), near: (120, 140, 90), water: nil, sunX: 0.5, sunY: 0.45)

    /// A little landscape: sky gradient, sun, two ridges and optionally a lake.
    static func landscapePNG(width: Int, height: Int, palette p: Palette) -> Data {
        png(width: width, height: height) { x, y in
            let fx = Double(x) / Double(max(1, width - 1))
            let fy = Double(y) / Double(max(1, height - 1))
            func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
                (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
            }
            var color = mix(p.skyTop, p.skyBottom, min(1, fy * 1.3))
            let aspect = Double(width) / Double(max(1, height))
            let dx = (fx - p.sunX) * aspect, dy = fy - p.sunY
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < 0.09 {
                color = p.sun
            } else if distance < 0.22 {
                color = mix(p.sun, color, (distance - 0.09) / 0.13)
            }
            let farRidge = 0.55 + 0.08 * sin(fx * 7.0 + 1.3) + 0.04 * sin(fx * 17.0)
            let nearRidge = 0.70 + 0.07 * sin(fx * 4.0 + 0.4) + 0.025 * sin(fx * 23.0 + 2.0)
            if fy > farRidge { color = mix(p.far, color, 0.15) }
            if fy > nearRidge { color = p.near }
            if let water = p.water, fy > 0.84 {
                let ripple = 0.08 * sin(fx * 60 + fy * 90)
                color = mix(water, p.skyBottom, 0.25 + ripple)
            }
            return (UInt8(clamping: Int(color.0)), UInt8(clamping: Int(color.1)), UInt8(clamping: Int(color.2)))
        }
    }

    /// An RGB PNG. The image data is zlib with stored (uncompressed) deflate blocks, which every
    /// decoder accepts.
    static func png(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity((width * 3 + 1) * height)
        for y in 0..<height {
            raw.append(0) // filter: none
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                raw.append(r); raw.append(g); raw.append(b)
            }
        }
        var zlib: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let length = min(65_535, raw.count - offset)
            let isLast = offset + length >= raw.count
            zlib.append(isLast ? 1 : 0)
            zlib.append(UInt8(length & 0xff)); zlib.append(UInt8(length >> 8))
            zlib.append(UInt8(~length & 0xff)); zlib.append(UInt8((~length >> 8) & 0xff))
            zlib.append(contentsOf: raw[offset..<(offset + length)])
            offset += length
        } while offset < raw.count
        zlib.append(contentsOf: bigEndian(adler32(raw)))

        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var header = bigEndian(UInt32(width)) + bigEndian(UInt32(height))
        header += [8, 2, 0, 0, 0] // 8-bit, truecolour, deflate, adaptive filtering, no interlace
        out += chunk("IHDR", header)
        out += chunk("IDAT", zlib)
        out += chunk("IEND", [])
        return Data(out)
    }

    private static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        return bigEndian(UInt32(data.count)) + typeBytes + data + bigEndian(crc32(typeBytes + data))
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }

    // MARK: PDF

    /// A one-page US-letter PDF: a coloured rule, a bold title, then lines of text. Lines that
    /// start with "# " are subheadings; "" adds space. Text is Latin-1 only (typographic
    /// punctuation is replaced).
    static func pdf(title: String, subtitle: String? = nil, lines: [String], accent: (Double, Double, Double) = (0.24, 0.35, 0.92)) -> Data {
        var content = ""
        content += String(format: "%.3f %.3f %.3f rg 72 742 468 5 re f\n", accent.0, accent.1, accent.2)
        content += "BT /F1 22 Tf 72 708 Td (\(pdfEscape(title))) Tj ET\n"
        var y = 708.0
        if let subtitle {
            y -= 22
            content += "0.45 0.45 0.45 rg BT /F2 11 Tf 72 \(Int(y)) Td (\(pdfEscape(subtitle))) Tj ET 0 0 0 rg\n"
        }
        y -= 34
        for line in lines {
            if y < 72 { break }
            if line.isEmpty {
                y -= 10
            } else if line.hasPrefix("# ") {
                y -= 6
                content += "BT /F1 13 Tf 72 \(Int(y)) Td (\(pdfEscape(String(line.dropFirst(2))))) Tj ET\n"
                y -= 20
            } else {
                content += "BT /F2 11 Tf 72 \(Int(y)) Td (\(pdfEscape(line))) Tj ET\n"
                y -= 16
            }
        }
        content += "0.6 0.6 0.6 rg BT /F2 8 Tf 72 48 Td (Sample document generated for the Ink demo inbox.) Tj ET\n"

        let contentBytes = Array(content.utf8)
        let objects: [String] = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        var out = Array("%PDF-1.4\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(out.count)
            out += Array("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        offsets.append(out.count)
        out += Array("6 0 obj\n<< /Length \(contentBytes.count) >>\nstream\n".utf8)
        out += contentBytes
        out += Array("\nendstream\nendobj\n".utf8)
        let xrefOffset = out.count
        var xref = "xref\n0 7\n0000000000 65535 f \n"
        for offset in offsets { xref += String(format: "%010ld 00000 n \n", offset) }
        xref += "trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out += Array(xref.utf8)
        return Data(out)
    }

    private static func pdfEscape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "(": result += "\\("
            case ")": result += "\\)"
            case "\\": result += "\\\\"
            case "\u{2014}", "\u{2013}": result += "-"
            case "\u{2018}", "\u{2019}": result += "'"
            case "\u{201C}", "\u{201D}": result += "\""
            case "\u{2022}": result += "\\225" // WinAnsi bullet
            case "\u{00B7}": result += "\\267"
            default:
                if scalar.value < 0x80 {
                    result.unicodeScalars.append(scalar)
                } else if scalar.value < 0x100 {
                    result += String(format: "\\%03o", scalar.value)
                } else {
                    result += "?"
                }
            }
        }
        return result
    }

    // MARK: iCalendar

    struct Attendee {
        var name: String
        var email: String
        var organizer = false
    }

    /// A METHOD:REQUEST invitation with one event and a 15-minute reminder.
    static func ics(uid: String, summary: String, start: Date, end: Date, location: String, description: String,
                    attendees: [Attendee], stamp: Date) -> Data {
        func utc(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.string(from: date)
        }
        func text(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        var lines = [
            "BEGIN:VCALENDAR",
            "PRODID:-//Fieldstone//Calendar 4.2//EN",
            "VERSION:2.0",
            "CALSCALE:GREGORIAN",
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            "DTSTART:\(utc(start))",
            "DTEND:\(utc(end))",
            "DTSTAMP:\(utc(stamp))",
        ]
        for attendee in attendees where attendee.organizer {
            lines.append("ORGANIZER;CN=\(attendee.name):mailto:\(attendee.email)")
        }
        lines.append("UID:\(uid)")
        for attendee in attendees {
            let status = attendee.organizer ? "ACCEPTED" : "NEEDS-ACTION"
            lines.append("ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=\(status);RSVP=\(attendee.organizer ? "FALSE" : "TRUE");CN=\(attendee.name);X-NUM-GUESTS=0:mailto:\(attendee.email)")
        }
        lines += [
            "CREATED:\(utc(stamp))",
            "DESCRIPTION:\(text(description))",
            "LAST-MODIFIED:\(utc(stamp))",
            "LOCATION:\(text(location))",
            "SEQUENCE:0",
            "STATUS:CONFIRMED",
            "SUMMARY:\(text(summary))",
            "TRANSP:OPAQUE",
            "BEGIN:VALARM",
            "ACTION:DISPLAY",
            "DESCRIPTION:Reminder",
            "TRIGGER:-P0DT0H15M0S",
            "END:VALARM",
            "END:VEVENT",
            "END:VCALENDAR",
        ]
        return Data(lines.map(foldICSLine).joined(separator: "\r\n").appending("\r\n").utf8)
    }

    /// Folds a content line to 75 octets (RFC 5545 §3.1) without splitting UTF-8 sequences.
    static func foldICSLine(_ line: String) -> String {
        var result = ""
        var count = 0
        for character in line {
            let size = String(character).utf8.count
            if count + size > 75 {
                result += "\r\n "
                count = 1
            }
            result.append(character)
            count += size
        }
        return result
    }
}
