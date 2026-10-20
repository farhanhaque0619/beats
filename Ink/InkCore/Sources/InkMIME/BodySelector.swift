import Foundation
import InkModel

/// Picks what to show from a MIME tree: the plain and HTML bodies and the attachments.
///
/// - `multipart/alternative`: the last alternative with HTML provides the HTML, the last
///   plain-text alternative the plain text; non-text alternatives (`text/calendar`, files) are
///   attachments, other text flavours (`text/enriched`, AMP, watch HTML) are ignored.
/// - `multipart/related`: the root (by `start`, else the first part) is the body; the rest are
///   resources, inline when the HTML references their Content-ID.
/// - `multipart/mixed` and anything unknown: inline text parts are the body, in order, joined;
///   everything else is an attachment.
/// - `multipart/signed`: the signed content; the signature part is dropped.
/// - `message/rfc822`: an attachment (`.eml`) and, unless it is `Content-Disposition: attachment`,
///   also shown inline below a forwarded-message header.
enum BodySelector {
    struct Segment {
        var plain: String?
        var html: String?
    }

    struct Collected {
        var segments: [Segment] = []
        var attachments: [MIMEPart] = []

        var hasHTML: Bool { segments.contains { $0.html != nil } }
        var hasPlain: Bool { segments.contains { $0.plain != nil } }
        var isEmpty: Bool { segments.isEmpty }

        mutating func append(_ other: Collected) {
            segments += other.segments
            attachments += other.attachments
        }
    }

    struct Result {
        var plainText: String?
        var html: String?
        var attachments: [Attachment]
    }

    static let signatureTypes: Set<String> = [
        "application/pgp-signature", "application/pkcs7-signature", "application/x-pkcs7-signature",
    ]

    /// Text flavours that are only ever an alternative rendering of the body.
    static let alternativeOnlyTextTypes: Set<String> = [
        "text/enriched", "text/richtext", "text/x-amp-html", "text/watch-html", "text/x-watch-html",
    ]

    static func select(_ root: MIMEPart) -> Result {
        let collected = collect(root, depth: 0)
        let plain = joinPlain(collected.segments)
        let html = joinHTML(collected.segments)
        var seen = Set<String>()
        var attachments: [Attachment] = []
        let referenced = html.map(referencedContentIDs) ?? []
        for part in collected.attachments where seen.insert(part.partID).inserted {
            attachments.append(makeAttachment(part, referencedContentIDs: referenced))
        }
        return Result(plainText: plain, html: html, attachments: attachments)
    }

    // MARK: Walking the tree

    static func collect(_ part: MIMEPart, depth: Int) -> Collected {
        if depth > MIMEParser.maxDepth + 2 { return Collected(attachments: [part]) }
        if part.isMultipart {
            switch part.contentType.subtype {
            case "alternative": return collectAlternative(part, depth: depth)
            case "related": return collectRelated(part, depth: depth)
            case "signed": return collectSigned(part, depth: depth)
            default: return collectMixed(part, depth: depth)
            }
        }
        if part.isEncapsulatedMessage {
            return collectMessage(part, depth: depth)
        }
        if let segment = textSegment(part) {
            return Collected(segments: segment.plain == nil && segment.html == nil ? [] : [segment])
        }
        return Collected(attachments: [part])
    }

    static func collectMixed(_ part: MIMEPart, depth: Int) -> Collected {
        var result = Collected()
        for (index, child) in part.children.enumerated() {
            let collected = collect(child, depth: depth + 1)
            result.append(collected)
            // A named text file that asks to be shown inline (Apple Mail attaches .txt files with
            // `Content-Disposition: inline`) is shown in the body and is also a file to save.
            if index > 0, !collected.segments.isEmpty, isNamedInlineText(child) {
                result.attachments.append(child)
            }
        }
        return result
    }

    static func isNamedInlineText(_ part: MIMEPart) -> Bool {
        let mimeType = part.contentType.mimeType
        return !part.isMultipart && (mimeType == "text/plain" || mimeType == "text/html")
            && part.filename != nil && part.disposition?.isInline == true
    }

