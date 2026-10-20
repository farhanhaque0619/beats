import Foundation
import InkModel

/// Parses raw RFC 5322 / MIME messages. Never throws and never crashes on bad input: anything it
/// can't make sense of ends up as text or as an attachment.
public enum MIMEParser {
    /// Nesting deeper than this is treated as an opaque leaf (defends against hostile messages).
    static let maxDepth = 40
    /// After this many parts the rest of a message is left unsplit.
    static let maxParts = 10_000

    /// Parses a whole message (headers and body).
    public static func parse(_ data: Data) -> ParsedMessage {
        let bytes = [UInt8](data)
        var parser = TreeParser(b: bytes)
        let root = parser.parseEntity(range: 0..<bytes.count, partID: "", isMessageRoot: true, depth: 0, defaultType: .defaultPlain)
        return ParsedMessage(headers: root.headers, root: root)
    }

    /// Parses a message given as text (converted to UTF-8 bytes).
    public static func parse(_ string: String) -> ParsedMessage {
        parse(Data(string.utf8))
    }

    /// Parses a MIME entity (headers + body) into a part tree whose IDs start at `partID`.
    /// Use this for a body part fetched with its MIME header (IMAP `BODY[1.2.MIME]` + `BODY[1.2]`).
    public static func parsePart(_ data: Data, partID: String = "1") -> MIMEPart {
        let bytes = [UInt8](data)
        var parser = TreeParser(b: bytes)
        return parser.parseEntity(range: 0..<bytes.count, partID: partID, isMessageRoot: false, depth: 0, defaultType: .defaultPlain)
    }

    /// Decodes a single body fetched on its own (for example the first 2 KB of an IMAP section for a
    /// snippet): undoes the transfer encoding, applies the charset (sniffing `<meta charset>` for
    /// HTML without one) and unwraps `format=flowed`. Truncated input is tolerated. HTML stays HTML.
    public static func decodeText(_ data: Data, transferEncoding: String?, contentType: ContentType) -> String {
        let decoded = TransferEncoding.decode(data, encoding: transferEncoding)
        let part = MIMEPart(contentType: contentType, body: decoded)
        let text = part.text() ?? Charset.decode(decoded, charset: contentType.charset)
        return BodySelector.applyFlowed(text, contentType: contentType)
    }
}

/// Builds the part tree over one byte buffer, by index ranges (no copying until a leaf body is decoded).
struct TreeParser {
    let b: [UInt8]
    var partCount = 0

    init(b: [UInt8], partCount: Int = 0) {
        self.b = b
        self.partCount = partCount
    }

    mutating func parseEntity(range: Range<Int>, partID: String, isMessageRoot: Bool, depth: Int, defaultType: ContentType) -> MIMEPart {
        let (headers, rawBodyStart) = MIMEHeaders.parseBlock(b, range: range)
        let bodyStart = min(max(rawBodyStart, range.lowerBound), range.upperBound)
        let bodyRange = bodyStart..<range.upperBound
        partCount += 1

        var contentType = headers["Content-Type"].map(ContentType.parse) ?? defaultType
        let transferEncoding = TransferEncoding.normalize(headers["Content-Transfer-Encoding"])
        let disposition = headers["Content-Disposition"].flatMap { value -> ContentDisposition? in
            value.trimmedWhitespace.isEmpty ? nil : ContentDisposition.parse(value)
        }
        let contentID = headers["Content-ID"].flatMap(cleanContentID)

        var part = MIMEPart(
            headers: headers,
            contentType: contentType,
            disposition: disposition,
            transferEncoding: transferEncoding,
            partID: isMessageRoot && !contentType.isMultipart ? Self.leafID(partID) : partID,
            contentID: contentID
        )

        if contentType.isMultipart {
            if depth < MIMEParser.maxDepth, partCount < MIMEParser.maxParts,
               let boundary = usableBoundary(contentType.boundary) ?? detectBoundary(in: bodyRange),
               let ranges = splitMultipart(bodyRange, boundary: boundary) {
                let childDefault = contentType.subtype == "digest" ? ContentType(type: "message", subtype: "rfc822") : ContentType.defaultPlain
                var children: [MIMEPart] = []
                children.reserveCapacity(ranges.count)
                for (index, childRange) in ranges.enumerated() {
                    if partCount >= MIMEParser.maxParts { break }
                    let childID = partID.isEmpty ? "\(index + 1)" : "\(partID).\(index + 1)"
                    children.append(parseEntity(range: childRange, partID: childID, isMessageRoot: false, depth: depth + 1, defaultType: childDefault))
                }
                part.children = children
                return part
            }
            // No boundary that matches anything: show the body as text rather than nothing.
            contentType = ContentType(type: "text", subtype: "plain", parameters: contentType.charset.map { ["charset": $0] } ?? [:])
            part.contentType = contentType
            if isMessageRoot { part.partID = Self.leafID(partID) }
        }

        let body = TransferEncoding.decode(bytes: b[bodyRange], encoding: transferEncoding)
        part.body = body
        part.filename = disposition?.filename ?? contentType.parameters["name"].flatMap(HeaderParameters.sanitizeFilename)
        if part.filename == nil, transferEncoding == "x-uuencode" {
            part.filename = UUEncode.filename(in: Data(b[bodyRange])).flatMap(HeaderParameters.sanitizeFilename)
        }

        if part.isEncapsulatedMessage, depth < MIMEParser.maxDepth, partCount < MIMEParser.maxParts, !body.isEmpty {
            let embedded: MIMEPart
            if transferEncoding == "base64" || transferEncoding == "quoted-printable" || transferEncoding == "x-uuencode" {
                var sub = TreeParser(b: [UInt8](body), partCount: partCount)
                embedded = sub.parseEntity(range: 0..<sub.b.count, partID: part.partID, isMessageRoot: true, depth: depth + 1, defaultType: .defaultPlain)
                partCount = sub.partCount
            } else {
                embedded = parseEntity(range: bodyRange, partID: part.partID, isMessageRoot: true, depth: depth + 1, defaultType: .defaultPlain)
            }
            part.children = [embedded]
        }
        return part
    }

