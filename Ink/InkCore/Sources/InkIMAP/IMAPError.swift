import Foundation
import InkModel

/// Why an IMAP operation failed, before it becomes a user-facing `MailError`.
///
/// `IMAPClient` throws `MailError` from its public methods; this type carries the protocol
/// detail (command, status, response code) that decides which `MailError` it becomes.
public enum IMAPError: Error, Sendable, Equatable {
    /// The server answered the command with NO or BAD.
    /// - Parameters:
    ///   - command: The command name (`"SELECT"`, `"UID MOVE"`, …).
    ///   - response: The tagged completion.
    ///   - mailbox: The decoded mailbox name the command was about, if any.
    ///   - alert: Text of an `[ALERT]` the server sent while the command ran.
    case commandFailed(command: String, response: IMAPTaggedResponse, mailbox: String?, alert: String?)
    /// The server said `* BYE` and closed the connection.
    case bye(String)
    /// The byte stream couldn't be framed (absurd literal size, endless line).
    case parse(IMAPParseError)
    /// The server sent something that makes no sense at this point.
    case unexpected(String)

    /// The `MailError` to show the user.
    public var mailError: MailError {
        switch self {
        case .commandFailed(let command, let response, let mailbox, let alert):
            return Self.map(command: command, response: response, mailbox: mailbox, alert: alert)
        case .bye(let text):
            let cleaned = Self.clean(text)
            return .connectionFailed(cleaned.isEmpty ? "The server closed the connection." : "The server closed the connection: \(cleaned)")
        case .parse(let error):
            switch error {
            case .literalTooLarge(let size): return .protocolError("It announced a \(size)-byte block of data, which is too large to accept.")
            case .lineTooLong: return .protocolError("It sent a response that never ended.")
            }
        case .unexpected(let detail):
            return .protocolError(detail)
        }
    }

    /// Converts any error raised while talking to the server into a `MailError`.
    public static func mailError(for error: Error) -> MailError {
        switch error {
        case let error as MailError:
            return error
        case let error as IMAPError:
            return error.mailError
        case let error as IMAPParseError:
            return IMAPError.parse(error).mailError
        case let error as TransportError:
            switch error {
            case .timeout: return .timeout
            case .closed: return .connectionFailed("The server closed the connection.")
            case .notConnected: return .connectionFailed("Not connected.")
            case .connectFailed(let detail): return .connectionFailed(detail)
            case .tlsFailed(let detail): return .tlsFailed(detail)
            case .io(let detail): return .connectionFailed(detail)
            }
        case is CancellationError:
            return .cancelled
        default:
            return .connectionFailed(error.localizedDescription)
        }
    }

    private static let authCommands: Set<String> = ["LOGIN", "AUTHENTICATE"]
    private static let mailboxCommands: Set<String> = ["SELECT", "EXAMINE", "STATUS"]

    private static func map(command: String, response: IMAPTaggedResponse, mailbox: String?, alert: String?) -> MailError {
        let name = command.uppercased()
        var text = clean(response.text.text)
        if let alert {
            let cleanedAlert = clean(alert)
            if !cleanedAlert.isEmpty, !text.contains(cleanedAlert) {
                text = text.isEmpty ? cleanedAlert : "\(cleanedAlert) \(text)"
            }
        }
        let isAuth = authCommands.contains(name) || name.hasPrefix("AUTHENTICATE ")

        switch response.text.code {
        case .authenticationFailed?, .authorizationFailed?, .expired?:
            return .authenticationFailed(text)
        case .privacyRequired?:
            return .tlsFailed(text.isEmpty ? "The server requires a secure connection." : text)
        case .unavailable?:
            return .serverError(text.isEmpty ? "The server is temporarily unavailable. Try again in a few minutes." : sentence(text))
        case .overQuota?:
            return .serverError(text.isEmpty ? "The mailbox is full." : "The mailbox is full: \(text)")
        case .tryCreate?, .nonExistent?:
            if let mailbox { return .mailboxNotFound(mailbox) }
        case .noPerm?:
            return .serverError(text.isEmpty ? "The server doesn't allow that in this folder." : sentence(text))
        case .alreadyExists?:
            return .serverError(text.isEmpty ? "That folder already exists." : sentence(text))
        default:
            break
        }

        if isAuth { return .authenticationFailed(text) }
        if response.status == .bad {
            return .protocolError(text.isEmpty ? "\(name) was rejected." : "\(name) was rejected: \(text)")
        }
        if mailboxCommands.contains(name), let mailbox { return .mailboxNotFound(mailbox) }
        return .serverError(text.isEmpty ? "The server couldn't complete \(name)." : sentence(text))
    }

    /// Trims and drops Gmail's ` (Failure)` suffix and similar noise.
    static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["(Failure)", "(Success)"] where result.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?".contains(last) ? text : text + "."
    }
}
