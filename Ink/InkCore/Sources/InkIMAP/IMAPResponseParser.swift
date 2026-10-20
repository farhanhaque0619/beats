import Foundation
import InkModel

/// Errors from the response parser. They mean the byte stream can't be trusted any more.
public enum IMAPParseError: Error, Sendable, Equatable {
    /// A literal announced more bytes than the parser accepts.
    case literalTooLarge(Int)
    /// A line grew past the limit without a line break.
    case lineTooLong
}

/// Incremental IMAP response parser.
///
/// Feed it bytes as they arrive with `append(_:)`, then call `next()` until it returns nil.
/// It works on raw bytes across arbitrary read boundaries: a CRLF or a `{n}` literal can be
/// split anywhere. Literal bytes are skipped over in O(1) per read, so a 25 MB attachment
/// arriving in small chunks costs no rescanning.
///
/// Parsing is tolerant: a malformed response becomes the best interpretation possible (or
/// `.untagged(.other(line))`) rather than an error. Only framing failures (absurd literal
/// sizes, endless lines) throw.
public struct IMAPResponseParser: Sendable {
    /// Largest literal accepted (bytes).
    public var maxLiteralSize: Int
    /// Longest line accepted without a line break (bytes).
    public var maxLineLength: Int
    /// After `ENABLE UTF8=ACCEPT`, mailbox names are UTF-8 rather than modified UTF-7.
    public var utf8Mode = false
    /// When true, `lastResponseSummary` is set for each response (for protocol logs; literal
    /// contents are elided).
    public var capturesSummary = false
    /// A one-line, literal-free rendering of the last response returned by `next()`.
    public private(set) var lastResponseSummary: String?

    private var buffer: [UInt8] = []
    /// Start of the response being framed.
    private var start = 0
    /// Where the search for the next line break resumes.
    private var scan = 0
    /// Start of the current line segment (after the last literal).
    private var lineStart = 0
    /// Literal bytes still to skip before the line continues.
    private var literalRemaining = 0
    /// Whether the response being framed is a status/continuation line (never has literals).
    private var frameIsStatus: Bool?
    /// Literal ranges of the frame (only tracked when capturing summaries).
    private var literalRanges: [Range<Int>] = []

    public init(maxLiteralSize: Int = 512 * 1024 * 1024, maxLineLength: Int = 64 * 1024 * 1024) {
        self.maxLiteralSize = maxLiteralSize
        self.maxLineLength = maxLineLength
    }

    /// Bytes received but not yet returned as responses.
    public var bufferedByteCount: Int { buffer.count - start }

    /// Adds bytes read from the server.
    public mutating func append(_ data: Data) {
        compact()
        buffer.append(contentsOf: data)
    }

    /// Adds bytes read from the server.
    public mutating func append(_ bytes: [UInt8]) {
        compact()
        buffer.append(contentsOf: bytes)
    }

