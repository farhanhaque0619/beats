import Foundation

/// A message's MIME tree from BODYSTRUCTURE, with IMAP section numbers on every node.
///
/// Section numbers follow RFC 3501 §6.4.5: a single-part message's body is `"1"`; a top-level
/// multipart is `""` with children `"1"`, `"2"`, …; nested parts are `"2.1"`, `"2.2"`; the body of
/// a message/rfc822 part at `"3"` is `"3.1"` when single-part, or children `"3.1"`, `"3.2"` when
/// multipart.
public indirect enum BodyStructure: Hashable, Sendable {
    case single(BodyPart)
    case multipart(BodyMultipart)
}

/// One non-multipart MIME part.
public struct BodyPart: Hashable, Sendable {
    /// IMAP section number, e.g. `"1"`, `"1.2"`.
    public var section: String
    /// Lowercased media type, e.g. `"text"`.
    public var type: String
    /// Lowercased subtype, e.g. `"plain"`.
    public var subtype: String
    /// Content-Type parameters with lowercased keys (values raw, e.g. `charset`, `name`).
    public var parameters: [String: String]
    /// Content-ID as sent, usually with angle brackets.
    public var id: String?
    /// Content-Description as sent.
    public var description: String?
    /// Lowercased Content-Transfer-Encoding, e.g. `"base64"`; `"7bit"` when unknown.
    public var encoding: String
    /// Size of the encoded body in bytes.
    public var size: Int
    /// Line count for text/* and message/rfc822 parts.
    public var lines: Int?
    /// Content-MD5 as sent (rarely present).
    public var md5: String?
    /// Lowercased disposition type, e.g. `"attachment"`, `"inline"`.
    public var disposition: String?
    /// Content-Disposition parameters with lowercased keys.
    public var dispositionParameters: [String: String]
    /// Content-Language tags.
    public var language: [String]
    /// Content-Location as sent.
    public var location: String?
    /// For message/rfc822 (and message/global): the attached message's envelope and structure.
    public var message: EncapsulatedMessage?

    public init(section: String, type: String, subtype: String, parameters: [String: String] = [:], id: String? = nil,
                description: String? = nil, encoding: String = "7bit", size: Int = 0, lines: Int? = nil, md5: String? = nil,
                disposition: String? = nil, dispositionParameters: [String: String] = [:], language: [String] = [],
                location: String? = nil, message: EncapsulatedMessage? = nil) {
        self.section = section
        self.type = type
        self.subtype = subtype
        self.parameters = parameters
        self.id = id
        self.description = description
        self.encoding = encoding
        self.size = size
        self.lines = lines
        self.md5 = md5
        self.disposition = disposition
        self.dispositionParameters = dispositionParameters
        self.language = language
        self.location = location
        self.message = message
    }

    /// `type/subtype`, lowercased.
    public var mimeType: String { "\(type)/\(subtype)" }

    /// The `charset` parameter, lowercased.
    public var charset: String? { parameters["charset"]?.lowercased() }

    /// Content-ID without angle brackets.
    public var contentID: String? {
        guard var value = id?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.hasPrefix("<") { value.removeFirst() }
        if value.hasSuffix(">") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    /// The file name: disposition `filename`, else the type's `name` parameter. RFC 2231
    /// (`filename*=utf-8''…`, continuations) is joined and decoded; RFC 2047 encoded words are
    /// left as sent for InkMIME to decode.
    public var filename: String? {
        if let value = RFC2231.value(named: "filename", in: dispositionParameters), !value.isEmpty { return value }
        if let value = RFC2231.value(named: "name", in: parameters), !value.isEmpty { return value }
        return nil
    }

    /// True for message/rfc822 (or message/global) parts: an attached email.
    public var isMessage: Bool { type == "message" && (subtype == "rfc822" || subtype == "global") }

    /// Whether this part is something the user would see as an attachment. `inRelated` is
    /// true when the parent is multipart/related, where parts with a Content-ID are images
    /// referenced from the HTML rather than attachments.
    public func isAttachment(inRelated: Bool = false) -> Bool {
        // Signature parts of multipart/signed are plumbing, not files the user sent.
        if type == "application", ["pgp-signature", "pkcs7-signature", "x-pkcs7-signature", "pgp-encrypted"].contains(subtype) {
            return false
        }
        if disposition == "attachment" { return true }
        if isMessage { return true }
        if type == "multipart" { return false }
        if inRelated, contentID != nil { return false }
        if type == "text" {
            guard filename != nil else { return false }
            // Inline body text that merely carries a name (some mailers do this) stays body text.
            if disposition == "inline", subtype == "plain" || subtype == "html" { return false }
            return true
        }
        return true
    }
}

/// The message inside a message/rfc822 part.
public struct EncapsulatedMessage: Hashable, Sendable {
    /// The attached message's ENVELOPE (nil if the server sent NIL).
    public var envelope: IMAPEnvelope?
    /// The attached message's MIME tree, numbered under the attachment's section.
    public var body: BodyStructure
    /// Size of the attached message in lines.
    public var lines: Int?

