import Foundation
import InkModel

/// Serialises an `OutgoingMessage` as an RFC 5322 / MIME message ready for SMTP and IMAP APPEND.
public enum MessageBuilder {
    /// RFC 5322 message: Date, From, To, Cc (never Bcc), Subject (encoded-word if non-ASCII), Message-ID
    /// (`<uuid@from-domain>`), In-Reply-To/References, MIME-Version, User-Agent: Ink.
    /// Body: multipart/alternative (text/plain quoted-printable UTF-8 + text/html generated from the
    /// plain text, with `quotedHTML` appended as a blockquote when present); wrapped in multipart/mixed
    /// when there are attachments (base64, 76-character lines, RFC 2231 `filename*=` for non-ASCII
    /// names). CRLF line endings throughout; no line is longer than 998 characters.
    ///
    /// - Parameters:
    ///   - date: the Date header (written in the current time zone).
    ///   - messageID: the Message-ID to use, without angle brackets; a new one is made when nil.
    /// - Returns: the message bytes and its Message-ID (without angle brackets).
    public static func build(_ message: OutgoingMessage, date: Date = Date(), messageID: String? = nil) -> (data: Data, messageID: String) {
        let id = messageID.flatMap(cleanMessageID) ?? "\(UUID().uuidString)@\(messageIDDomain(message.from.address))"

        var headers = HeaderWriter()
        headers.add("Date", RFC5322Date.format(date))
        headers.addAddresses("From", [message.from])
        if message.to.isEmpty && message.cc.isEmpty {
            headers.add("To", "undisclosed-recipients:;")
        } else if !message.to.isEmpty {
            headers.addAddresses("To", message.to)
        }
        if !message.cc.isEmpty { headers.addAddresses("Cc", message.cc) }
        headers.addUnstructured("Subject", message.subject)
        headers.addIDs("Message-ID", [id])
        let inReplyTo = message.inReplyTo.flatMap(cleanMessageID)
        if let inReplyTo { headers.addIDs("In-Reply-To", [inReplyTo]) }
        var references = message.references.compactMap(cleanMessageID)
        if let inReplyTo, !references.contains(inReplyTo) { references.append(inReplyTo) }
        if !references.isEmpty { headers.addIDs("References", references) }
        headers.add("MIME-Version", "1.0")
        headers.add("User-Agent", "Ink")

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let altBoundary = "=_Ink_alt_" + token
        let plain = message.fullPlainText.normalizedNewlines
        let html = htmlBody(for: message)

        var alternative = ""
        alternative += "--\(altBoundary)\r\n"
        alternative += "Content-Type: text/plain; charset=utf-8\r\n"
        alternative += "Content-Transfer-Encoding: quoted-printable\r\n\r\n"
        alternative += QuotedPrintable.encode(Data(plain.utf8)) + "\r\n"
        alternative += "--\(altBoundary)\r\n"
        alternative += "Content-Type: text/html; charset=utf-8\r\n"
        alternative += "Content-Transfer-Encoding: quoted-printable\r\n\r\n"
        alternative += QuotedPrintable.encode(Data(html.utf8)) + "\r\n"
        alternative += "--\(altBoundary)--\r\n"

        var body = Data()
        func append(_ text: String) { body.append(contentsOf: Array(text.utf8)) }
        if message.attachments.isEmpty {
            headers.add("Content-Type", "multipart/alternative; boundary=\"\(altBoundary)\"")
            append(alternative)
        } else {
            let mixedBoundary = "=_Ink_mix_" + token
            headers.add("Content-Type", "multipart/mixed; boundary=\"\(mixedBoundary)\"")
            append("--\(mixedBoundary)\r\n")
            append("Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n")
            append(alternative)
            for attachment in message.attachments {
                append("--\(mixedBoundary)\r\n")
                append(attachmentHeaders(attachment))
                append("Content-Transfer-Encoding: base64\r\n\r\n")
                let encoded = Base64Lenient.encodeBytes(attachment.data, lineLength: 76)
                body.append(contentsOf: encoded)
                if !encoded.isEmpty { append("\r\n") }
            }
            append("--\(mixedBoundary)--\r\n")
        }

        var data = Data(headers.text.utf8)
        data.reserveCapacity(data.count + body.count + 2)
        data.append(contentsOf: Array("\r\n".utf8))
        data.append(body)
        return (data, id)
    }

    // MARK: Headers

    /// Accumulates folded header lines.
    struct HeaderWriter {
        var text = ""

        mutating func add(_ name: String, _ value: String) {
            text += fold(name: name, value: sanitizeHeaderText(value))
        }

        mutating func addUnstructured(_ name: String, _ value: String) {
            let clean = sanitizeHeaderText(value).trimmedWhitespace
            let tooLong = clean.split(separator: " ").contains { $0.utf8.count > 900 }
            // The first word shares its line with "Name: ", so keep every word short enough for 78.
            let budget = 78 - name.utf8.count - 2
            let encoded = tooLong || EncodedWord.needsEncoding(clean)
                ? EncodedWord.encode(clean, force: true, maxWordLength: budget)
                : clean
            text += fold(name: name, value: encoded)
        }