    static func collectAlternative(_ part: MIMEPart, depth: Int) -> Collected {
        let results = part.children.map { collect($0, depth: depth + 1) }
        var htmlIndex = results.lastIndex { $0.hasHTML }
        let plainIndex = results.lastIndex { $0.hasPlain && !$0.hasHTML } ?? results.lastIndex { $0.hasPlain }
        // An HTML rendering with nothing to see (`<div><br></div>`, only a style sheet) must not
        // win over a plain alternative that has the actual text.
        if let index = htmlIndex, let plainIndex, plainIndex != index, !hasVisibleHTML(results[index]) {
            htmlIndex = results.indices.last { $0 != plainIndex && results[$0].hasHTML && hasVisibleHTML(results[$0]) }
        }
        var result = Collected()
        if htmlIndex != nil || plainIndex != nil {
            var segment = Segment()
            if let plainIndex { segment.plain = joinPlain(results[plainIndex].segments) }
            if let htmlIndex { segment.html = joinHTML(results[htmlIndex].segments) }
            result.segments = [segment]
            if let chosen = htmlIndex ?? plainIndex { result.attachments += results[chosen].attachments }
            // Files only the plain rendering carries (some mailers attach to the text branch alone);
            // copies of the ones the HTML branch has are skipped.
            if let htmlIndex, let plainIndex, plainIndex != htmlIndex {
                for file in results[plainIndex].attachments where !result.attachments.contains(where: { isSameFile($0, file) }) {
                    result.attachments.append(file)
                }
            }
        }
        for (index, child) in part.children.enumerated() where index != htmlIndex && index != plainIndex {
            let r = results[index]
            guard r.segments.isEmpty else { continue }
            // Pure attachments (a calendar invite next to the text) are kept; other renderings of
            // the same text (enriched, AMP) are not.
            if !child.isMultipart && alternativeOnlyTextTypes.contains(child.contentType.mimeType) { continue }
            result.attachments += r.attachments
        }
        return result
    }

    static func hasVisibleHTML(_ collected: Collected) -> Bool {
        collected.segments.contains { segment in
            guard let html = segment.html else { return false }
            let bytes = Array(html.utf8)
            return HTMLQuoteFinder.hasVisibleContent(bytes, 0..<bytes.count)
        }
    }

    static func collectRelated(_ part: MIMEPart, depth: Int) -> Collected {
        guard !part.children.isEmpty else { return Collected() }
        var rootIndex = 0
        if let start = part.contentType.parameters["start"] {
            let wanted = start.trimmingCharacters(in: CharacterSet(charactersIn: " <>\"")).lowercased()
            if let i = part.children.firstIndex(where: { $0.contentID?.lowercased() == wanted }) { rootIndex = i }
        }
        var result = collect(part.children[rootIndex], depth: depth + 1)
        for (index, child) in part.children.enumerated() where index != rootIndex {
            result.attachments += child.isMultipart ? child.leafParts : [child]
        }
        return result
    }

    static func collectSigned(_ part: MIMEPart, depth: Int) -> Collected {
        guard let first = part.children.first else { return Collected() }
        var result = collect(first, depth: depth + 1)
        for child in part.children.dropFirst() where !signatureTypes.contains(child.contentType.mimeType) {
            result.append(collect(child, depth: depth + 1))
        }
        return result
    }

    static func collectMessage(_ part: MIMEPart, depth: Int) -> Collected {
        var result = Collected(attachments: [part])
        guard part.disposition?.isAttachment != true, let embeddedRoot = part.children.first else { return result }
        let inner = collect(embeddedRoot, depth: depth + 1)
        let headers = embeddedRoot.headers
        var lines = ["---------- Forwarded message ----------"]
        for name in ["From", "Date", "Subject", "To", "Cc"] {
            if let value = headers.decoded(name), !value.isEmpty {
                lines.append("\(name): \(ParsedMessage.singleLine(value))")
            }
        }
        let headerText = lines.joined(separator: "\n")
        let innerPlain = joinPlain(inner.segments) ?? inner.segments.compactMap { $0.html.map(HTMLText.toPlainText) }.joined(separator: "\n")
        var segment = Segment(plain: headerText + "\n\n" + innerPlain)
        if inner.hasHTML {
            let headerHTML = lines.map(HTMLText.escape).joined(separator: "<br>\n")
            segment.html = "<div class=\"ink-forwarded-header\">\(headerHTML)</div>\n<div class=\"ink-forwarded\">\(joinHTML(inner.segments) ?? "")</div>"
        }
        result.segments = [segment]
        result.attachments += inner.attachments
        return result
    }

