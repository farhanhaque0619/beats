import SwiftUI
import InkCore

/// How a sender lets you leave their list, from the `List-Unsubscribe` headers.
enum ReaderUnsubscribe: Equatable {
    /// RFC 8058: a single POST to this URL unsubscribes, no page to visit.
    case oneClick(URL)
    /// Send an email (opens Compose, prefilled).
    case mailto(URL)
    /// Open a page in the browser.
    case web(URL)

    /// The best option the message offers: one-click first, then email, then a web page.
    init?(message: MessageSummary) {
        guard let header = message.listUnsubscribe else { return nil }
        let urls = Self.urls(in: header)
        let supportsOneClick = message.listUnsubscribePost?
            .range(of: "List-Unsubscribe=One-Click", options: .caseInsensitive) != nil
        func first(_ schemes: Set<String>) -> URL? {
            urls.first { schemes.contains($0.scheme?.lowercased() ?? "") }
        }
        if supportsOneClick, let url = first(["https"]) {
            self = .oneClick(url)
        } else if let url = first(["mailto"]) {
            self = .mailto(url)
        } else if let url = first(["https", "http"]) {
            self = .web(url)
        } else {
            return nil
        }
    }

    /// `<mailto:a@b?subject=x>, <https://…>` → URLs, tolerating folded whitespace inside the brackets.
    static func urls(in header: String) -> [URL] {
        var result: [URL] = []
        var rest = Substring(header)
        while let open = rest.firstIndex(of: "<") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: ">") else { break }
            let raw = String(rest[afterOpen..<close].filter { !$0.isWhitespace })
            if let url = URL(string: raw), url.scheme != nil {
                result.append(url)
            }
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    /// Sends the RFC 8058 one-click request. True when the server accepted it.
    ///
    /// Only ever called after the person confirms. The request carries nothing that ties it to
    /// them: an ephemeral session with no cookies or cache, and redirects are not followed
    /// (RFC 8058 forbids them, and following one would turn the POST into a tracked GET).
    static func postOneClick(to url: URL) async -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request, delegate: ReaderNoRedirects())
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
            // A 3xx means the server took the POST and wanted to show a page we won't visit.
            return (200..<400).contains(status)
        } catch {
            return false
        }
    }
}

/// Stops URLSession from following redirects for one request.
private final class ReaderNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// `mailto:` links from a message (and List-Unsubscribe addresses) as a Compose draft sent from
/// the account the message came to.
@MainActor
enum ReaderMailto {
    static func draft(for url: URL, accountID: String, store: MailStore, defaultSubject: String? = nil) -> OutgoingMessage? {
        guard url.scheme?.lowercased() == "mailto",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let account = store.account(id: accountID) != nil ? accountID : nil
        var draft = store.newDraft(accountID: account)
        draft.to = addresses(components.path)
        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "to": draft.to += addresses(value)
            case "cc": draft.cc = addresses(value)
            case "bcc": draft.bcc = addresses(value)
            case "subject": draft.subject = value
            case "body": draft.body = value
            default: break
            }
        }
        if draft.subject.isEmpty, let defaultSubject { draft.subject = defaultSubject }
        return draft
    }

    private static func addresses(_ list: String) -> [EmailAddress] {
        list.split(separator: ",")
            .map { EmailAddress(address: $0.trimmingCharacters(in: .whitespaces)) }
            .filter(\.isValid)
    }
}

/// The small "Unsubscribe" text button in the latest message's header.
struct ReaderUnsubscribeButton: View {
    let message: MessageSummary
    let method: ReaderUnsubscribe

    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var isConfirming = false
    @State private var progress: Phase = .idle

    private enum Phase { case idle, working, done }

    var body: some View {
        Button {
            tap()
        } label: {
            ZStack {
                switch progress {
                case .idle:
                    Text("Unsubscribe")
                case .working:
                    LoadingDots()
                case .done:
                    Label("Unsubscribed", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(InkFont.caption)
            .foregroundStyle(progress == .done ? Ink.tertiary : Ink.secondary)
            .padding(.horizontal, InkSpace.s)
            .padding(.vertical, 5)
            .background(Ink.fill, in: Capsule())
            .contentShape(Capsule())
            .animation(InkMotion.snappy, value: progress)
        }
        .buttonStyle(.pressable)
        .disabled(progress != .idle)
        .accessibilityLabel(progress == .done ? "Unsubscribed" : "Unsubscribe")
        .accessibilityHint(hint)
        .confirmationDialog("Unsubscribe from \(senderName)?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) {
                Task { await unsubscribeWithOneClick() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ink will ask the sender to stop emailing you.")
        }
    }

    private var senderName: String {
        message.sender?.displayName ?? "this list"
    }

    private var hint: String {
        switch method {
        case .oneClick: return "Asks the sender to take you off this list, after you confirm"
        case .mailto: return "Writes the unsubscribe email for you to send"
        case .web: return "Opens the sender's unsubscribe page in your browser"
        }
    }

    private func tap() {
        Haptics.tick()
        switch method {
        case .oneClick:
            isConfirming = true
        case .mailto(let url):
            // Compose opens filled in, from the address that's subscribed; sending is the consent.
            if let draft = ReaderMailto.draft(for: url, accountID: message.accountID, store: store, defaultSubject: "Unsubscribe") {
                app.composeDraft = draft
            }
        case .web(let url):
            openURL(url)
        }
    }

    private func unsubscribeWithOneClick() async {
        guard case .oneClick(let url) = method else { return }
        progress = .working
        let succeeded = await ReaderUnsubscribe.postOneClick(to: url)
        if succeeded {
            progress = .done
            Haptics.success()
            store.showToast(Toast(message: "Unsubscribed from \(senderName)", systemImage: "checkmark.circle", style: .success))
        } else {
            progress = .idle
            Haptics.warning()
            store.showToast(Toast(message: "Couldn't unsubscribe. Try the link in the message.", systemImage: "exclamationmark.circle", style: .error))
        }
    }
}
