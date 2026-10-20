#if os(iOS)
import SwiftUI
import InkCore

/// The iPhone inbox: Ink's own header instead of a system large title, the conversation list,
/// pull to refresh, and a thin top bar that takes over once the title scrolls away.
///
/// Focus and Other behave like two pages side by side: switching slides one list out and the
/// other in from its side.
struct InboxScreen: View {
    @Environment(MailStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let zoomNamespace: Namespace.ID?
    @State private var isHeaderCollapsed = false

    private static let topAnchor = "inbox.top"
    /// Scroll distance after which the compact bar appears.
    private static let collapseDistance: CGFloat = 64
    /// Keeps lines readable on iPad and in landscape.
    private static let readableWidth: CGFloat = 720

    /// - Parameter zoomNamespace: Namespace in which rows publish themselves as sources for the
    ///   zoom transition into a thread.
    init(zoomNamespace: Namespace.ID? = nil) {
        self.zoomNamespace = zoomNamespace
    }

    var body: some View {
        let page = InboxPage(scope: store.scope, filter: store.inboxFilter, splitEnabled: store.focusedInboxEnabled)
        let collapseDistance = Self.collapseDistance
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        InboxHeader()
                            .id(Self.topAnchor)
                        InboxSyncBanner()
                        ZStack(alignment: .top) {
                            // A new mailbox gets a fresh list (no row-by-row reshuffle of the old
                            // one); Focus and Other slide past each other.
                            InboxList(zoomNamespace: zoomNamespace)
                                .id(InboxListIdentity(scope: store.scope, page: page))
                                .transition(reduceMotion ? .opacity : page.transition)
                        }
                    }
                    .frame(maxWidth: Self.readableWidth)
                    .frame(maxWidth: .infinity)
                }
                .contentMargins(.bottom, InkSize.fab + InkSpace.xxl, for: .scrollContent)
                .refreshable {
                    await store.refresh()
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > collapseDistance
                } action: { _, collapsed in
                    withAnimation(InkMotion.snappy) { isHeaderCollapsed = collapsed }
                }

                // Fills the status bar area so the big title slides under it, not under the
                // clock, before the compact bar takes over.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 0)
                    .background(Ink.background)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if isHeaderCollapsed {
                    InboxCompactBar {
                        Haptics.tick()
                        withAnimation(InkMotion.smooth) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                    }
                    .transition(.opacity.combined(with: .offset(y: -8)))
                }
            }
            .onChange(of: store.scope) {
                // A different mailbox starts at the top, not wherever the last one was scrolled to.
                proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
        }
        .background(Ink.background)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Identity of the list under the header.
private struct InboxListIdentity: Hashable {
    let scope: MailScope
    let page: InboxPage
}

/// Which list the inbox shows. Focus sits to the left of Other, so each slides in from its own
/// side; every other mailbox is a single page that cross-fades.
enum InboxPage: Hashable {
    case focus
    case other
    case single

    init(scope: MailScope, filter: InboxFilter, splitEnabled: Bool) {
        guard scope.role == .inbox, splitEnabled else {
            self = .single
            return
        }
        switch filter {
        case .focused: self = .focus
        case .other: self = .other
        case .everything: self = .single
        }
    }

    var transition: AnyTransition {
        switch self {
        case .focus: return .move(edge: .leading).combined(with: .opacity)
        case .other: return .move(edge: .trailing).combined(with: .opacity)
        case .single: return .opacity
        }
    }
}
#endif
