import Foundation

/// How waiting for the next chunk of server bytes ended.
enum IMAPReadOutcome: Sendable {
    case data(Data)
    case failure(Error)
    /// The wait's deadline passed; the read is still outstanding and can be awaited again.
    case deadline
    /// The waiting task was cancelled; the read is still outstanding.
    case cancelled
}

/// Resolves a continuation exactly once, whichever of the racing events comes first, even
/// when an event fires before the continuation is installed.
final class IMAPOutcomeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<IMAPReadOutcome, Never>?
    private var early: IMAPReadOutcome?
    private var finished = false

    func install(_ continuation: CheckedContinuation<IMAPReadOutcome, Never>) {
        lock.lock()
        if let early {
            self.early = nil
            finished = true
            lock.unlock()
            continuation.resume(returning: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ outcome: IMAPReadOutcome) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if let continuation {
            self.continuation = nil
            finished = true
            lock.unlock()
            continuation.resume(returning: outcome)
        } else {
            if early == nil { early = outcome }
            lock.unlock()
        }
    }
}

enum IMAPReadRace {
    /// Waits for an outstanding read, a deadline or (optionally) cancellation of the current
    /// task, whichever comes first. The read itself is never cancelled here, so its bytes are
    /// not lost: the caller keeps the task and awaits it again later.
    static func wait(for read: Task<Data, Error>, timeout: TimeInterval, cancellable: Bool) async -> IMAPReadOutcome {
        let latch = IMAPOutcomeLatch()
        let watcher = Task.detached {
            switch await read.result {
            case .success(let data): latch.resolve(.data(data))
            case .failure(let error): latch.resolve(.failure(error))
            }
        }
        let nanoseconds = UInt64(max(0, min(timeout, 365 * 86_400)) * 1_000_000_000)
        let timer = Task.detached {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                latch.resolve(.deadline)
            } catch {
                // Cancelled because another event won.
            }
        }
        let outcome: IMAPReadOutcome
        if cancellable {
            outcome = await withTaskCancellationHandler {
                await withCheckedContinuation { latch.install($0) }
            } onCancel: {
                latch.resolve(.cancelled)
            }
        } else {
            outcome = await withCheckedContinuation { latch.install($0) }
        }
        timer.cancel()
        _ = watcher
        return outcome
    }
}

/// SASL client messages (RFC 4616 PLAIN, Google/Microsoft XOAUTH2), base64-encoded for the wire.
public enum IMAPSASL {
    /// `base64("\0" + username + "\0" + password)`.
    public static func plain(username: String, password: String) -> String {
        var bytes: [UInt8] = [0]
        bytes.append(contentsOf: username.utf8)
        bytes.append(0)
        bytes.append(contentsOf: password.utf8)
        return Data(bytes).base64EncodedString()
    }

    /// `base64("user=" + username + "\u{1}auth=Bearer " + token + "\u{1}\u{1}")`.
    public static func xoauth2(username: String, accessToken: String) -> String {
        Data("user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}".utf8).base64EncodedString()
    }

    /// The `status` of an XOAUTH2 error challenge such as
    /// `eyJzdGF0dXMiOiI0MDAiLCJzY2hlbWVzIjoiQmVhcmVyIiwic2NvcGUiOiJodHRwczovL21haWwuZ29vZ2xlLmNvbS8ifQ==`
    /// (`{"status":"400","schemes":"Bearer","scope":"https://mail.google.com/"}`).
    public static func xoauth2ErrorStatus(_ challenge: String) -> String? {
        var text = challenge.trimmingCharacters(in: .whitespaces)
        while text.utf8.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let status = object["status"] as? String { return status }
        if let status = object["status"] as? Int { return String(status) }
        return nil
    }
}