    // MARK: Leaves

    /// The text segment for an inline text/plain or text/html part; nil when the part is an attachment.
    static func textSegment(_ part: MIMEPart) -> Segment? {
        let mimeType = part.contentType.mimeType
        guard mimeType == "text/plain" || mimeType == "text/html" else { return nil }
        if part.disposition?.isAttachment == true { return nil }
        // A named text part is a file unless it explicitly asks to be shown inline.
        if part.filename != nil && part.disposition?.isInline != true { return nil }
        guard let raw = part.text() else { return nil }
        // Line endings are a wire detail: bodies use "\n". iOS Mail leaves stray byte-order marks
        // inside quoted lines; they are invisible noise in plain text.
        var text = raw.normalizedNewlines
        if mimeType == "text/plain", text.unicodeScalars.contains("\u{FEFF}") {
            text = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\u{FEFF}" }))
        }
        if text.trimmedWhitespace.isEmpty { return Segment() }
        if mimeType == "text/html" { return Segment(html: text) }
        return Segment(plain: applyFlowed(text, contentType: part.contentType))
    }

    static func applyFlowed(_ text: String, contentType: ContentType) -> String {
        guard contentType.mimeType == "text/plain",
              contentType.parameters["format"]?.trimmedWhitespace.asciiLowercased == "flowed" else { return text }
        let delSp = contentType.parameters["delsp"]?.trimmedWhitespace.asciiLowercased == "yes"
        return FlowedText.decode(text, delSp: delSp)
    }

    // MARK: Joining

    static func joinPlain(_ segments: [Segment]) -> String? {
        guard segments.contains(where: { $0.plain != nil }) else { return nil }
        var out = ""
        for segment in segments {
            guard let text = segment.plain ?? segment.html.map(HTMLText.toPlainText), !text.isEmpty else { continue }
            if !out.isEmpty && out.utf8.last != 0x0A { out += "\n" }
            out += text
        }
        return out
    }

    static func joinHTML(_ segments: [Segment]) -> String? {
        guard segments.contains(where: { $0.html != nil }) else { return nil }
        var pieces: [String] = []
        for segment in segments {
            if let html = segment.html {
                pieces.append(html)
            } else if let plain = segment.plain, !plain.isEmpty {
                pieces.append("<div class=\"ink-plain-part\" style=\"white-space: pre-wrap\">\(PlainTextHTML.render(plain))</div>")
            }
        }
        return pieces.joined(separator: "\n")
    }

    // MARK: Attachments

    static func isSameFile(_ a: MIMEPart, _ b: MIMEPart) -> Bool {
        a.contentType.mimeType == b.contentType.mimeType && a.body.count == b.body.count && a.body == b.body
    }

    /// Every `cid:` reference in the HTML, normalised (lowercased, entities and percent-escapes
    /// decoded). Matched whole, so `cid:image10` doesn't claim the part `image1`.
    static func referencedContentIDs(_ html: String) -> Set<String> {
        let b = Array(html.utf8)
        let needle = Array("cid:".utf8)
        var result = Set<String>()
        var from = 0
        while let i = b.firstRangeCaseInsensitive(of: needle, from: from, to: b.count) {
            let start = i + needle.count
            var end = start
            while end < b.count {
                let c = b[end]
                if isASCIIWhitespace(c) || c == ASCII.quote || c == ASCII.apostrophe || c == ASCII.lt || c == ASCII.gt
                    || c == ASCII.rparen || c == ASCII.lparen { break }
                end += 1
            }
            if end > start {
                let raw = HTMLText.decodeEntities(b, range: start..<end, inAttribute: true)
                result.insert(normalizedContentID(raw))
                if let unescaped = raw.removingPercentEncoding { result.insert(normalizedContentID(unescaped)) }
            }
            from = max(end, i + 1)
        }
        return result
    }

    static func normalizedContentID(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
    }

