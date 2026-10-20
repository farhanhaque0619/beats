import Foundation
import InkModel

// The connection layer of `IMAPClient`: writing tagged commands (with synchronizing and
// non-synchronizing literals), reading complete responses through the incremental parser,
// applying untagged data to the client's state, and tearing down broken connections.
extension IMAPClient {
    /// Sends `command` with a fresh tag and reads until its completion, without judging the
    /// status. Synchronizing literals wait for the server's `+`; if the server answers the
    /// command instead (NO / BAD), the rest isn't sent. `sasl` answers continuation requests
    /// that aren't for literals (AUTHENTICATE); the returned bytes are sent followed by CRLF.
    func send(_ command: IMAPCommand, readTimeout: TimeInterval? = nil, sasl: ((String) -> Data)? = nil) async throws -> IMAPCommandResult {
        let tag = tags.next()
        commandAlert = nil
        log("C: \(tag) \(command.logDescription)")
        var untagged: [IMAPUntagged] = []
        var outgoing = Data("\(tag) ".utf8)
        var completion: IMAPTaggedResponse?

        partsLoop: for part in command.parts {
            switch part {
            case .text(let text):
                outgoing.append(text)
            case .literal(let literal, let synchronizing):
                if synchronizing {
                    try await write(outgoing)
                    outgoing = Data()
                    waiting: while true {
                        let response = try await readResponse(timeout: readTimeout)
                        switch response {
                        case .continuation:
                            break waiting
                        case .tagged(let tagged) where tagged.tag == tag:
                            completion = tagged
                            break partsLoop
                        case .tagged(let tagged):
                            log("Ignoring completion for unknown tag \(tagged.tag)")
                        case .untagged(let response):
                            handle(response)
                            untagged.append(response)
                        }
                    }
                }
                outgoing.append(literal)
            }
        }

        if completion == nil {
            if !outgoing.isEmpty { try await write(outgoing) }
            while completion == nil {
                let response = try await readResponse(timeout: readTimeout)
                switch response {
                case .tagged(let tagged) where tagged.tag == tag:
                    completion = tagged
                case .tagged(let tagged):
                    log("Ignoring completion for unknown tag \(tagged.tag)")
                case .untagged(let response):
                    handle(response)
                    untagged.append(response)
                case .continuation(let text):
                    if let sasl {
                        var reply = sasl(text)
                        log("C: [SASL response redacted]")
                        reply.append(contentsOf: [Byte.cr, Byte.lf])
                        try await write(reply)
                    } else {
                        log("Ignoring unexpected continuation request")
                    }
                }
            }
        }
        guard let tagged = completion else { throw IMAPError.unexpected("The command never completed.") }
        apply(code: tagged.text.code, text: tagged.text.text)
        return IMAPCommandResult(tag: tag, command: command.name, tagged: tagged, untagged: untagged)
    }

    /// The next complete response, reading from the transport as needed.
    func readResponse(timeout: TimeInterval? = nil) async throws -> IMAPResponse {
        while true {
            if let response = try nextBufferedResponse() { return response }
            let data = try await readChunk(timeout: timeout ?? self.timeout)
            guard !data.isEmpty else { throw TransportError.closed }
            parser.append(data)
        }
    }

    /// A response already sitting in the parser's buffer, if any.
    func nextBufferedResponse() throws -> IMAPResponse? {
        let response: IMAPResponse?
        do {
            response = try parser.next()
        } catch let error as IMAPParseError {
            throw IMAPError.parse(error)
        }
        if let response, logger != nil {
            log("S: " + (parser.lastResponseSummary ?? String(describing: response)))
        }
        return response
    }

    /// One chunk from the server. Finishes an outstanding detached read first. In a cancelled
    /// task the read runs detached, so clean-up (DONE, LOGOUT) still works.
    private func readChunk(timeout: TimeInterval) async throws -> Data {
        if pendingRead == nil, !Task.isCancelled {
            return try await transport.read(timeout: timeout)
        }
        let read = pendingRead ?? makeDetachedRead(timeout: timeout)
        pendingRead = read
        switch await IMAPReadRace.wait(for: read, timeout: timeout, cancellable: false) {
        case .data(let data):
            pendingRead = nil
            return data
        case .failure(let error):
            pendingRead = nil
            throw error
        case .deadline, .cancelled:
            throw TransportError.timeout
        }
    }

