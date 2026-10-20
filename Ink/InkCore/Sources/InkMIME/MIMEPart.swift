import Foundation

/// One node of a parsed MIME tree.
///
/// Part IDs follow IMAP section numbering (RFC 3501 §6.4.5): the children of a multipart root are
/// "1", "2", …; a non-multipart message's body is "1"; the parts of a `message/rfc822` part "3" are
/// "3.1", "3.2", … (its encapsulated root shares the ID "3" when it is a multipart, since IMAP has
/// no number for it, and is "3.1" otherwise). A multipart root's own ID is "".
public struct MIMEPart: Hashable, Sendable {
    public var headers: MIMEHeaders
    /// Defaults to `text/plain; charset=us-ascii` (or `message/rfc822` inside multipart/digest).
    public var contentType: ContentType
    public var disposition: ContentDisposition?
    /// Lowercased Content-Transfer-Encoding, "7bit" when missing.
    public var transferEncoding: String
    /// IMAP-style section number. See the type documentation.
    public var partID: String
    /// The body decoded per Content-Transfer-Encoding. Empty for multiparts. For `message/rfc822`
    /// parts it is the encapsulated message's raw bytes.
    public var body: Data
    public var children: [MIMEPart]
    /// Content-ID without angle brackets.
    public var contentID: String?
    /// The disposition `filename`, else the Content-Type `name` parameter; decoded and stripped of
    /// directory components.
    public var filename: String?

    public init(
        headers: MIMEHeaders = MIMEHeaders(),
        contentType: ContentType = .defaultPlain,
        disposition: ContentDisposition? = nil,
        transferEncoding: String = "7bit",
        partID: String = "1",
        body: Data = Data(),
        children: [MIMEPart] = [],
        contentID: String? = nil,
        filename: String? = nil
    ) {
        self.headers = headers
        self.contentType = contentType
        self.disposition = disposition
        self.transferEncoding = transferEncoding
        self.partID = partID
        self.body = body
        self.children = children
        self.contentID = contentID
        self.filename = filename
    }

    public var isMultipart: Bool { contentType.isMultipart }

    /// True for `message/rfc822` (and `message/global`) parts.
    public var isEncapsulatedMessage: Bool {
        contentType.type == "message" && (contentType.subtype == "rfc822" || contentType.subtype == "global")
    }

    /// The body decoded with its charset, for `text/*` parts; nil otherwise.
    ///
    /// When the part has no charset parameter, an HTML part's `<meta charset>` is honoured and
    /// anything else is read as UTF-8 if valid, else Windows-1252.
    public func text() -> String? {
        guard contentType.type == "text" else { return nil }
        var charset = contentType.charset
        if charset == nil, contentType.subtype == "html" {
            charset = HTMLCharsetSniffer.sniff(body)
        }
        return Charset.decode(body, charset: charset)
    }

    /// The encapsulated message of a `message/rfc822` part, parsed.
    public var embeddedMessage: ParsedMessage? {
        guard isEncapsulatedMessage, let root = children.first else { return nil }
        return ParsedMessage(headers: root.headers, root: root)
    }

    /// This part and all of its descendants, depth first.
    public var allParts: [MIMEPart] {
        var result: [MIMEPart] = []
        func visit(_ part: MIMEPart) {
            result.append(part)
            for child in part.children { visit(child) }
        }
        visit(self)
        return result
    }

    /// The leaf parts (no multiparts), depth first. Encapsulated messages count as leaves.
    public var leafParts: [MIMEPart] {
        var result: [MIMEPart] = []
        func visit(_ part: MIMEPart) {
            if part.isMultipart {
                for child in part.children { visit(child) }
            } else {
                result.append(part)
            }
        }
        visit(self)
        return result
    }

    /// Finds the part with this IMAP section number. For an encapsulated message's ID this is the
    /// `message/rfc822` part itself (found before its multipart root, which shares the ID).
    public func part(withID id: String) -> MIMEPart? {
        if partID == id { return self }
        for child in children {
            if let found = child.part(withID: id) { return found }
        }
        return nil
    }
}

/// Finds `<meta charset=...>` / `<meta http-equiv=Content-Type content="...; charset=...">` near the
/// start of an HTML body.
enum HTMLCharsetSniffer {
    static func sniff(_ data: Data) -> String? {
        let limit = min(data.count, 4096)
        guard limit > 8 else { return nil }
        let b = [UInt8](data.prefix(limit))
        let needle = Array("charset".utf8)
        var from = 0
        while let i = b.firstRangeCaseInsensitive(of: needle, from: from, to: b.count) {
            var j = i + needle.count
            while j < b.count && isASCIIWhitespace(b[j]) { j += 1 }
            guard j < b.count, b[j] == ASCII.equals else { from = i + 1; continue }
            j += 1
            while j < b.count && (isASCIIWhitespace(b[j]) || b[j] == ASCII.quote || b[j] == ASCII.apostrophe) { j += 1 }
            let start = j
            while j < b.count, isASCIILetter(b[j]) || isASCIIDigit(b[j]) || b[j] == ASCII.dash || b[j] == ASCII.underscore || b[j] == ASCII.colon || b[j] == ASCII.dot {
                j += 1
            }
            if j > start { return String(decoding: b[start..<j], as: UTF8.self) }
            from = i + 1
        }
        return nil
    }
}