        mutating func addAddresses(_ name: String, _ addresses: [EmailAddress]) {
            let formatted = addresses.compactMap(MessageBuilder.formatAddress)
            guard !formatted.isEmpty else { return }
            text += fold(name: name, value: formatted.joined(separator: ", "))
        }

        mutating func addIDs(_ name: String, _ ids: [String]) {
            text += fold(name: name, value: ids.map { "<\($0)>" }.joined(separator: " "))
        }
    }

    /// Folds a header at spaces so lines stay under 78 characters where possible (never over 998).
    static func fold(name: String, value: String) -> String {
        let limit = 78
        var out = ""
        var line = name + ":"
        for word in value.split(separator: " ", omittingEmptySubsequences: true) {
            let w = String(word)
            if line.utf8.count + 1 + w.utf8.count > limit && line.utf8.count > name.utf8.count + 1 {
                out += line + "\r\n"
                line = " " + w
            } else {
                line += " " + w
            }
        }
        out += line + "\r\n"
        return out
    }

    /// Header text can't carry line breaks or control characters (header injection).
    static func sanitizeHeaderText(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 }))
    }

    static func cleanAddress(_ address: String) -> String {
        address.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F && !"<>,;()\"".unicodeScalars.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// `Name <addr>`, with the name encoded (non-ASCII) or quoted (specials) as needed.
    static func formatAddress(_ address: EmailAddress) -> String? {
        let addr = cleanAddress(address.address)
        // An address can't be folded; one too long for a header line is not a real address.
        guard !addr.isEmpty, addr.utf8.count <= 900 else { return nil }
        guard let rawName = address.name else { return addr }
        let name = sanitizeHeaderText(rawName).collapsingWhitespace
        guard !name.isEmpty, name != addr else { return addr }
        // A word too long to fold onto a 998-octet line is split into encoded words instead.
        let tooLong = name.split(separator: " ").contains { $0.utf8.count > 900 }
        if tooLong || EncodedWord.needsEncoding(name) {
            return EncodedWord.encode(name, force: true, maxWordLength: 64) + " <\(addr)>"
        }
        let specials = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
        if name.unicodeScalars.contains(where: { specials.contains($0) }) {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(addr)>"
        }
        return "\(name) <\(addr)>"
    }

    static func cleanMessageID(_ raw: String) -> String? {
        let s = raw.filter { !$0.isWhitespace && $0 != "<" && $0 != ">" && $0 != "\"" }
        return s.isEmpty || s.utf8.count > 900 ? nil : s
    }

    static func messageIDDomain(_ address: String) -> String {
        guard let at = address.lastIndex(of: "@") else { return "ink.local" }
        let domain = address[address.index(after: at)...].lowercased()
        let valid = !domain.isEmpty && domain.utf8.allSatisfy { isASCIILetter($0) || isASCIIDigit($0) || $0 == ASCII.dash || $0 == ASCII.dot }
        return valid ? domain : "ink.local"
    }

    // MARK: Attachments

    static func sanitizeMIMEType(_ s: String) -> String {
        let lower = s.trimmedWhitespace.asciiLowercased
        guard lower.utf8.count <= 200 else { return "application/octet-stream" }
        let parts = lower.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, ContentType.isToken(String(parts[0])), ContentType.isToken(String(parts[1])),
              !parts[0].isEmpty, !parts[1].isEmpty else { return "application/octet-stream" }
        return lower
    }

    static func attachmentHeaders(_ attachment: OutgoingAttachment) -> String {
        let mimeType = sanitizeMIMEType(attachment.mimeType)
        let name = HeaderParameters.sanitizeFilename(sanitizeHeaderText(attachment.filename).collapsingWhitespace) ?? "attachment"
        let simple = name.utf8.count <= 60 && !name.contains("  ")
            && name.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F && $0 != ASCII.quote && $0 != ASCII.backslash }
        if simple {
            return fold(name: "Content-Type", value: "\(mimeType); name=\"\(name)\"")
                + fold(name: "Content-Disposition", value: "attachment; filename=\"\(name)\"")
        }
        // Non-ASCII or long: RFC 2047 in `name` (what Outlook reads) and RFC 2231 in `filename*`.
        let encodedName = EncodedWord.encode(name, force: true, maxWordLength: 60)
        return fold(name: "Content-Type", value: "\(mimeType); name=\"\(encodedName)\"")
            + fold(name: "Content-Disposition", value: "attachment; " + rfc2231Parameter("filename", name))
    }

    static let attributeChars: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8))

    /// `name*0*=utf-8''…; name*1*=…` with segments short enough to fold.
    static func rfc2231Parameter(_ name: String, _ value: String) -> String {
        var pieces: [String] = []
        var current = ""
        for byte in value.utf8 {
            let token = attributeChars.contains(byte)
                ? String(UnicodeScalar(byte))
                : "%" + String(UnicodeScalar(upperHexDigits[Int(byte >> 4)])) + String(UnicodeScalar(upperHexDigits[Int(byte & 0x0F)]))
            if current.utf8.count + token.utf8.count > 54 {
                pieces.append(current)
                current = ""
            }
            current += token
        }
        if !current.isEmpty || pieces.isEmpty { pieces.append(current) }
        if pieces.count == 1 { return "\(name)*=utf-8''\(pieces[0])" }
        return pieces.enumerated().map { index, piece in
            index == 0 ? "\(name)*0*=utf-8''\(piece)" : "\(name)*\(index)*=\(piece)"
        }.joined(separator: "; ")
    }

    // MARK: HTML alternative

    static let fontStyle = "font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 15px; line-height: 1.45;"
    static let quoteStyle = "margin: 0 0 0 0.8ex; border-left: 1px solid #ccc; padding-left: 1ex;"

    /// The text/html alternative: the typed text as HTML, then the quoted original.
    static func htmlBody(for message: OutgoingMessage) -> String {
        var html = "<!DOCTYPE html>\n<html>\n<head>\n<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">\n</head>\n<body>\n"
        html += "<div dir=\"auto\" style=\"\(fontStyle)\">\n\(linesToHTML(message.body))\n</div>\n"
        let quotedText = message.quotedText.map { $0.normalizedNewlines } ?? ""
        let quotedHTML = message.quotedHTML.map { HTMLSanitizer.sanitize($0, dropCIDImages: true).body } ?? ""
        if !quotedText.trimmedWhitespace.isEmpty || !quotedHTML.trimmedWhitespace.isEmpty {
            let (header, rest) = splitQuoteHeader(quotedText, mode: message.replyMode)
            html += "<br>\n<div dir=\"auto\" style=\"\(fontStyle)\">\n"
            if !header.isEmpty {
                html += "<div>" + header.map(PlainTextHTML.linkify).joined(separator: "<br>\n") + "</div>\n"
            }
            html += "<blockquote type=\"cite\" style=\"\(quoteStyle)\">\n"
            if !quotedHTML.trimmedWhitespace.isEmpty {
                html += quotedHTML
            } else {
                html += quotedLinesToHTML(rest)
            }
            html += "\n</blockquote>\n</div>\n"
        }
        html += "</body>\n</html>\n"
        return html
    }

    /// Splits `quotedText` into its header (the "On … wrote:" line, or a forward's header block)
    /// and the quoted body (with one level of `>` removed for replies).
    static func splitQuoteHeader(_ quotedText: String, mode: ReplyMode?) -> (header: [String], rest: String) {
        let lines = quotedText.components(separatedBy: "\n")
        let isForward = mode == .forward || (mode == nil && (lines.first?.hasPrefix("-----") ?? false))
        var header: [String] = []
        var index = 0
        if isForward {
            while index < lines.count && !lines[index].trimmedWhitespace.isEmpty {
                header.append(lines[index])
                index += 1
            }
            while index < lines.count && lines[index].trimmedWhitespace.isEmpty { index += 1 }
            return (header, lines[index...].joined(separator: "\n"))
        }
        while index < lines.count && !lines[index].hasPrefix(">") && !lines[index].trimmedWhitespace.isEmpty && index < 3 {
            header.append(lines[index])
            index += 1
        }
        let rest = lines[index...].map { line -> String in
            if line.hasPrefix("> ") { return String(line.dropFirst(2)) }
            if line.hasPrefix(">") { return String(line.dropFirst()) }
            return line
        }
        return (header, rest.joined(separator: "\n"))
    }

    /// Plain lines → escaped, linked HTML with `<br>` line breaks.
    static func linesToHTML(_ text: String) -> String {
        text.normalizedNewlines.components(separatedBy: "\n").map { line in
            let linked = PlainTextHTML.linkify(line)
            // Keep indentation and runs of spaces.
            return linked.replacingOccurrences(of: "  ", with: " &nbsp;")
        }.joined(separator: "<br>\n")
    }

    /// Plain lines with `>` quoting → nested blockquotes with `<br>` line breaks.
    static func quotedLinesToHTML(_ text: String) -> String {
        var out = ""
        var depth = 0
        var first = true
        for line in text.components(separatedBy: "\n") {
            let (lineDepth, content) = PlainTextHTML.quoteDepth(line)
            if lineDepth > depth {
                out += String(repeating: "<blockquote type=\"cite\" style=\"\(quoteStyle)\">", count: lineDepth - depth)
                first = true
            } else if lineDepth < depth {
                out += String(repeating: "</blockquote>", count: depth - lineDepth)
                first = true
            }
            depth = lineDepth
            if !first { out += "<br>\n" }
            out += PlainTextHTML.linkify(content)
            first = false
        }
        out += String(repeating: "</blockquote>", count: depth)
        return out
    }
}