    func makeDetachedRead(timeout: TimeInterval) -> Task<Data, Error> {
        let transport = self.transport
        return Task.detached { try await transport.read(timeout: timeout) }
    }

    func write(_ data: Data) async throws {
        if Task.isCancelled {
            let transport = self.transport
            try await Task.detached { try await transport.write(data) }.value
        } else {
            try await transport.write(data)
        }
    }

    // MARK: State

    /// Applies an untagged response to the client's state.
    func handle(_ response: IMAPUntagged) {
        switch response {
        case .exists(let count):
            selectedMailbox?.exists = count
        case .recent(let count):
            selectedMailbox?.recent = count
        case .expunge:
            if let exists = selectedMailbox?.exists, exists > 0 { selectedMailbox?.exists = exists - 1 }
        case .vanished(let set, let earlier):
            if !earlier, let count = set.count, let exists = selectedMailbox?.exists {
                selectedMailbox?.exists = exists >= UInt32(clamping: count) ? exists - UInt32(clamping: count) : 0
            }
        case .flags(let flags):
            selectedMailbox?.flags = flags
        case .capability(let list):
            capabilities = Set(list.map { $0.uppercased() })
        case .ok(let text), .no(let text), .bad(let text), .preauth(let text):
            apply(code: text.code, text: text.text)
        case .bye(let text):
            byeText = text
        case .enabled(let list):
            for name in list.map({ $0.uppercased() }) {
                enabledExtensions.insert(name)
                if name == "QRESYNC" { enabledExtensions.insert("CONDSTORE") }
                if name == "UTF8=ACCEPT" || name == "UTF8=ONLY" {
                    enabledExtensions.insert("UTF8=ACCEPT")
                    parser.utf8Mode = true
                }
            }
        default:
            break
        }
    }

    /// Applies a response code from any status response.
    func apply(code: IMAPResponseCode?, text: String) {
        switch code {
        case .capability(let list)?:
            capabilities = Set(list.map { $0.uppercased() })
        case .alert?:
            let cleaned = IMAPError.clean(text)
            lastAlert = cleaned
            commandAlert = cleaned
            log("ALERT: \(cleaned)")
        case .highestModSeq(let value)?:
            if selectedMailbox != nil { selectedMailbox?.highestModSeq = value }
        case .uidNext(let value)?:
            if selectedMailbox != nil { selectedMailbox?.uidNext = value }
        default:
            break
        }
    }

    /// Converts a failure to `MailError`, closing the connection when the stream can't be
    /// trusted any more (anything but a clean NO/BAD completion).
    func handleFailure(_ error: Error) -> MailError {
        let mapped: MailError
        switch error {
        case let error as MailError:
            mapped = error
        case TransportError.closed where byeText != nil, TransportError.notConnected where byeText != nil:
            mapped = IMAPError.bye(byeText ?? "").mailError
        default:
            mapped = IMAPError.mailError(for: error)
        }
        let fatal: Bool
        switch error {
        case is TransportError, is IMAPParseError, is CancellationError:
            fatal = true
        case let error as IMAPError:
            if case .commandFailed = error { fatal = false } else { fatal = true }
        default:
            switch mapped {
            case .timeout, .connectionFailed, .tlsFailed, .cancelled: fatal = true
            case .protocolError: fatal = !(error is MailError)
            default: fatal = false
            }
        }
        if fatal, state != .disconnected {
            log("Closing the connection after: \(mapped.localizedDescription)")
            teardown()
        }
        return mapped
    }

    func teardown() {
        pendingRead?.cancel()
        pendingRead = nil
        transport.close()
        state = .disconnected
        selectedMailbox = nil
        parser.reset()
    }

    func log(_ line: String) {
        logger?(line)
    }
}