    public init(envelope: IMAPEnvelope?, body: BodyStructure, lines: Int?) {
        self.envelope = envelope
        self.body = body
        self.lines = lines
    }
}

/// A multipart node.
public struct BodyMultipart: Hashable, Sendable {
    /// IMAP section number; `""` for the message's top-level multipart.
    public var section: String
    /// Lowercased subtype, e.g. `"mixed"`, `"alternative"`, `"related"`.
    public var subtype: String
    /// Child parts in order (sections `<section>.1`, `<section>.2`, …).
    public var parts: [BodyStructure]
    /// Parameters with lowercased keys (e.g. `boundary`).
    public var parameters: [String: String]
    public var disposition: String?
    public var dispositionParameters: [String: String]
    public var language: [String]
    public var location: String?

    public init(section: String, subtype: String, parts: [BodyStructure], parameters: [String: String] = [:],
                disposition: String? = nil, dispositionParameters: [String: String] = [:], language: [String] = [],
                location: String? = nil) {
        self.section = section
        self.subtype = subtype
        self.parts = parts
        self.parameters = parameters
        self.disposition = disposition
        self.dispositionParameters = dispositionParameters
        self.language = language
        self.location = location
    }

    /// Always `"multipart"`.
    public var type: String { "multipart" }
    public var mimeType: String { "multipart/\(subtype)" }
}

extension BodyStructure {
    /// IMAP section number of this node.
    public var section: String {
        switch self {
        case .single(let part): return part.section
        case .multipart(let multipart): return multipart.section
        }
    }

    /// Lowercased media type.
    public var type: String {
        switch self {
        case .single(let part): return part.type
        case .multipart: return "multipart"
        }
    }

    /// Lowercased subtype.
    public var subtype: String {
        switch self {
        case .single(let part): return part.subtype
        case .multipart(let multipart): return multipart.subtype
        }
    }

    public var mimeType: String { "\(type)/\(subtype)" }

    /// Every non-multipart part in order, not descending into attached messages.
    public var leafParts: [BodyPart] {
        switch self {
        case .single(let part): return [part]
        case .multipart(let multipart): return multipart.parts.flatMap(\.leafParts)
        }
    }

    /// The node with the given section number, searching attached messages too. For an
    /// attached message whose body is multipart, the message/rfc822 part itself is returned
    /// (both share the section number).
    public func part(section: String) -> BodyStructure? {
        if self.section == section { return self }
        switch self {
        case .single(let part):
            return part.message?.body.part(section: section)
        case .multipart(let multipart):
            for child in multipart.parts {
                if let found = child.part(section: section) { return found }
            }
            return nil
        }
    }

    /// The part to show as the message text: text/plain over text/html, skipping attachments
    /// and attached messages (unless the message has no text of its own).
    public func preferredTextPart() -> (section: String, part: BodyPart)? {
        var candidates = TextCandidates()
        collectText(parentSubtype: nil, into: &candidates)
        if let part = candidates.plain.first ?? candidates.html.first { return (part.section, part) }
        for message in candidates.messages {
            if let found = message.message?.body.preferredTextPart() { return found }
        }
        return nil
    }

    /// The first text/plain body part (not an attachment).
    public var plainTextPart: (section: String, part: BodyPart)? {
        var candidates = TextCandidates()
        collectText(parentSubtype: nil, into: &candidates)
        if let part = candidates.plain.first { return (part.section, part) }
        for message in candidates.messages {
            if let found = message.message?.body.plainTextPart { return found }
        }
        return nil
    }

    /// The first text/html body part (not an attachment).
    public var htmlPart: (section: String, part: BodyPart)? {
        var candidates = TextCandidates()
        collectText(parentSubtype: nil, into: &candidates)
        if let part = candidates.html.first { return (part.section, part) }
        for message in candidates.messages {
            if let found = message.message?.body.htmlPart { return found }
        }
        return nil
    }

    /// Parts the user would see as attachments, in order. Attached messages count as one
    /// attachment each; inline images inside multipart/related don't count.
    public var attachmentParts: [BodyPart] {
        var result: [BodyPart] = []
        collectAttachments(parentSubtype: nil, into: &result)
        return result
    }

    /// Images and other parts referenced from the HTML by Content-ID (multipart/related).
    public var inlineParts: [BodyPart] {
        var result: [BodyPart] = []
        collectInline(parentSubtype: nil, into: &result)
        return result
    }

