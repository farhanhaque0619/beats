#if os(iOS)
import SwiftUI
import InkCore

/// One entry of the flattened inbox list: a day header or a conversation.
struct InboxListItem: Identifiable {
    enum Kind {
        case section(String)
        /// `showsSeparator` is false for the last row of a day.
        case conversation(Conversation, showsSeparator: Bool)
    }

    let id: String
    let kind: Kind

    /// Groups conversations (newest first) into day sections without reordering them. A day
    /// that shows up twice (a woken snooze on top, say) gets a second, distinct header ID.
    /// Runs on every list update (each swipe, each sync), so titles are worked out once per day,
    /// not once per conversation.
    static func build(from conversations: [Conversation], now: Date = Date()) -> [InboxListItem] {
        var sections = InboxDaySections(now: now)
        let titles = conversations.map { sections.title(for: $0.date) }
        var items: [InboxListItem] = []
        items.reserveCapacity(conversations.count + 6)
        var occurrences: [String: Int] = [:]
        for index in conversations.indices {
            let title = titles[index]
            if index == 0 || titles[index - 1] != title {
                let occurrence = (occurrences[title] ?? 0) + 1
                occurrences[title] = occurrence
                let id = occurrence == 1 ? "section|\(title)" : "section|\(title)|\(occurrence)"
                items.append(InboxListItem(id: id, kind: .section(title)))
            }
            let endsSection = index == conversations.count - 1 || titles[index + 1] != title
            let conversation = conversations[index]
            items.append(InboxListItem(id: conversation.id, kind: .conversation(conversation, showsSeparator: !endsSection)))
        }
        return items
    }
}

/// Day-section titles for one pass over a list. `InkDate.sectionTitle` depends only on the
/// day, and lists run newest first, so it is asked once per distinct day and each conversation
/// in between costs two date comparisons instead of a round of calendar maths.
private struct InboxDaySections {
    private let now: Date
    private let calendar: Calendar
    private var lastDay: (interval: DateInterval, title: String)?

    init(now: Date, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    mutating func title(for date: Date) -> String {
        if let lastDay, date >= lastDay.interval.start, date < lastDay.interval.end {
            return lastDay.title
        }
        let title = InkDate.sectionTitle(for: date, now: now, calendar: calendar)
        if let interval = calendar.dateInterval(of: .day, for: date) {
            lastDay = (interval, title)
        }
        return title
    }
}

/// The conversations under the inbox header: day sections of swipeable rows, infinite scroll,
/// the first-load shimmer and the empty states. Lives in its own view so header and scroll
/// state changes never re-render the rows.
struct InboxList: View {
    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.displayScale) private var displayScale

    /// Rows register as zoom sources for the thread transition when set.
    let zoomNamespace: Namespace.ID?

    /// Rows that already flew off-screen from a swipe: they only fade while the list closes up.
    @State private var sweptAway: Set<String> = []
    /// Scopes that have shown mail or finished a sync, so the shimmer never returns for them.
    @State private var loadedScopes: Set<MailScope> = []
    /// Ends the cold-start shimmer even if nothing ever reports a sync.
    @State private var hasSettled = false
    /// The footer is inside the lazy stack's window, so older mail should keep coming.
    @State private var isFooterVisible = false
    /// A load-more run is in flight (it can page several times in a row, see `loadMoreIfNeeded`).
    @State private var isPaging = false

    /// Row width, measured once here instead of by every row (§5.7).
    @State private var rowWidth: CGFloat = 0

    /// Pages in a row that may add nothing to this list before paging waits for the next scroll.
    private static let maxQuietPages = 3

    /// How far the screenshot scene's first row is swiped: left, between the short and long
    /// thresholds, so it shows the default archive about to commit.
    private static let screenshotSwipeFraction: CGFloat = -0.42