    /// Drops everything buffered (after STARTTLS nothing sent before the handshake may be used).
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        start = 0
        scan = 0
        lineStart = 0
        literalRemaining = 0
        frameIsStatus = nil
        literalRanges.removeAll()
    }

    /// The next complete response, or nil when more bytes are needed.
    public mutating func next() throws -> IMAPResponse? {
        while true {
            guard let frameEnd = try frameNext() else { return nil }
            let frameStart = start
            start = frameEnd
            scan = frameEnd
            lineStart = frameEnd
            frameIsStatus = nil
            if capturesSummary {
                lastResponseSummary = summary(from: frameStart, to: frameEnd)
            }
            literalRanges.removeAll(keepingCapacity: true)
            if let response = IMAPResponseDecoder.decode(bytes: buffer, start: frameStart, end: frameEnd, utf8Mode: utf8Mode) {
                return response
            }
            // A blank line: skip it.
        }
    }

    /// Parses every complete response in `text` (a convenience for tests and tools).
    public static func parseAll(_ text: String, utf8Mode: Bool = false) throws -> [IMAPResponse] {
        var parser = IMAPResponseParser()
        parser.utf8Mode = utf8Mode
        parser.append(Data(text.utf8))
        var responses: [IMAPResponse] = []
        while let response = try parser.next() { responses.append(response) }
        return responses
    }

    // MARK: Framing

    /// Advances over the buffer; returns the end index (exclusive) of a complete response.
    private mutating func frameNext() throws -> Int? {
        while true {
            if literalRemaining > 0 {
                let available = buffer.count - scan
                if available < literalRemaining {
                    literalRemaining -= available
                    scan = buffer.count
                    return nil
                }
                scan += literalRemaining
                literalRemaining = 0
                lineStart = scan
                continue
            }
            guard let lineFeed = indexOfLineFeed(from: scan) else {
                scan = buffer.count
                if buffer.count - lineStart > maxLineLength { throw IMAPParseError.lineTooLong }
                return nil
            }
            var contentEnd = lineFeed
            if contentEnd > lineStart, buffer[contentEnd - 1] == Byte.cr { contentEnd -= 1 }
            if frameIsStatus == nil {
                frameIsStatus = Self.isStatusLine(buffer, from: start, to: contentEnd)
            }
            if frameIsStatus == false, let length = Self.literalLength(buffer, from: lineStart, to: contentEnd) {
                guard length <= maxLiteralSize else { throw IMAPParseError.literalTooLarge(length) }
                scan = lineFeed + 1
                lineStart = scan
                literalRemaining = length
                if capturesSummary { literalRanges.append(scan..<(scan + length)) }
                continue
            }
            return lineFeed + 1
        }
    }

    private func indexOfLineFeed(from index: Int) -> Int? {
        buffer.withUnsafeBufferPointer { pointer -> Int? in
            var position = index
            let count = pointer.count
            while position < count {
                if pointer[position] == Byte.lf { return position }
                position += 1
            }
            return nil
        }
    }

    private mutating func compact() {
        guard start > 0 else { return }
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else if start >= 16 * 1024, start * 2 >= buffer.count {
            buffer.removeFirst(start)
        } else {
            return
        }
        let shift = start
        start = 0
        scan -= shift
        lineStart -= shift
        literalRanges = literalRanges.map { ($0.lowerBound - shift)..<($0.upperBound - shift) }
    }

    /// Continuations and `OK/NO/BAD/BYE/PREAUTH` lines can't contain literals, so a text that
    /// happens to end in `{5}` isn't mistaken for one.
    static func isStatusLine(_ bytes: [UInt8], from start: Int, to end: Int) -> Bool {
        guard start < end else { return true }
        if bytes[start] == Byte.plus { return true }
        var index = start
        while index < end, bytes[index] != Byte.space { index += 1 }
        index += 1
        guard index < end else { return false }
        let wordStart = index
        while index < end, bytes[index] != Byte.space, bytes[index] != Byte.openBracket { index += 1 }
        let length = index - wordStart
        guard length >= 2, length <= 7 else { return false }
        var word: [UInt8] = []
        for position in wordStart..<index {
            let byte = bytes[position]
            word.append(byte >= 0x61 && byte <= 0x7A ? byte - 0x20 : byte)
        }
        switch word {
        case Array("OK".utf8), Array("NO".utf8), Array("BAD".utf8), Array("BYE".utf8), Array("PREAUTH".utf8):
            return true
        default:
            return false
        }
    }

    /// The length of a `{n}` / `{n+}` literal announced at the end of a line.
    static func literalLength(_ bytes: [UInt8], from start: Int, to end: Int) -> Int? {
        var index = end - 1
        guard index > start, bytes[index] == Byte.closeBrace else { return nil }
        index -= 1
        if bytes[index] == Byte.plus { index -= 1 }
        var value = 0
        var multiplier = 1
        var digits = 0
        while index >= start, Byte.isDigit(bytes[index]) {
            digits += 1
            if digits > 12 { return nil }
            value += Int(bytes[index] - Byte.zero) * multiplier
            multiplier *= 10
            index -= 1
        }
        guard digits > 0, index >= start, bytes[index] == Byte.openBrace else { return nil }
        return value
    }

    private func summary(from start: Int, to end: Int) -> String {
        var output: [UInt8] = []
        var index = start
        var rangeIndex = 0
        let limit = 2000
        while index < end, output.count < limit {
            if rangeIndex < literalRanges.count, index == literalRanges[rangeIndex].lowerBound {
                output.append(contentsOf: Array("<\(literalRanges[rangeIndex].count) bytes>".utf8))
                index = literalRanges[rangeIndex].upperBound
                rangeIndex += 1
                continue
            }
            let byte = buffer[index]
            if byte != Byte.cr, byte != Byte.lf { output.append(byte) } else if index + 1 < end, byte == Byte.lf { output.append(Byte.space) }
            index += 1
        }
        var text = IMAPText.decode(output)
        if index < end { text += "…" }
        return text
    }
}

