import SwiftUI
import WebKit
import InkCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A message body in a `WKWebView`, sized to its content so the thread scrolls as one page.
///
/// Private by construction: the message's own JavaScript never runs, remote loads are blocked
/// by a content rule list (unless allowed for this message), the data store is ephemeral, and
/// links leave the app instead of navigating in place. The view reloads only when its
/// `EmailRenderKey` changes (body, colour scheme, accent, font, remote content).
@MainActor
struct EmailWebView {
    var messageBody: MessageBody
    var allowsRemoteContent: Bool
    /// Fold quoted replies that repeat earlier messages in the thread.
    var collapseQuotes: Bool
    var readingFont: ReadingFont
    /// The document height in points, reported by the page. Zero until the first layout.
    @Binding var contentHeight: CGFloat
    /// `mailto:` links (the app opens Compose).
    var onMailto: (URL) -> Void

    func makeCoordinator() -> EmailWebCoordinator {
        EmailWebCoordinator(parent: self)
    }

    fileprivate func refresh(_ coordinator: EmailWebCoordinator, environment: EnvironmentValues) {
        coordinator.parent = self
        let key = EmailRenderKey.make(
            body: messageBody,
            allowsRemoteContent: allowsRemoteContent,
            collapseQuotes: collapseQuotes,
            readingFont: readingFont,
            environment: environment
        )
        coordinator.render(key, body: messageBody)
    }
}

#if os(iOS)
extension EmailWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        refresh(context.coordinator, environment: context.environment)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: EmailWebCoordinator) {
        coordinator.tearDown()
    }
}
#elseif os(macOS)
extension EmailWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        refresh(context.coordinator, environment: context.environment)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: EmailWebCoordinator) {
        coordinator.tearDown()
    }
}
#endif

// MARK: - Coordinator

@MainActor
final class EmailWebCoordinator: NSObject, WKNavigationDelegate {
    var parent: EmailWebView

    private weak var webView: WKWebView?
    private var contentController: WKUserContentController?
    private var renderedKey: EmailRenderKey?
    private var renderTask: Task<Void, Never>?
    /// The last document loaded, kept to recover if the web content process dies.
    private var loadedDocument: String?
    private var reportedHeight: CGFloat = 0

    init(parent: EmailWebView) {
        self.parent = parent
        super.init()
    }

    func makeWebView() -> WKWebView {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: EmailWebScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        // The controller keeps its handler alive; the proxy only points back weakly.
        controller.add(EmailWebMessageProxy(coordinator: self), contentWorld: .defaultClient, name: EmailWebScript.handlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = ReaderWebKit.dataStore
        configuration.suppressesIncrementalRendering = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = EmailPlatformWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
        let scrollView = webView.scrollView
        scrollView.backgroundColor = .clear
        scrollView.isScrollEnabled = false
        scrollView.bounces = false
        scrollView.scrollsToTop = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        #elseif os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        #endif

        contentController = controller
        self.webView = webView
        return webView
    }

    /// Builds the document off the main thread and loads it, unless it's already showing.
    func render(_ key: EmailRenderKey, body: MessageBody) {
        guard key != renderedKey else { return }
        renderedKey = key
        renderTask?.cancel()
        let request = EmailDocumentBuilder.request(for: body, key: key)
        renderTask = Task { [weak self] in
            let document = await Task.detached(priority: .userInitiated) {
                EmailDocumentBuilder.document(for: request)
            }.value
            var blockList: WKContentRuleList?
            if !key.allowsRemoteContent {
                blockList = await ReaderContentRules.remoteContentBlockList()
            }
            guard !Task.isCancelled, let self else { return }
            self.show(document, blockList: blockList)
        }
    }

    private func show(_ document: String, blockList: WKContentRuleList?) {
        guard let webView, let contentController else { return }
        contentController.removeAllContentRuleLists()
        if let blockList {
            contentController.add(blockList)
        }
        loadedDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    fileprivate func didMeasure(height: CGFloat) {
        let height = ceil(height)
        guard height.isFinite, height > 0, abs(height - reportedHeight) >= 1 else { return }
        reportedHeight = height
        withAnimation(InkMotion.smooth) {
            parent.contentHeight = height
        }
    }

    func tearDown() {
        renderTask?.cancel()
        renderTask = nil
        contentController?.removeScriptMessageHandler(forName: EmailWebScript.handlerName, contentWorld: .defaultClient)
        contentController?.removeAllUserScripts()
        webView?.navigationDelegate = nil
        webView?.stopLoading()
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(policy(for: navigationAction))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let loadedDocument else { return }
        webView.loadHTMLString(loadedDocument, baseURL: nil)
    }

    /// Only the document we load ourselves may navigate the view. Tapped links leave the app:
    /// `mailto:` opens Compose, web links open in the browser, anything else is ignored.
    private func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if action.navigationType == .linkActivated {
            switch scheme {
            case "mailto":
                parent.onMailto(url)
            case "http", "https":
                openExternally(url)
            default:
                break
            }
            return .cancel
        }
        return scheme == "about" ? .allow : .cancel
    }

    private func openExternally(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        _ = NSWorkspace.shared.open(url)
        #endif
    }
}

/// Receives the height messages. WebKit retains its script message handlers strongly, so this
/// small proxy holds the coordinator weakly to keep the web view from leaking.
@MainActor
private final class EmailWebMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var coordinator: EmailWebCoordinator?

    init(coordinator: EmailWebCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == EmailWebScript.handlerName, let number = message.body as? NSNumber else { return }
        coordinator?.didMeasure(height: CGFloat(number.doubleValue))
    }
}