    private static var rowTransition: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity))
    }

    var body: some View {
        let conversations = store.conversations
        Group {
            if !conversations.isEmpty {
                rows(conversations)
            } else if showsSkeleton {
                InboxSkeletonList(showsAvatar: settings.showAvatars, compact: settings.density == .compact)
                    .transition(.opacity)
            } else {
                emptyState
                    .transition(.opacity)
            }
        }
        .animation(InkMotion.smooth, value: conversations.isEmpty)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            rowWidth = width
        }
        .onChange(of: conversations.isEmpty, initial: true) { _, isEmpty in
            if !isEmpty { loadedScopes.insert(store.scope) }
        }
        .onChange(of: store.syncStatus) { oldStatus, newStatus in
            guard oldStatus == .syncing, newStatus != .syncing else { return }
            loadedScopes.insert(store.scope)
            // Paging waits out syncs; pick up where it left off if the end is still showing.
            if newStatus == .idle, isFooterVisible { loadMoreIfNeeded() }
        }
        .task {
            try? await Task.sleep(for: .seconds(2))
            hasSettled = true
        }
    }

    // MARK: Rows

    private func rows(_ conversations: [Conversation]) -> some View {
        let scope = store.scope
        let style = ConversationRowStyle(settings: settings, scope: scope, accountCount: store.accounts.count)
        let items = InboxListItem.build(from: conversations)
        let ids = conversations.map(\.id)
        let loadMoreTriggers = Set(ids.suffix(5))
        let accounts = store.accounts
        var accountColors: [String: Int] = [:]
        for account in accounts where accountColors[account.id] == nil {
            accountColors[account.id] = account.colorIndex
        }
        let myAddresses = Set(accounts.map { $0.emailAddress.lowercased() })
        let separatorInset = style.textLeadingInset
        let screenshotRowID: String? = app.screenshot == .swipe ? conversations.first?.id : nil
        let context = InboxRowContext(
            style: style,
            swipes: settings.swipes,
            rowWidth: rowWidth,
            accountColors: accountColors,
            myAddresses: myAddresses,
            separatorInset: separatorInset,
            showsSnoozeTime: scope.role == .snoozed,
            screenshotRowID: screenshotRowID
        )
        return LazyVStack(spacing: 0, pinnedViews: []) {
            ForEach(items) { item in
                switch item.kind {
                case .section(let title):
                    SectionHeaderView(title)
                        .transition(.opacity)
                case .conversation(let conversation, let showsSeparator):
                    row(conversation, showsSeparator: showsSeparator, context: context)
                        .onAppear {
                            if loadMoreTriggers.contains(conversation.id) { loadMoreIfNeeded() }
                        }
                }
            }
            if store.canLoadMore || store.isLoadingMore {
                InboxListFooter(isLoading: store.isLoadingMore)
                    .onAppear {
                        isFooterVisible = true
                        loadMoreIfNeeded()
                    }
                    .onDisappear { isFooterVisible = false }
            }
        }
        .animation(InkMotion.rowRemoval, value: ids)
    }

    private func row(_ conversation: Conversation, showsSeparator: Bool, context: InboxRowContext) -> some View {
        let id = conversation.id
        return SwipeRow(
            configuration: context.swipes,
            width: context.rowWidth,
            isUnread: conversation.isUnread,
            isFlagged: conversation.isFlagged,
            debugFraction: id == context.screenshotRowID ? Self.screenshotSwipeFraction : nil,
            onTap: { app.open(id) },
            onWillRemove: { _ in sweptAway.insert(id) },
            onCommit: { action in commit(action, on: conversation) }
        ) {
            ConversationRow(
                conversation: conversation,
                style: context.style,
                accountColorIndex: context.accountColors[conversation.accountID] ?? 0,
                myAddresses: context.myAddresses,
                snoozedUntil: context.showsSnoozeTime ? store.snoozeDate(for: conversation) : nil
            )
            .equatable()
        }
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle()
                    .fill(Ink.hairline)
                    .frame(height: 1 / max(displayScale, 1))
                    .padding(.leading, context.separatorInset)
                    .allowsHitTesting(false)
            }
        }
        .inboxZoomSource(id: id, in: zoomNamespace)
        .contextMenu {
            InboxRowMenu(conversation: conversation, scope: store.scope, folders: moveTargets(for: conversation.accountID)) { command in
                handle(command, on: conversation)
            }
        } preview: {
            InboxRowPreview(conversation: conversation, myAddresses: context.myAddresses)
        }
        .transition(sweptAway.contains(id) ? AnyTransition.opacity : Self.rowTransition)
    }

    // MARK: Actions

    /// A committed swipe. Rows that flew off are already gone from view, so the list just closes
    /// up; everything else animates in place.
    private func commit(_ action: SwipeAction, on conversation: Conversation) {
        guard action.removesFromList, action != .snooze else {
            withAnimation(InkMotion.snappy) { app.perform(action, on: [conversation]) }
            return
        }
        withAnimation(InkMotion.rowRemoval) { app.perform(action, on: [conversation]) }
        celebrateIfInboxZero()
        let id = conversation.id
        Task {
            try? await Task.sleep(for: .seconds(1))
            sweptAway.remove(id)
        }
    }

    private func handle(_ command: InboxRowCommand, on conversation: Conversation) {
        Haptics.tick()
        switch command {
        case .action(let action):
            withAnimation(action.removesFromList ? InkMotion.rowRemoval : InkMotion.snappy) {
                app.perform(action, on: [conversation])
            }
        case .move(let mailbox):
            withAnimation(InkMotion.rowRemoval) { store.move([conversation], to: mailbox) }
        case .moveToInbox:
            withAnimation(InkMotion.rowRemoval) { store.moveToInbox([conversation]) }
        case .unsnooze:
            withAnimation(InkMotion.rowRemoval) { store.unsnooze([conversation]) }
        }
        celebrateIfInboxZero()
    }

    /// A success tap when your own action empties the whole inbox: not a filter, not a sync.
    private func celebrateIfInboxZero() {
        guard store.conversations.isEmpty, store.scope.role == .inbox else { return }
        let page = currentPage
        guard page != .other, page != .focus || store.otherCount == 0 else { return }
        Haptics.success()
    }

    /// Pages in older mail when the end of the list comes into view. A page can add nothing to
    /// this list (all of it filed under Other, say), so it keeps going while the end is still
    /// showing, a few pages at most, and stops on an error. It waits while a sync runs: paging a
    /// mailbox before its first sync would mark it as having nothing older.
    private func loadMoreIfNeeded() {
        guard store.canLoadMore, !store.isLoadingMore, !isPaging, store.syncStatus != .syncing else { return }
        isPaging = true
        Task {
            for _ in 0..<Self.maxQuietPages {
                let before = store.conversations.count
                await store.loadMore()
                let addedNothing = store.conversations.count <= before
                guard addedNothing, isFooterVisible, store.canLoadMore, store.toast?.style != .error else { break }
            }
            isPaging = false
        }
    }

    /// Folders worth offering in "Move to…": the inbox and archive (unless already there) and
    /// custom folders, never Sent, Drafts or the like.
    private func moveTargets(for accountID: String) -> [MailboxInfo] {
        let scope = store.scope
        return store.mailboxes(for: accountID).filter { mailbox in
            guard mailbox.isSelectable else { return false }
            switch mailbox.role {
            case .inbox:
                return scope.role != .inbox
            case .archive:
                return scope.role != .archive
            case .custom:
                if case .mailbox(_, let path) = scope { return path != mailbox.path }
                return true
            default:
                return false
            }
        }
    }

    // MARK: Empty and loading

    private var isSyncFailure: Bool {
        if case .failed = store.syncStatus { return true }
        return false
    }

    private var showsSkeleton: Bool {
        if isSyncFailure || loadedScopes.contains(store.scope) { return false }
        return store.syncStatus == .syncing || (store.lastSyncedAt == nil && !hasSettled)
    }

    private var currentPage: InboxPage {
        InboxPage(scope: store.scope, filter: store.inboxFilter, splitEnabled: store.focusedInboxEnabled)
    }

    @ViewBuilder private var emptyState: some View {
        if isSyncFailure {
            EmptyStateView(systemImage: "tray", title: "Nothing to show yet", message: "Pull down to try again.")
                .padding(.top, InkSpace.xxl)
        } else if store.scope.role == .inbox {
            // The cache holds only the newest page of the inbox: once you've cleared it, check
            // for older mail before calling it done.
            inboxEmptyState
                .onAppear { loadMoreIfNeeded() }
        } else {
            let copy = InboxEmptyCopy(scope: store.scope)
            EmptyStateView(systemImage: copy.systemImage, title: copy.title, message: copy.message)
                .padding(.top, InkSpace.xxl)
        }
    }

    /// The inbox's empty states. Inbox zero is only for a truly empty inbox: an empty filter gets a
    /// calm note instead (§5.1, §5.9).
    @ViewBuilder private var inboxEmptyState: some View {
        let page = currentPage
        if page == .focus, store.otherCount > 0 {
            InboxFocusClearView(otherCount: store.otherCount, otherUnread: store.otherUnreadCount) {
                Haptics.tick()
                withAnimation(InkMotion.smooth) { store.inboxFilter = .other }
            }
        } else if page == .other {
            EmptyStateView(
                systemImage: "newspaper",
                title: "Nothing in Other",
                message: "Newsletters and notifications collect here, out of the way."
            )
            .padding(.top, InkSpace.xxl)
        } else {
            InboxZeroView()
        }
    }
}

