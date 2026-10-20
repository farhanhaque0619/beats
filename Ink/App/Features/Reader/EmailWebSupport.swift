import Foundation
import SwiftUI
import WebKit
import InkCore
#if os(macOS)
import AppKit
#endif

// The pieces behind `EmailWebView`: what decides a re-render, how the HTML document is built
// (off the main thread), the remote-content blocker, and the one script that measures height.

// MARK: - Render key

/// Everything that changes how a message's document looks. The web view reloads only when
/// this changes, never on ordinary SwiftUI updates.
struct EmailRenderKey: Hashable, Sendable {
    var messageID: String
    var fetchedAt: Date
    var dark: Bool
    var allowsRemoteContent: Bool
    var accentHex: String
    var fontFamily: String
    var fontSizePx: Int
    var collapseQuotes: Bool

    @MainActor
    static func make(
        body: MessageBody,
        allowsRemoteContent: Bool,
        collapseQuotes: Bool,
        readingFont: ReadingFont,
        environment: EnvironmentValues
    ) -> EmailRenderKey {
        EmailRenderKey(
            messageID: body.messageID,
            fetchedAt: body.fetchedAt,
            dark: environment.colorScheme == .dark,
            allowsRemoteContent: allowsRemoteContent,
            accentHex: hex(environment.inkAccent.resolve(in: environment)),
            fontFamily: readingFont == .serif ? "ui-serif" : "-apple-system",
            fontSizePx: fontSize(for: environment),
            collapseQuotes: collapseQuotes
        )
    }

    /// "#2F6BFF" for the accent as it looks right now (light or dark).
    private static func hex(_ color: Color.Resolved) -> String {
        func channel(_ value: Float) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(color.red), channel(color.green), channel(color.blue))
    }

    /// Body text size in CSS pixels, following Dynamic Type on iPhone.
    @MainActor
    private static func fontSize(for environment: EnvironmentValues) -> Int {
        #if os(macOS)
        return 14
        #else
        switch environment.dynamicTypeSize {
        case .xSmall: return 14
        case .small: return 15
        case .medium: return 16
        case .large: return 17
        case .xLarge: return 19
        case .xxLarge: return 21
        case .xxxLarge: return 23
        case .accessibility1: return 28
        case .accessibility2: return 33
        case .accessibility3: return 40
        case .accessibility4: return 47
        case .accessibility5: return 53
        @unknown default: return 17
        }
        #endif
    }
}

// MARK: - Document

/// An inline part (usually an image) that the HTML refers to with `cid:`.
struct EmailInlinePart: Sendable {
    var mimeType: String
    var data: Data
}

/// The inputs for building one message's document, safe to hand to a background task.
struct EmailRenderRequest: Sendable {
    var key: EmailRenderKey
    var html: String?
    var plainText: String?
    /// Inline parts keyed by normalised Content-ID.
    var inlineParts: [String: EmailInlinePart]
}