// MARK: - Interpretation

/// Turns the bytes of one framed response into an `IMAPResponse`.
enum IMAPResponseDecoder {
    static func decode(bytes: [UInt8], start: Int, end: Int, utf8Mode: Bool) -> IMAPResponse? {
        var reader = IMAPReader(bytes: bytes, start: start, end: end)
        guard !reader.isAtLineEnd else { return nil }
        let first = bytes[start]
        if first == Byte.plus {
            reader.position += 1
            return .continuation(reader.readRestOfLine())
        }
        if first == Byte.star {
            reader.position += 1
            return .untagged(decodeUntagged(&reader, lineStart: start, utf8Mode: utf8Mode))
        }
        let tag = reader.readWord()
        reader.skipSpaces()
        let word = reader.readWord().uppercased()
        let status: IMAPResponseStatus
        switch word {
        case "OK": status = .ok
        case "NO": status = .no
        case "BAD": status = .bad
        default:
            // Not a valid completion; report it as BAD with the whole line so it can't pass as success.
            var whole = IMAPReader(bytes: bytes, start: start, end: end)
            return .tagged(IMAPTaggedResponse(tag: tag, status: .bad, text: IMAPResponseText(text: whole.readRestOfLine())))
        }
        return .tagged(IMAPTaggedResponse(tag: tag, status: status, text: decodeResponseText(&reader)))
    }

    static func lineText(_ bytes: [UInt8], start: Int, end: Int) -> String {
        var reader = IMAPReader(bytes: bytes, start: start, end: end)
        return reader.readRestOfLine()
    }

    static func decodeUntagged(_ reader: inout IMAPReader, lineStart: Int, utf8Mode: Bool) -> IMAPUntagged {
        reader.skipSpaces()
        let lineBytes = reader.bytes
        let lineEnd = reader.end
        let otherStart = max(lineStart, reader.position)
        func other() -> IMAPUntagged { .other(lineText(lineBytes, start: otherStart, end: lineEnd)) }
        let word = reader.readWord()
        if let number = UInt32(word) {
            reader.skipSpaces()
            switch reader.readWord().uppercased() {
            case "EXISTS": return .exists(number)
            case "RECENT": return .recent(number)
            case "EXPUNGE": return .expunge(number)
            case "FETCH": return .fetch(decodeFetch(seq: number, &reader))
            default: return other()
            }
        }
        switch word.uppercased() {
        case "OK": return .ok(decodeResponseText(&reader))
        case "NO": return .no(decodeResponseText(&reader))
        case "BAD": return .bad(decodeResponseText(&reader))
        case "PREAUTH": return .preauth(decodeResponseText(&reader))
        case "BYE": return .bye(decodeResponseText(&reader).text)
        case "CAPABILITY": return .capability(reader.readValuesToLineEnd().compactMap(\.text))
        case "FLAGS": return .flags(reader.readValue()?.stringList ?? [])
        case "LIST", "XLIST":
            guard let mailbox = decodeMailbox(&reader, utf8Mode: utf8Mode) else { return other() }
            return .list(mailbox)
        case "LSUB":
            guard let mailbox = decodeMailbox(&reader, utf8Mode: utf8Mode) else { return other() }
            return .lsub(mailbox)
        case "STATUS":
            guard let (name, status) = decodeStatus(&reader) else { return other() }
            return .status(mailbox: name, status)
        case "SEARCH", "SORT":
            let (numbers, modSeq) = decodeSearch(&reader)
            return .search(numbers, modSeq: modSeq)
        case "ESEARCH": return .esearch(decodeESearch(&reader))
        case "ENABLED": return .enabled(reader.readValuesToLineEnd().compactMap(\.text))
        case "ID": return .id(decodeID(&reader))
        case "VANISHED":
            guard let vanished = decodeVanished(&reader) else { return other() }
            return vanished
        default:
            return other()
        }
    }

    // MARK: Response text and codes

