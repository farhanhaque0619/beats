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
    static func postOneClick(to url: URL) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        // Ephemeral: no cookies or cache tie this request to anything else you do.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
            return (200..<300).contains(status)
        } catch {
            return false
        }
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

    private func tap() {
        Haptics.tick()
        switch method {
        case .oneClick:
            isConfirming = true
        case .mailto(let url):
            app.handleOpenURL(url)
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