    static func leafID(_ containerID: String) -> String {
        containerID.isEmpty ? "1" : containerID + ".1"
    }

    /// Strips `<>`, whitespace and quotes from a Content-ID.
    func cleanContentID(_ raw: String) -> String? {
        var s = raw.trimmedWhitespace
        if let open = s.firstIndex(of: "<") {
            let afterOpen = s.index(after: open)
            let close = s[afterOpen...].firstIndex(of: ">") ?? s.endIndex
            s = String(s[afterOpen..<close])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
        return s.isEmpty ? nil : s
    }

    func usableBoundary(_ boundary: String?) -> [UInt8]? {
        guard let boundary else { return nil }
        // Trailing spaces are not part of a boundary (RFC 2046 §5.1.1).
        var bytes = Array(boundary.utf8)
        while let last = bytes.last, isWSP(last) { bytes.removeLast() }
        guard !bytes.isEmpty, bytes.count <= 200 else { return nil }
        return bytes
    }

    /// Finds the boundary of a multipart whose Content-Type lacks one (or names one that doesn't
    /// occur): the first `--token` line that appears again later.
    func detectBoundary(in range: Range<Int>) -> [UInt8]? {
        var lineStart = range.lowerBound
        let end = min(range.upperBound, range.lowerBound + 256 * 1024)
        while lineStart < end {
            let lf = b.firstIndex(of: ASCII.lf, from: lineStart, to: range.upperBound) ?? range.upperBound
            var lineEnd = lf
            while lineEnd > lineStart && (b[lineEnd - 1] == ASCII.cr || isWSP(b[lineEnd - 1])) { lineEnd -= 1 }
            if lineEnd - lineStart > 3, b[lineStart] == ASCII.dash, b[lineStart + 1] == ASCII.dash {
                var candidate = Array(b[(lineStart + 2)..<lineEnd])
                if candidate.count > 2, candidate.suffix(2) == [ASCII.dash, ASCII.dash] { candidate.removeLast(2) }
                if !candidate.isEmpty, candidate.count <= 200, !candidate.contains(where: { isWSP($0) }),
                   let ranges = splitMultipart(range, boundary: candidate), ranges.count >= 1,
                   b.firstRange(of: [ASCII.dash, ASCII.dash] + candidate, from: lf, to: range.upperBound) != nil {
                    return candidate
                }
            }
            lineStart = lf + 1
        }
        return nil
    }

    /// Splits a multipart body into its parts' ranges (each from just after a delimiter line to the
    /// line break before the next). Preamble and epilogue are dropped. A missing close delimiter
    /// (truncated message) ends the last part at the end of the data. Nil when no delimiter occurs.
    func splitMultipart(_ range: Range<Int>, boundary: [UInt8]) -> [Range<Int>]? {
        let delimiter = [ASCII.dash, ASCII.dash] + boundary
        var parts: [Range<Int>] = []
        var currentStart: Int?
        var found = false
        var lineStart = range.lowerBound
        let end = range.upperBound
        while lineStart < end {
            let lf = b.firstIndex(of: ASCII.lf, from: lineStart, to: end)
            let lineEnd = lf ?? end
            let next = lf.map { $0 + 1 } ?? end
            if b[lineStart] == ASCII.dash, b.hasBytes(delimiter, at: lineStart), lineStart + delimiter.count <= lineEnd {
                var k = lineStart + delimiter.count
                var isClose = false
                var isDelimiter = false
                if k + 1 < lineEnd, b[k] == ASCII.dash, b[k + 1] == ASCII.dash {
                    // "--boundary--" closes the multipart; anything after it on the line is ignored.
                    isClose = true
                    isDelimiter = true
                } else {
                    while k < lineEnd && (isWSP(b[k]) || b[k] == ASCII.cr) { k += 1 }
                    isDelimiter = k == lineEnd
                }
                if isDelimiter {
                    found = true
                    if let start = currentStart {
                        parts.append(start..<contentEnd(before: lineStart, floor: start))
                    }
                    if isClose {
                        currentStart = nil
                        return parts
                    }
                    currentStart = next
                }
            }
            lineStart = next
        }
        guard found else { return nil }
        if let start = currentStart, start <= end {
            parts.append(start..<end)
        }
        return parts
    }

    /// The line break before a delimiter belongs to the delimiter.
    func contentEnd(before lineStart: Int, floor: Int) -> Int {
        var e = lineStart
        if e > floor && b[e - 1] == ASCII.lf {
            e -= 1
            if e > floor && b[e - 1] == ASCII.cr { e -= 1 }
        }
        return max(e, floor)
    }
}

/// A parsed message: the decoded envelope headers, the MIME tree, and the body Ink shows.
public struct ParsedMessage: Sendable {
    /// The message's own header block.
    public var headers: MIMEHeaders
    /// The MIME tree (IMAP part numbering, see `MIMEPart`).
    public var root: MIMEPart
    /// Decoded subject, "" when missing.
    public var subject: String
    public var from: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    /// The Date header, else the date of the newest Received header.
    public var date: Date?
    /// Message-ID without angle brackets.
    public var messageID: String?
    /// In-Reply-To IDs without angle brackets.
    public var inReplyTo: [String]
    /// References IDs without angle brackets, oldest first, de-duplicated.
    public var references: [String]
    /// The text/plain body (joined when several inline text parts make up the message; HTML-only
    /// pieces converted to text). Nil when the message has no text/plain at all.
    public var plainText: String?
    /// The text/html body (joined likewise; plain pieces escaped). Nil when there is no HTML.
    public var html: String?
    /// Attachments with their decoded data. Images referenced from the HTML by `cid:` are
    /// `isInline` and carry their `contentID`.
    public var attachments: [Attachment]