/// Values shared by every row in one render of the list, computed once.
private struct InboxRowContext {
    var style: ConversationRowStyle
    var swipes: SwipeConfiguration
    var rowWidth: CGFloat
    var accountColors: [String: Int]
    var myAddresses: Set<String>
    var separatorInset: CGFloat
    var showsSnoozeTime: Bool
    var screenshotRowID: String?
}

/// The bottom of the list while older mail can still be paged in: a fixed-height slot, so rows
/// don't jump as the dots come and go, showing `LoadingDots` while a page loads.
private struct InboxListFooter: View {
    let isLoading: Bool

    var body: some View {
        ZStack {
            if isLoading {
                LoadingDots()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .animation(InkMotion.fade, value: isLoading)
    }
}

/// Focus is empty but Other isn't: calm, no celebration, and a way over to Other.
private struct InboxFocusClearView: View {
    let otherCount: Int
    let otherUnread: Int
    let showOther: () -> Void

    var body: some View {
        VStack(spacing: InkSpace.m) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Ink.tertiary)
                .accessibilityHidden(true)
            Text("Focus is clear")
                .font(InkFont.headline)
                .foregroundStyle(Ink.primary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
            Button("Show Other", action: showOther)
                .buttonStyle(.inkSecondary)
                .fixedSize()
                .padding(.top, InkSpace.s)
        }
        .padding(InkSpace.xxxl)
        .frame(maxWidth: .infinity)
        .padding(.top, InkSpace.xxl)
    }

    private var message: String {
        if otherUnread > 0 {
            return otherUnread == 1 ? "1 unread in Other." : "\(otherUnread) unread in Other."
        }
        return otherCount == 1 ? "1 conversation in Other." : "\(otherCount) conversations in Other."
    }
}

/// Calm copy for an empty mailbox that isn't the inbox.
private struct InboxEmptyCopy {
    let systemImage: String
    let title: String
    let message: String?

    init(scope: MailScope) {
        switch scope.role {
        case .flagged:
            self.init("star", "No starred mail", "Star a conversation to keep it close.")
        case .snoozed:
            self.init("clock", "Nothing snoozed", "Snoozed mail comes back right when you need it.")
        case .drafts:
            self.init("doc", "No drafts", nil)
        case .sent:
            self.init("paperplane", "Nothing sent yet", nil)
        case .archive, .all:
            self.init("archivebox", "Nothing archived", "Archived mail waits here, out of the way.")
        case .junk:
            self.init("xmark.bin", "No spam", "Your spam folder is clean.")
        case .trash:
            self.init("trash", "Trash is empty", nil)
        case .inbox:
            self.init("tray", "Inbox zero", nil)
        case .custom, nil:
            self.init("folder", "This folder is empty", nil)
        }
    }

    private init(_ systemImage: String, _ title: String, _ message: String?) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
    }
}

private extension View {
    /// Marks the row as the source of the zoom into its thread (iOS 18).
    @ViewBuilder
    func inboxZoomSource(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}
#endif
