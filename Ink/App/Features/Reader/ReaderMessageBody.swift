import SwiftUI
import InkCore

/// The body of an expanded message: loading dots, then the email in a web view sized to fit,
/// with the remote-images banner above and attachment chips below. Cached bodies show at once;
/// otherwise the body is fetched while the dots pulse.
struct ReaderMessageBody: View {
    let message: MessageSummary
    let collapseQuotes: Bool

    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var phase: Phase = .loading
    @State private var attempt = 0
    @State private var contentHeight: CGFloat = 0
    @State private var inspection: Inspection?
    @State private var remoteContentAllowedHere = false

    private enum Phase {
        case loading
        case loaded(MessageBody)
        case failed(String)
    }

    /// Facts about the HTML, worked out off the main thread once per body.
    private struct Inspection: Equatable, Sendable {
        var remoteImages = 0
        var trackers = 0
        /// A designed newsletter keeps its own layout, so it gets a little more width.
        var isDesigned = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpace.m) {
            switch phase {
            case .loading:
                placeholder
            case .failed(let reason):
                failure(reason)
            case .loaded(let messageBody):
                loaded(messageBody)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { showCachedBody() }
        .task(id: attempt) { await load() }
    }

    // MARK: States

    private var placeholder: some View {
        LoadingDots()
            .frame(maxWidth: .infinity, minHeight: 72)
    }

    private func failure(_ reason: String) -> some View {
        VStack(spacing: InkSpace.m) {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Haptics.tick()
                withAnimation(InkMotion.snappy) { phase = .loading }
                attempt += 1
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
                    .font(InkFont.button)
                    .foregroundStyle(Ink.primary)
                    .padding(.horizontal, InkSpace.l)
                    .padding(.vertical, InkSpace.s)
                    .background(Ink.fill, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, InkSpace.l)
        .padding(.horizontal, InkSpace.gutter)
    }

    @ViewBuilder
    private func loaded(_ messageBody: MessageBody) -> some View {
        let isReady = contentHeight > 0 && inspection != nil
        if showsPrivacyBanner {
            ReaderPrivacyBanner(trackers: inspection?.trackers ?? 0) {
                withAnimation(InkMotion.smooth) { remoteContentAllowedHere = true }
            }
            .padding(.horizontal, InkSpace.gutter)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        ZStack(alignment: .top) {
            EmailWebView(
                messageBody: messageBody,
                allowsRemoteContent: allowsRemoteContent,
                collapseQuotes: collapseQuotes,
                readingFont: settings.readingFont,
                contentHeight: $contentHeight,
                onMailto: { app.handleOpenURL($0) }
            )
            // Held at 1 pt until the page has been measured, then springs open to its height.
            .frame(height: isReady ? max(contentHeight, 1) : 1)
            .padding(.horizontal, inspection?.isDesigned == true ? InkSpace.s : InkSpace.gutter)
            .opacity(isReady ? 1 : 0)
            .accessibilityHidden(!isReady)

            if !isReady {
                placeholder
                    .transition(.opacity)
            }
        }
        .animation(InkMotion.smooth, value: isReady)
        .task(id: InspectionKey(body: messageBody)) { await inspect(messageBody) }

        let attachments = messageBody.visibleAttachments
        if !attachments.isEmpty {
            ReaderAttachmentStrip(message: message, attachments: attachments)
        }
    }

    // MARK: Privacy

    private var allowsRemoteContent: Bool {
        settings.loadRemoteImages || remoteContentAllowedHere
    }

    private var showsPrivacyBanner: Bool {
        !allowsRemoteContent && (inspection?.remoteImages ?? 0) > 0
    }

    private struct InspectionKey: Hashable {
        var messageID: String
        var fetchedAt: Date

        init(body: MessageBody) {
            messageID = body.messageID
            fetchedAt = body.fetchedAt
        }
    }

    private func inspect(_ messageBody: MessageBody) async {
        let html = messageBody.html
        let result = await Task.detached(priority: .userInitiated) { () -> Inspection in
            guard let html else { return Inspection() }
            return Inspection(
                remoteImages: EmailHTMLDocument.countRemoteImages(html),
                trackers: EmailHTMLDocument.countTrackingPixels(html),
                isDesigned: EmailHTMLDocument.isDesigned(html)
            )
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(InkMotion.smooth) { inspection = result }
    }

    // MARK: Loading

    private func showCachedBody() {
        guard case .loading = phase, let cached = store.cachedBody(for: message) else { return }
        phase = .loaded(cached)
    }

    private func load() async {
        if case .loaded = phase { return }
        if let cached = store.cachedBody(for: message) {
            phase = .loaded(cached)
            return
        }
        do {
            let fetched = try await store.body(for: message)
            withAnimation(InkMotion.smooth) { phase = .loaded(fetched) }
        } catch is CancellationError {
            return
        } catch MailError.cancelled {
            return
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "Couldn't load this message."
            withAnimation(InkMotion.smooth) { phase = .failed(reason) }
        }
    }
}

/// "Images hidden to protect your privacy · 3 trackers blocked  Load images".
private struct ReaderPrivacyBanner: View {
    let trackers: Int
    let onLoad: () -> Void

    @Environment(\.inkAccent) private var accent

    var body: some View {
        HStack(spacing: InkSpace.s) {
            Image(systemName: "eye.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Ink.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: InkSpace.s)
            Button {
                Haptics.tick()
                onLoad()
            } label: {
                Text("Load images")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.vertical, InkSpace.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .fixedSize()
        }
        .padding(.horizontal, InkSpace.m)
        .padding(.vertical, InkSpace.s)
        .background(Ink.fill, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
    }

    private var text: String {
        switch trackers {
        case 0: return "Images hidden to protect your privacy"
        case 1: return "Images hidden to protect your privacy · 1 tracker blocked"
        default: return "Images hidden to protect your privacy · \(trackers) trackers blocked"
        }
    }
}