    static func decodeResponseText(_ reader: inout IMAPReader) -> IMAPResponseText {
        reader.skipSpaces()
        var code: IMAPResponseCode?
        if reader.peek() == Byte.openBracket, let close = reader.responseCodeEnd() {
            var codeReader = IMAPReader(bytes: reader.bytes, start: reader.position + 1, end: close)
            code = decodeCode(&codeReader)
            reader.position = close + 1
        }
        return IMAPResponseText(code: code, text: reader.readRestOfLine())
    }

    static func decodeCode(_ reader: inout IMAPReader) -> IMAPResponseCode {
        reader.skipSpaces()
        let name = reader.readWord().uppercased()
        reader.skipSpaces()
        let snapshot = reader
        func fallback() -> IMAPResponseCode {
            var copy = snapshot
            let text = copy.readRestOfLine()
            return .other(name, text.isEmpty ? nil : text)
        }

        switch name {
        case "ALERT": return .alert
        case "PARSE": return .parse
        case "READ-ONLY": return .readOnly
        case "READ-WRITE": return .readWrite
        case "TRYCREATE": return .tryCreate
        case "NOMODSEQ": return .noModSeq
        case "UIDNOTSTICKY": return .uidNotSticky
        case "CLOSED": return .closed
        case "UNAVAILABLE": return .unavailable
        case "AUTHENTICATIONFAILED": return .authenticationFailed
        case "AUTHORIZATIONFAILED": return .authorizationFailed
        case "EXPIRED": return .expired
        case "PRIVACYREQUIRED": return .privacyRequired
        case "CONTACTADMIN": return .contactAdmin
        case "NOPERM": return .noPerm
        case "INUSE": return .inUse
        case "EXPUNGEISSUED": return .expungeIssued
        case "CORRUPTION": return .corruption
        case "SERVERBUG": return .serverBug
        case "CLIENTBUG": return .clientBug
        case "CANNOT": return .cannot
        case "LIMIT": return .limit
        case "OVERQUOTA": return .overQuota
        case "ALREADYEXISTS": return .alreadyExists
        case "NONEXISTENT": return .nonExistent
        case "UIDNEXT", "UIDVALIDITY", "UNSEEN":
            guard let number = reader.readValue()?.uint32 else { return fallback() }
            switch name {
            case "UIDNEXT": return .uidNext(number)
            case "UIDVALIDITY": return .uidValidity(number)
            default: return .unseen(number)
            }
        case "HIGHESTMODSEQ":
            guard let number = reader.readValue()?.uint64 else { return fallback() }
            return .highestModSeq(number)
        case "PERMANENTFLAGS":
            return .permanentFlags(reader.readValue()?.stringList ?? [])
        case "CAPABILITY":
            return .capability(reader.readValuesToLineEnd().compactMap(\.text))
        case "BADCHARSET":
            return .badCharset(reader.readValue()?.stringList ?? [])
        case "COPYUID":
            guard let validity = reader.readValue()?.uint32,
                  let source = reader.readValue()?.text.flatMap(IMAPSequenceSet.init),
                  let destination = reader.readValue()?.text.flatMap(IMAPSequenceSet.init) else { return fallback() }
            return .copyUID(uidValidity: validity, source: source, destination: destination)
        case "APPENDUID":
            guard let validity = reader.readValue()?.uint32,
                  let uids = reader.readValue()?.text.flatMap(IMAPSequenceSet.init) else { return fallback() }
            return .appendUID(uidValidity: validity, uids: uids)
        case "MODIFIED":
            guard let set = reader.readValue()?.text.flatMap(IMAPSequenceSet.init) else { return fallback() }
            return .modified(set)
        default:
            return fallback()
        }
    }

    // MARK: Mailboxes

    static func decodeMailbox(_ reader: inout IMAPReader, utf8Mode: Bool) -> IMAPMailbox? {
        guard let attributesValue = reader.readValue() else { return nil }
        let attributes: [String]
        switch attributesValue {
        case .list: attributes = attributesValue.stringList ?? []
        case .atom(let atom): attributes = [atom]
        case .string, .nilValue: attributes = []
        }
        guard let delimiterValue = reader.readValue() else { return nil }
        let delimiter: String? = delimiterValue.isNil ? nil : delimiterValue.text
        guard let nameValue = reader.readValue() else { return nil }
        let rawName: String
        switch nameValue {
        case .nilValue: rawName = "NIL"
        case .list: return nil
        default: rawName = nameValue.text ?? ""
        }
        let name = utf8Mode ? rawName : ModifiedUTF7.decode(rawName)
        return IMAPMailbox(rawName: rawName, name: name, delimiter: delimiter?.isEmpty == true ? nil : delimiter, attributes: attributes)
    }