enum EmailDocumentBuilder {
    private static let contentIDPattern = try? NSRegularExpression(pattern: #"cid:([^"'\s<>)]+)"#, options: [.caseInsensitive])

    /// Runs on the main thread, so it only gathers: the HTML itself is searched for `cid:`
    /// references off the main thread, in `document(for:)`.
    static func request(for body: MessageBody, key: EmailRenderKey) -> EmailRenderRequest {
        var parts: [String: EmailInlinePart] = [:]
        if body.html != nil {
            for attachment in body.attachments {
                guard let contentID = attachment.contentID, let data = attachment.data else { continue }
                parts[normalizedContentID(contentID)] = EmailInlinePart(mimeType: attachment.mimeType, data: data)
            }
        }
        return EmailRenderRequest(key: key, html: body.html, plainText: body.plainText, inlineParts: parts)
    }

    /// The full HTML document for the web view. Pure and potentially slow on big newsletters,
    /// so callers run it off the main thread.
    static func document(for request: EmailRenderRequest) -> String {
        let html = request.html.map { inlineContentIDs(in: $0, parts: request.inlineParts) }
        let options = EmailHTMLDocument.Options(
            dark: request.key.dark,
            allowRemoteContent: request.key.allowsRemoteContent,
            accentHex: request.key.accentHex,
            fontFamily: request.key.fontFamily,
            fontSizePx: request.key.fontSizePx,
            collapseQuotes: request.key.collapseQuotes
        )
        return lockingZoom(EmailHTMLDocument.build(html: html, plainText: request.plainText, options: options))
    }

    /// The page sits inside the thread's scroll view and can't pan, so pinch and double-tap
    /// zoom would strand you in a magnified corner. WKWebView honours `user-scalable=no`.
    static func lockingZoom(_ document: String) -> String {
        let viewport = #"content="width=device-width, initial-scale=1""#
        let head = document.prefix(4_096)
        guard let range = head.range(of: viewport) else { return document }
        var locked = document
        locked.replaceSubrange(range, with: #"content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no""#)
        return locked
    }

    /// Rewrites `cid:` references to `data:` URIs so inline images show without any loading.
    static func inlineContentIDs(in html: String, parts: [String: EmailInlinePart]) -> String {
        guard !parts.isEmpty, let regex = contentIDPattern else { return html }
        let source = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return html }

        let output = NSMutableString(string: html)
        var uris: [String: String] = [:]
        for match in matches.reversed() {
            let reference = source.substring(with: match.range(at: 1))
            guard let found = lookUp(reference, in: parts) else { continue }
            let key = found.key
            let part = found.part
            let uri: String
            if let cached = uris[key] {
                uri = cached
            } else {
                uri = "data:\(safeMIMEType(part.mimeType));base64,\(part.data.base64EncodedString())"
                uris[key] = uri
            }
            output.replaceCharacters(in: match.range, with: uri)
        }
        return output as String
    }

    static func normalizedContentID(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
    }

    private static func lookUp(_ reference: String, in parts: [String: EmailInlinePart]) -> (key: String, part: EmailInlinePart)? {
        let plain = normalizedContentID(reference)
        if let part = parts[plain] { return (plain, part) }
        if let decoded = reference.removingPercentEncoding {
            let key = normalizedContentID(decoded)
            if let part = parts[key] { return (key, part) }
        }
        return nil
    }

    private static func safeMIMEType(_ type: String) -> String {
        let lowered = type.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/+-.;="))
        guard lowered.contains("/"), lowered.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "application/octet-stream"
        }
        return lowered
    }
}

// MARK: - WebKit plumbing

@MainActor
enum ReaderWebKit {
    /// One ephemeral store for every message: nothing is written to disk, no cookies survive,
    /// and all reader web views share a single web content process.
    static let dataStore = WKWebsiteDataStore.nonPersistent()
}

/// The two content rule lists the reader uses, each compiled once per launch.
@MainActor
enum ReaderContentRules {
    private static let remoteContent = ReaderCompiledRules(
        identifier: "ink.reader.block-remote-content.v1",
        source: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
    )

    private static let trackers = ReaderCompiledRules(
        identifier: "ink.reader.block-trackers.v1",
        source: trackerRules()
    )

    /// Images off: every http(s) load is blocked. Nil if WebKit couldn't compile it (the
    /// document's CSP still blocks remote images in that case).
    static func remoteContentBlockList() async -> WKContentRuleList? {
        await remoteContent.list()
    }

    /// Images on: known open-tracking services stay blocked and no cookies are sent, so
    /// "Load images" doesn't also tell the sender you read it.
    static func trackerBlockList() async -> WKContentRuleList? {
        await trackers.list()
    }

    /// Hosts and paths of common open-tracking pixels (the same vendors the privacy banner
    /// counts). Plain literals only: content-blocker regexes reject `|`, `\b`, `\d` and friends,
    /// and one bad pattern fails the whole list.
    private static let trackerPatterns: [String] = [
        #"mailtrack\.io"#, #"yesware\.com"#, #"mixmax\.com"#, #"track\.hubspot"#, "hubspotlinks", "hs-analytics",
        "sidekickopen", #"mailfoogae\.appspot\.com"#, #"bananatag\.com"#, #"getnotify\.com"#, #"streak\.com/"#,
        #"superhuman\.com"#, "/track/open", "/wf/open", #"/open\.php"#, #"open\.aspx"#, #"emltrk\.com"#,
        #"list-manage\.com/track"#, #"mandrillapp\.com/track"#, #"sendgrid\.net/wf"#, #"pardot\.com/r/"#,
        "convertkit-mail", #"open\.convertkit"#, #"linkedin\.com/emimp"#, "email_open_log_pic",
        #"google-analytics\.com/collect"#, #"/o\.gif"#, #"/pixel\.gif"#, #"/pixel\.png"#, #"/pixel\?"#,
        "/pixel/", #"://pixel\."#, "/beacon", #"/trk\?"#, "/trk/", "/tracking/", #"/open\?"#, #"awstrack\.me"#,
        #"mailgun\.org/o"#, "mktoresp", #"/imp\?"#, "/impression", #"trk\.klclick"#, "klaviyomail",
    ]

    private static func trackerRules() -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block-cookies"]],
        ]
        for pattern in trackerPatterns {
            rules.append(["trigger": ["url-filter": pattern], "action": ["type": "block"]])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}

