#if os(macOS)
import SwiftUI
import InkCore

/// The middle column: the mailbox's conversations, or search results while the toolbar search
/// field has text.
struct MacConversationColumn: View {
    let searchQuery: String
    /// Bumped each time the search is submitted (Return), to fetch server results right away.
    let searchSubmitCount: Int
    var focus: FocusState<MacPane?>.Binding
    /// Clears the toolbar search, back to the mailbox.
    var endSearch: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store

    var body: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = MacActions(app: app)
        VStack(spacing: 0) {
            if query.isEmpty {
                MacListHeader()
                MacConversationList(focus: focus)
            } else {
                MacSearchResults(query: query, submitCount: searchSubmitCount, focus: focus, endSearch: endSearch)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .navigationTitle(store.title(for: store.scope))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    actions.run(.compose)
                } label: {
                    Label(MacCommand.compose.title, systemImage: MacCommand.compose.systemImage)
                }
                .help("New message (C)")
                .disabled(!actions.isEnabledInMenu(.compose))
            }
        }
    }
}

/// "Inbox 12" in the display face, and the Focus / Other pill for inboxes.
private struct MacListHeader: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        let scope = store.scope
        let unread = store.unreadCount(for: scope)
        let showsFilter = scope.role == .inbox && store.focusedInboxEnabled
        VStack(alignment: .leading, spacing: InkSpace.m) {
            HStack(alignment: .firstTextBaseline, spacing: InkSpace.s) {
                Text(store.title(for: scope))
                    .font(InkFont.title)
                    .tracking(InkTracking.title)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if unread > 0 {
                    Text(verbatim: "\(unread)")
                        .font(InkFont.meta)
                        .foregroundStyle(Ink.tertiary)
                        .contentTransition(.numericText())
                        .accessibilityLabel("\(unread) unread")
                }
                Spacer(minLength: 0)
            }
            if showsFilter {
                MacInboxFilterPill()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, InkSpace.gutter)
        .padding(.top, InkSpace.m)
        .padding(.bottom, InkSpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(InkMotion.snappy, value: unread)
        .animation(InkMotion.smooth, value: showsFilter)
    }
}

/// Two-segment Focus | Other control with a sliding ink capsule.
private struct MacInboxFilterPill: View {
    @Environment(MailStore.self) private var store
    @Namespace private var selectionNamespace