    /// Builds the message view of a part tree (`headers` are the message headers, usually `root.headers`).
    public init(headers: MIMEHeaders, root: MIMEPart) {
        self.headers = headers
        self.root = root
        subject = headers.decoded("Subject")?.collapsingWhitespace ?? ""
        from = AddressParser.parseList(headers.values("From").joined(separator: ", "))
        replyTo = AddressParser.parseList(headers.values("Reply-To").joined(separator: ", "))
        to = AddressParser.parseList(headers.values("To").joined(separator: ", "))
        cc = AddressParser.parseList(headers.values("Cc").joined(separator: ", "))
        bcc = AddressParser.parseList(headers.values("Bcc").joined(separator: ", "))
        date = headers["Date"].flatMap(RFC5322Date.parse) ?? Self.receivedDate(headers)
        messageID = headers["Message-ID"].flatMap { MessageIDParser.parseList($0).first }
        inReplyTo = headers.values("In-Reply-To").flatMap(MessageIDParser.parseList)
        references = MessageIDParser.parseList(headers.values("References").joined(separator: " "))

        let body = BodySelector.select(root)
        plainText = body.plainText
        html = body.html
        attachments = body.attachments
    }

    /// The body in the shape the app stores and shows.
    public func body(messageID: String) -> MessageBody {
        MessageBody(messageID: messageID, plainText: plainText, html: html, attachments: attachments)
    }

    /// The best readable text: `plainText`, else the HTML converted to text.
    public var readableText: String {
        if let plainText, !plainText.trimmedWhitespace.isEmpty { return plainText }
        if let html { return HTMLText.toPlainText(html) }
        return plainText ?? ""
    }

    static func singleLine(_ s: String) -> String {
        // "\r\n" is a single Character, so it needs its own comparison.
        guard s.contains(where: { $0 == "\r\n" || $0 == "\r" || $0 == "\n" || $0 == "\t" }) else { return s }
        return s.split(whereSeparator: { $0 == "\r\n" || $0 == "\r" || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }

    static func receivedDate(_ headers: MIMEHeaders) -> Date? {
        for value in headers.values("Received") {
            if let semi = value.lastIndex(of: ";"), let date = RFC5322Date.parse(String(value[value.index(after: semi)...])) {
                return date
            }
        }
        return nil
    }
}