    static func decodeStatus(_ reader: inout IMAPReader) -> (String, IMAPStatus)? {
        guard let nameValue = reader.readValue(), case .list(let items)? = reader.readValue() else { return nil }
        let name = nameValue.isNil ? "NIL" : (nameValue.text ?? "")
        var status = IMAPStatus()
        var index = 0
        while index + 1 < items.count {
            let key = items[index].text?.uppercased() ?? ""
            let value = items[index + 1]
            switch key {
            case "MESSAGES": status.messages = value.uint32
            case "RECENT": status.recent = value.uint32
            case "UIDNEXT": status.uidNext = value.uint32
            case "UIDVALIDITY": status.uidValidity = value.uint32
            case "UNSEEN": status.unseen = value.uint32
            case "HIGHESTMODSEQ": status.highestModSeq = value.uint64
            case "SIZE": status.size = value.uint64
            default: break
            }
            index += 2
        }
        return (name, status)
    }

    // MARK: Search

    static func decodeSearch(_ reader: inout IMAPReader) -> ([UInt32], UInt64?) {
        var numbers: [UInt32] = []
        var modSeq: UInt64?
        while true {
            reader.skipSpaces()
            guard !reader.isAtLineEnd else { break }
            if let number = reader.readNumber() {
                if let value = UInt32(exactly: number) { numbers.append(value) }
                continue
            }
            guard let value = reader.readValue() else {
                reader.position += 1
                continue
            }
            if case .list(let items) = value, items.count >= 2, items[0].text?.uppercased() == "MODSEQ" {
                modSeq = items[1].uint64
            }
        }
        return (numbers, modSeq)
    }

    static func decodeESearch(_ reader: inout IMAPReader) -> IMAPESearchResponse {
        var result = IMAPESearchResponse()
        var values = reader.readValuesToLineEnd()[...]
        if case .list(let correlator)? = values.first {
            if correlator.count >= 2, correlator[0].text?.uppercased() == "TAG" { result.tag = correlator[1].text }
            values = values.dropFirst()
        }
        while let value = values.first {
            values = values.dropFirst()
            guard let key = value.text?.uppercased() else { continue }
            if key == "UID" {
                result.isUID = true
                continue
            }
            guard let argument = values.first else { break }
            values = values.dropFirst()
            switch key {
            case "MIN": result.min = argument.uint32
            case "MAX": result.max = argument.uint32
            case "COUNT": result.count = argument.int
            case "ALL": result.all = argument.text.flatMap(IMAPSequenceSet.init)
            case "MODSEQ": result.modSeq = argument.uint64
            default: break
            }
        }
        return result
    }

    static func decodeID(_ reader: inout IMAPReader) -> [String: String] {
        guard case .list(let items)? = reader.readValue() else { return [:] }
        var fields: [String: String] = [:]
        var index = 0
        while index + 1 < items.count {
            if let key = items[index].text, let value = items[index + 1].text {
                fields[key.lowercased()] = value
            }
            index += 2
        }
        return fields
    }

    static func decodeVanished(_ reader: inout IMAPReader) -> IMAPUntagged? {
        var earlier = false
        reader.skipSpaces()
        if reader.peek() == Byte.openParen, let modifiers = reader.readValue()?.stringList {
            earlier = modifiers.contains { $0.uppercased() == "EARLIER" }
        }
        guard let set = reader.readValue()?.text.flatMap(IMAPSequenceSet.init) else { return nil }
        return .vanished(set, earlier: earlier)
    }

    // MARK: Fetch