/// One content rule list, compiled on first use and shared by every message after that.
@MainActor
private final class ReaderCompiledRules {
    private let identifier: String
    private let source: String
    private var compiled: WKContentRuleList?
    private var isCompiling = false
    private var waiting: [CheckedContinuation<WKContentRuleList?, Never>] = []

    init(identifier: String, source: String) {
        self.identifier = identifier
        self.source = source
    }

    func list() async -> WKContentRuleList? {
        if let compiled { return compiled }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard !isCompiling else { return }
            isCompiling = true
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) { list, _ in
                MainActor.assumeIsolated {
                    self.finish(with: list)
                }
            }
        }
    }

    private func finish(with list: WKContentRuleList?) {
        compiled = list
        isCompiling = false
        let continuations = waiting
        waiting = []
        for continuation in continuations {
            continuation.resume(returning: list)
        }
    }
}

/// The only script that ever runs: in Ink's own content world (the message's JavaScript stays
/// off), it scales wide newsletters to fit and reports the document height.
enum EmailWebScript {
    static let handlerName = "height"

    static let source = """
    (function () {
      'use strict';
      var root = document.documentElement;
      var minimumZoom = 0.4;
      var lastHeight = 0;
      var lastWidth = -1;
      var lastExcess = -1;
      var creep = 0;
      var resized = false;
      var queued = false;

      // Wide newsletters (fixed 600-700px tables) shrink to the view's width instead of scrolling
      // sideways. The email sits in #ink-content, which scrolls its own overflow, so the page
      // itself never looks wider than the view: measure the wrapper's content too.
      function fit() {
        var body = document.body;
        var width = window.innerWidth;
        if (!body || width <= 0 || width === lastWidth) { return; }
        lastWidth = width;
        body.style.zoom = '';
        var contentWidth = root.scrollWidth;
        var wrapper = document.getElementById('ink-content');
        if (wrapper) {
          var outside = Math.max(0, width - wrapper.clientWidth);
          contentWidth = Math.max(contentWidth, wrapper.scrollWidth + outside);
        }
        if (contentWidth > width + 1) {
          body.style.zoom = String(Math.max(width / contentWidth, minimumZoom));
        }
      }

      function measure() {
        var height = root.getBoundingClientRect().height;
        if (root.scrollHeight > window.innerHeight + 1) {
          height = Math.max(height, root.scrollHeight);
        }
        return Math.ceil(height);
      }

      function post(height) {
        var handlers = window.webkit && window.webkit.messageHandlers;
        if (handlers && handlers.height) { handlers.height.postMessage(height); }
      }

      function report() {
        if (!queued) { return; }
        queued = false;
        var afterResize = resized;
        resized = false;
        fit();
        var height = measure();
        if (height <= 0 || Math.abs(height - lastHeight) < 1) { return; }
        // A page sized in viewport units (100vh) outgrows every height it is given, by the same
        // amount each time the view catches up. After a few rounds of that, stop feeding it.
        // (Images loading one by one also grow the page, but not in answer to a resize.)
        var viewport = window.innerHeight;
        if (afterResize && lastHeight > 0 && height > lastHeight && Math.abs(viewport - lastHeight) <= 1) {
          var excess = height - viewport;
          creep = Math.abs(excess - lastExcess) <= 1 ? creep + 1 : 0;
          lastExcess = excess;
          if (creep >= 3) { return; }
        } else {
          creep = 0;
          lastExcess = -1;
        }
        lastHeight = height;
        post(height);
      }

      function schedule() {
        if (queued) { return; }
        queued = true;
        window.requestAnimationFrame(report);
        window.setTimeout(report, 120);
      }

      function refit() {
        lastWidth = -1;
        schedule();
      }

      if (window.ResizeObserver) {
        var observer = new ResizeObserver(schedule);
        observer.observe(root);
        if (document.body) { observer.observe(document.body); }
      }
      window.addEventListener('load', refit);
      window.addEventListener('resize', function () {
        resized = true;
        schedule();
      });
      document.addEventListener('toggle', schedule, true);
      Array.prototype.forEach.call(document.images, function (image) {
        if (!image.complete) {
          image.addEventListener('load', refit);
          image.addEventListener('error', schedule);
        }
      });
      schedule();
    })();
    """
}

#if os(macOS)
/// Hands scroll-wheel events to the enclosing SwiftUI scroll view, so the whole thread scrolls
/// as one page instead of the web view swallowing the gesture.
final class EmailPassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

typealias EmailPlatformWebView = EmailPassthroughWebView
#else
typealias EmailPlatformWebView = WKWebView
#endif