    /// True when `attachmentParts` isn't empty.
    public var hasAttachments: Bool { !attachmentParts.isEmpty }

    private struct TextCandidates {
        var plain: [BodyPart] = []
        var html: [BodyPart] = []
        var messages: [BodyPart] = []
    }

    private func collectText(parentSubtype: String?, into candidates: inout TextCandidates) {
        switch self {
        case .multipart(let multipart):
            for child in multipart.parts { child.collectText(parentSubtype: multipart.subtype, into: &candidates) }
        case .single(let part):
            if part.isMessage {
                candidates.messages.append(part)
                return
            }
            guard part.type == "text", !part.isAttachment(inRelated: parentSubtype == "related") else { return }
            if part.subtype == "plain" {
                candidates.plain.append(part)
            } else if part.subtype == "html" {
                candidates.html.append(part)
            }
        }
    }

    private func collectAttachments(parentSubtype: String?, into result: inout [BodyPart]) {
        switch self {
        case .multipart(let multipart):
            for child in multipart.parts { child.collectAttachments(parentSubtype: multipart.subtype, into: &result) }
        case .single(let part):
            if part.isAttachment(inRelated: parentSubtype == "related") { result.append(part) }
        }
    }

    private func collectInline(parentSubtype: String?, into result: inout [BodyPart]) {
        switch self {
        case .multipart(let multipart):
            for child in multipart.parts { child.collectInline(parentSubtype: multipart.subtype, into: &result) }
        case .single(let part):
            if part.contentID != nil, part.type != "text", !part.isMessage,
               parentSubtype == "related" || part.disposition == "inline" {
                result.append(part)
            }
        }
    }
}

/// RFC 2231 parameter value handling (`name*=charset'lang'%XX`, `name*0*=…`, `name*1=…`).
enum RFC2231 {
    /// The value of `name` in `parameters` (keys lowercased), joining continuations and
    /// percent-decoding extended values.
    static func value(named name: String, in parameters: [String: String]) -> String? {
        if let plain = parameters[name] { return plain }
        if let extended = parameters[name + "*"] { return decodeExtended(extended, charset: nil).text }

        var segments: [(index: Int, value: String, encoded: Bool)] = []
        let prefix = name + "*"
        for (key, value) in parameters where key.hasPrefix(prefix) {
            var rest = key.dropFirst(prefix.count)
            var encoded = false
            if rest.hasSuffix("*") {
                encoded = true
                rest = rest.dropLast()
            }
            guard let index = Int(rest), index >= 0, index < 1000 else { continue }
            segments.append((index, value, encoded))
        }
        guard !segments.isEmpty else { return nil }
        segments.sort { $0.index < $1.index }

        var charset: String?
        var bytes: [UInt8] = []
        for (position, segment) in segments.enumerated() {
            if segment.encoded {
                if position == 0 {
                    let decoded = decodeExtended(segment.value, charset: nil)
                    charset = decoded.charset
                    bytes.append(contentsOf: decoded.bytes)
                } else {
                    bytes.append(contentsOf: percentDecode(Substring(segment.value)))
                }
            } else {
                bytes.append(contentsOf: Array(segment.value.utf8))
            }
        }
        return decodeBytes(bytes, charset: charset)
    }

    /// Splits `charset'language'value` and percent-decodes the value.
    static func decodeExtended(_ value: String, charset fallback: String?) -> (text: String, charset: String?, bytes: [UInt8]) {
        let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        let charset: String?
        let encodedValue: Substring
        if pieces.count == 3 {
            charset = pieces[0].isEmpty ? fallback : String(pieces[0])
            encodedValue = pieces[2]
        } else {
            charset = fallback
            encodedValue = Substring(value)
        }
        let bytes = percentDecode(encodedValue)
        return (decodeBytes(bytes, charset: charset), charset, bytes)
    }

    static func percentDecode(_ value: Substring) -> [UInt8] {
        let utf8 = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(utf8.count)
        var index = 0
        while index < utf8.count {
            let byte = utf8[index]
            if byte == UInt8(ascii: "%"), index + 2 < utf8.count,
               let high = hexValue(utf8[index + 1]), let low = hexValue(utf8[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// Decodes with the charsets that matter for file names; anything else is tried as UTF-8,
    /// then Latin-1 (which never fails).
    static func decodeBytes(_ bytes: [UInt8], charset: String?) -> String {
        switch charset?.lowercased() {
        case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "l1":
            return IMAPText.latin1(bytes)
        case "windows-1252", "cp1252":
            if let text = String(data: Data(bytes), encoding: .windowsCP1252) { return text }
            return IMAPText.latin1(bytes)
        default:
            return IMAPText.decode(bytes)
        }
    }
}