    static func decodeFetch(seq: UInt32, _ reader: inout IMAPReader) -> IMAPFetchResponse {
        var response = IMAPFetchResponse(seq: seq)
        guard case .list(let items)? = reader.readValue() else { return response }
        var index = 0
        while index < items.count {
            guard case .atom(let rawName) = items[index] else {
                index += 1
                continue
            }
            let value: IMAPValue? = index + 1 < items.count ? items[index + 1] : nil
            index += 2
            guard let value else { break }
            let name = rawName.uppercased()
            switch name {
            case "UID":
                response.uid = value.uint32
            case "FLAGS":
                response.flags = value.stringList ?? []
            case "INTERNALDATE":
                response.internalDate = value.text.flatMap(IMAPDate.parseInternalDate)
            case "RFC822.SIZE":
                response.size = value.int
            case "ENVELOPE":
                response.envelope = decodeEnvelope(value)
            case "BODYSTRUCTURE", "BODY":
                response.bodyStructure = BodyStructureDecoder.decode(value)
            case "RFC822":
                if let data = sectionData(value) { response.sections[""] = data }
            case "RFC822.HEADER":
                if let data = sectionData(value) { response.sections["HEADER"] = data }
            case "RFC822.TEXT":
                if let data = sectionData(value) { response.sections["TEXT"] = data }
            case "X-GM-THRID":
                response.gmailThreadID = value.uint64
            case "X-GM-MSGID":
                response.gmailMessageID = value.uint64
            case "X-GM-LABELS":
                switch value {
                case .list: response.gmailLabels = value.stringList ?? []
                case .nilValue: response.gmailLabels = []
                default: response.gmailLabels = value.text.map { [$0] } ?? []
                }
            case "MODSEQ":
                response.modSeq = value.list?.first?.uint64 ?? value.uint64
            case "EMAILID":
                response.emailID = value.list?.first?.text ?? value.text
            case "THREADID":
                response.threadID = value.list?.first?.text ?? value.text
            case "PREVIEW":
                response.preview = value.nstring
            default:
                if name.hasPrefix("BODY[") || name.hasPrefix("BODY.PEEK[") {
                    guard let open = rawName.firstIndex(of: "["), let close = rawName.lastIndex(of: "]"), open < close else { continue }
                    let key = IMAPFetchResponse.sectionKey(String(rawName[rawName.index(after: open)..<close]))
                    if let data = sectionData(value) { response.sections[key] = data }
                    let after = rawName[rawName.index(after: close)...]
                    if after.hasPrefix("<"), let origin = Int(after.dropFirst().prefix { $0 != ">" && $0 != "." }) {
                        response.sectionOrigins[key] = origin
                    }
                }
            }
        }
        return response
    }

    private static func sectionData(_ value: IMAPValue) -> Data? {
        switch value {
        case .string(let data): return data
        case .atom(let atom): return Data(atom.utf8)
        case .nilValue, .list: return nil
        }
    }

    // MARK: Envelope

    static func decodeEnvelope(_ value: IMAPValue) -> IMAPEnvelope? {
        guard case .list(let fields) = value else { return nil }
        func field(_ index: Int) -> IMAPValue? { index < fields.count ? fields[index] : nil }
        return IMAPEnvelope(
            date: field(0)?.nstring,
            subject: field(1)?.nstring,
            from: decodeAddresses(field(2)),
            sender: decodeAddresses(field(3)),
            replyTo: decodeAddresses(field(4)),
            to: decodeAddresses(field(5)),
            cc: decodeAddresses(field(6)),
            bcc: decodeAddresses(field(7)),
            inReplyTo: field(8)?.nstring,
            messageID: field(9)?.nstring
        )
    }

    static func decodeAddresses(_ value: IMAPValue?) -> [IMAPAddress] {
        guard case .list(let items)? = value else { return [] }
        return items.compactMap { item -> IMAPAddress? in
            guard case .list(let parts) = item else { return nil }
            func part(_ index: Int) -> String? { index < parts.count ? parts[index].nstring : nil }
            return IMAPAddress(name: part(0), adl: part(1), mailbox: part(2), host: part(3))
        }
    }
}

// MARK: - BODYSTRUCTURE

/// Interprets a BODYSTRUCTURE / BODY value. Positional fields are read with defaults, so
/// missing extension data, NIL anywhere, odd spacing and atoms-for-strings are all fine.
enum BodyStructureDecoder {
    static func decode(_ value: IMAPValue) -> BodyStructure? {
        decode(value, path: [], messageRoot: true, depth: 0)
    }