    var body: some View {
        let other = store.otherUnreadCount > 0 ? store.otherUnreadCount : store.otherCount
        HStack(spacing: 2) {
            segment(.focused, count: 0)
            segment(.other, count: other)
        }
        .padding(3)
        .background(Ink.fill, in: Capsule())
        .animation(InkMotion.snappy, value: store.inboxFilter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inbox filter")
    }

    private func segment(_ filter: InboxFilter, count: Int) -> some View {
        let isSelected = store.inboxFilter == filter
        return Button {
            guard store.inboxFilter != filter else { return }
            Haptics.tick()
            store.inboxFilter = filter
        } label: {
            HStack(spacing: 5) {
                Text(filter.title)
                    .font(InkFont.button)
                if count > 0 {
                    Text(InkFormat.badge(count))
                        .font(InkFont.meta)
                        .foregroundStyle(isSelected ? Ink.onInverse.opacity(0.7) : Ink.tertiary)
                }
            }
            .foregroundStyle(isSelected ? Ink.onInverse : Ink.secondary)
            .padding(.horizontal, InkSpace.m)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Ink.inverse)
                        .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The mailbox list: native selection (click, ⇧/⌘-click, arrows), trackpad swipes from the
/// user's swipe settings, a context menu for the clicked rows, and paging near the end.
private struct MacConversationList: View {
    var focus: FocusState<MacPane?>.Binding

    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.inkAccent) private var accent
    /// Scopes that have shown mail or finished a sync: an empty one is really empty, not loading.
    @State private var loadedScopes: Set<MailScope> = []
    /// Ends the first-launch dots even if no sync ever reports back.
    @State private var hasSettled = false

    var body: some View {
        @Bindable var app = app
        let conversations = store.conversations
        let context = MacRowContext(store: store, settings: settings)
        let tailIDs = Set(conversations.suffix(5).map(\.id))
        let actions = MacActions(app: app)
        ScrollViewReader { proxy in
            List(selection: $app.selection) {
                ForEach(conversations) { conversation in
                    context.row(conversation)
                        .equatable()
                        .listRowInsets(EdgeInsets())
                        .listRowSeparatorTint(Ink.hairline)
                        .macSwipeActions(for: conversation, swipes: settings.swipes, accent: accent) { action in
                            actions.perform(action, on: [conversation])
                        }
                        .macHoverActions(for: conversation) { action in
                            actions.perform(action, on: [conversation])
                        }
                        .onAppear {
                            if tailIDs.contains(conversation.id) { loadMore() }
                        }
                }
                if store.isLoadingMore {
                    HStack {
                        Spacer()
                        LoadingDots()
                        Spacer()
                    }
                    .padding(.vertical, InkSpace.l)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                MacConversationMenu(app: app, ids: ids)
            }
            .focused(focus, equals: .list)
            .macKeyboardShortcuts(app: app, pane: .list)
            .overlay {
                if conversations.isEmpty {
                    MacListEmptyState(isLoading: isLoading)
                }
            }
            .animation(InkMotion.smooth, value: conversations.isEmpty)
            .animation(InkMotion.smooth, value: isLoading)
            .onChange(of: conversations.isEmpty, initial: true) { _, isEmpty in
                if !isEmpty { loadedScopes.insert(store.scope) }
            }
            .onChange(of: store.syncStatus) { oldStatus, newStatus in
                guard oldStatus == .syncing, newStatus != .syncing else { return }
                loadedScopes.insert(store.scope)
            }
            .task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                hasSettled = true
            }
            .onChange(of: app.focusedConversationID) { _, id in
                guard let id else { return }
                withAnimation(InkMotion.snappy) { proxy.scrollTo(id) }
            }
            .onChange(of: store.scope) { _, _ in
                if let first = store.conversations.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }

    /// Nothing to show because this mailbox hasn't loaded yet (rather than because it's empty).
    private var isLoading: Bool {
        guard !loadedScopes.contains(store.scope) else { return false }
        return store.syncStatus == .syncing || (store.lastSyncedAt == nil && !hasSettled)
    }

    private func loadMore() {
        guard store.canLoadMore, !store.isLoadingMore else { return }
        let mailStore = store
        Task { await mailStore.loadMore() }
    }
}

/// First load, inbox zero, or a quiet note for other empty mailboxes. Only a truly empty inbox
/// is celebrated: not an empty Focus or Other, and not a list that's empty because sync failed.
private struct MacListEmptyState: View {
    /// The mailbox hasn't loaded yet: show dots, not "empty".
    var isLoading: Bool

    @Environment(MailStore.self) private var store

    var body: some View {
        Group {
            if isLoading {
                LoadingDots()
            } else if isSyncFailure {
                EmptyStateView(systemImage: "wifi.exclamationmark", title: "Nothing to show yet",
                               message: "Ink couldn't reach your mail. Press ⇧⌘N to try again.")
            } else if store.scope.role == .inbox {
                inboxZero
            } else {
                EmptyStateView(systemImage: symbol, title: title, message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    private var isSyncFailure: Bool {
        if case .failed = store.syncStatus { return true }
        return false
    }

    @ViewBuilder
    private var inboxZero: some View {
        if store.focusedInboxEnabled && store.inboxFilter == .focused && store.otherCount > 0 {
            InboxZeroView(title: "Focus is clear", message: "\(InkFormat.badge(store.otherCount)) waiting in Other.")
        } else if store.focusedInboxEnabled && store.inboxFilter == .other {
            InboxZeroView(title: "Nothing in Other", message: "Newsletters and notifications land here.")
        } else {
            InboxZeroView()
        }
    }

    private var symbol: String {
        store.scope.role?.systemImage ?? MailboxRole.custom.systemImage
    }

    private var title: String {
        switch store.scope.role {
        case .flagged: return "Nothing starred"
        case .snoozed: return "Nothing snoozed"
        case .sent: return "Nothing sent yet"
        case .drafts: return "No drafts"
        case .archive, .all: return "Nothing archived"
        case .junk: return "No spam"
        case .trash: return "Trash is empty"
        case .inbox, .custom, .none: return "This folder is empty"
        }
    }

    private var message: String? {
        switch store.scope.role {
        case .flagged: return "Press S to star a conversation and keep it close."
        case .snoozed: return "Press H to snooze a conversation until a better time."
        case .archive, .all: return "Press E to archive. Archived mail waits here."
        case .junk: return "Mail you mark as spam lands here."
        default: return nil
        }
    }
}
#endif