    static func makeAttachment(_ part: MIMEPart, referencedContentIDs: Set<String>) -> Attachment {
        var isInline = false
        if let cid = part.contentID {
            isInline = referencedContentIDs.contains(normalizedContentID(cid))
        }
        let mimeType = part.contentType.mimeType
        return Attachment(
            id: part.partID,
            filename: part.filename ?? defaultFilename(part),
            mimeType: mimeType,
            size: part.body.count,
            contentID: part.contentID,
            isInline: isInline,
            data: part.body
        )
    }

    static let extensions: [String: String] = [
        "image/jpeg": "jpg", "image/jpg": "jpg", "image/pjpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp",
        "image/heic": "heic", "image/heif": "heif", "image/tiff": "tiff", "image/bmp": "bmp", "image/svg+xml": "svg",
        "application/pdf": "pdf", "text/plain": "txt", "text/html": "html", "text/calendar": "ics", "application/ics": "ics",
        "text/csv": "csv", "text/vcard": "vcf", "text/x-vcard": "vcf", "application/zip": "zip", "application/json": "json",
        "application/msword": "doc", "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.ms-excel": "xls", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.ms-powerpoint": "ppt", "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "audio/mpeg": "mp3", "audio/mp4": "m4a", "video/mp4": "mp4", "video/quicktime": "mov", "message/rfc822": "eml",
        "message/global": "eml", "message/delivery-status": "txt", "text/rfc822-headers": "txt", "application/pgp-keys": "asc",
    ]

    static func defaultFilename(_ part: MIMEPart) -> String {
        let mimeType = part.contentType.mimeType
        if mimeType == "application/ms-tnef" || mimeType == "application/vnd.ms-tnef" { return "winmail.dat" }
        if part.isEncapsulatedMessage {
            let subject = part.children.first?.headers.decoded("Subject").map(ParsedMessage.singleLine) ?? ""
            let safe = HeaderParameters.sanitizeFilename(String(subject.prefix(80))) ?? "Forwarded Message"
            return safe + ".eml"
        }
        if mimeType == "text/calendar" || mimeType == "application/ics" { return "invite.ics" }
        let base: String
        switch part.contentType.type {
        case "image": base = "Image"
        case "audio": base = "Audio"
        case "video": base = "Video"
        default: base = "Attachment"
        }
        let ext = extensions[mimeType] ?? ""
        return ext.isEmpty ? "\(base) \(part.partID)" : "\(base) \(part.partID).\(ext)"
    }
}

/// `format=flowed` (RFC 3676) decoding.
public enum FlowedText {
    /// Unwraps soft-wrapped lines: a line ending in a space continues on the next line of the same
    /// quote depth. Removes space-stuffing, and with `delSp` the soft-break space itself. Quoted lines
    /// come back as `> text` (`>> text` for deeper levels). The signature separator `-- ` is a hard break.
    public static func decode(_ text: String, delSp: Bool) -> String {
        let lines = text.normalizedNewlines.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var paragraph = ""
        var paragraphDepth = -1
        var open = false

        func emit(_ raw: String, depth: Int, trimTrailing: Bool = false) {
            var content = raw
            if trimTrailing && content != "-- " {
                while content.hasSuffix(" ") { content.removeLast() }
            }
            out.append(depth > 0 ? String(repeating: ">", count: depth) + (content.isEmpty ? "" : " ") + content : content)
        }

        for line in lines {
            var depth = 0
            var scalars = Substring(line)
            while scalars.first == ">" { depth += 1; scalars = scalars.dropFirst() }
            if scalars.first == " " { scalars = scalars.dropFirst() }   // space-stuffing
            var content = String(scalars)
            let isSignature = content == "-- "
            let flowed = !isSignature && content.hasSuffix(" ")
            if flowed && delSp { content.removeLast() }

            if open && depth != paragraphDepth {
                // Quote depth changed: the open paragraph ends here.
                emit(paragraph, depth: paragraphDepth, trimTrailing: true)
                paragraph = ""
                open = false
            }
            if open {
                paragraph += content
            } else {
                paragraph = content
                paragraphDepth = depth
                open = true
            }
            if !flowed {
                emit(paragraph, depth: paragraphDepth)
                paragraph = ""
                open = false
            }
        }
        if open { emit(paragraph, depth: paragraphDepth, trimTrailing: true) }
        return out.joined(separator: "\n")
    }
}