    private static func decode(_ value: IMAPValue, path: [Int], messageRoot: Bool, depth: Int) -> BodyStructure? {
        guard depth < 40, case .list(let items) = value, !items.isEmpty else { return nil }
        if case .list = items[0] {
            return .multipart(decodeMultipart(items, path: path, depth: depth))
        }
        return .single(decodeSingle(items, path: messageRoot ? path + [1] : path, depth: depth))
    }

    private static func sectionString(_ path: [Int]) -> String {
        path.map(String.init).joined(separator: ".")
    }

    private static func decodeMultipart(_ items: [IMAPValue], path: [Int], depth: Int) -> BodyMultipart {
        var children: [BodyStructure] = []
        var index = 0
        while index < items.count, case .list = items[index] {
            if let child = decode(items[index], path: path + [index + 1], messageRoot: false, depth: depth + 1) {
                children.append(child)
            }
            index += 1
        }
        func field(_ offset: Int) -> IMAPValue? { index + offset < items.count ? items[index + offset] : nil }
        let subtype = field(0)?.text?.lowercased() ?? "mixed"
        let (disposition, dispositionParameters) = decodeDisposition(field(2))
        return BodyMultipart(
            section: sectionString(path),
            subtype: subtype,
            parts: children,
            parameters: decodeParameters(field(1)),
            disposition: disposition,
            dispositionParameters: dispositionParameters,
            language: decodeLanguage(field(3)),
            location: field(4)?.nstring
        )
    }

    private static func decodeSingle(_ items: [IMAPValue], path: [Int], depth: Int) -> BodyPart {
        func field(_ index: Int) -> IMAPValue? { index < items.count ? items[index] : nil }
        let type = field(0)?.text?.lowercased() ?? "application"
        let subtype = field(1)?.text?.lowercased() ?? "octet-stream"
        var part = BodyPart(
            section: sectionString(path),
            type: type,
            subtype: subtype,
            parameters: decodeParameters(field(2)),
            id: field(3)?.nstring,
            description: field(4)?.nstring,
            encoding: field(5)?.text?.lowercased() ?? "7bit",
            size: field(6)?.int ?? 0
        )
        var next = 7
        if part.isMessage, let envelopeValue = field(7), let bodyValue = field(8), case .list = bodyValue,
           envelopeValue.list != nil || envelopeValue.isNil {
            let envelope = IMAPResponseDecoder.decodeEnvelope(envelopeValue)
            if let body = decode(bodyValue, path: path, messageRoot: true, depth: depth + 1) {
                part.message = EncapsulatedMessage(envelope: envelope, body: body, lines: field(9)?.int)
            }
            part.lines = field(9)?.int
            next = 10
        } else if type == "text", let lines = field(7)?.int {
            part.lines = lines
            next = 8
        }
        part.md5 = field(next)?.nstring
        let (disposition, dispositionParameters) = decodeDisposition(field(next + 1))
        part.disposition = disposition
        part.dispositionParameters = dispositionParameters
        part.language = decodeLanguage(field(next + 2))
        part.location = field(next + 3)?.nstring
        return part
    }

    private static func decodeParameters(_ value: IMAPValue?) -> [String: String] {
        guard case .list(let items)? = value else { return [:] }
        var parameters: [String: String] = [:]
        var index = 0
        while index + 1 < items.count {
            if let key = items[index].text?.lowercased(), !key.isEmpty, parameters[key] == nil, items[index + 1].list == nil {
                parameters[key] = items[index + 1].text ?? ""
            }
            index += 2
        }
        return parameters
    }

    private static func decodeDisposition(_ value: IMAPValue?) -> (String?, [String: String]) {
        switch value {
        case .list(let items)?:
            let type = items.first?.text?.lowercased()
            return (type?.isEmpty == true ? nil : type, decodeParameters(items.count > 1 ? items[1] : nil))
        case .string?, .atom?:
            let type = value?.text?.lowercased()
            return (type?.isEmpty == true ? nil : type, [:])
        default:
            return (nil, [:])
        }
    }

    private static func decodeLanguage(_ value: IMAPValue?) -> [String] {
        switch value {
        case .list?: return value?.stringList ?? []
        case .string?, .atom?: return value?.text.map { [$0] } ?? []
        default: return []
        }
    }
}
