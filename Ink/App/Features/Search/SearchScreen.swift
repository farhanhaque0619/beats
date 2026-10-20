import SwiftUI
import InkCore

/// Search across your mail. Before typing: recent searches and quick filters. While typing:
/// instant results from the cache, then the server's results in "More results".
///
/// - Full screen (iPhone, `embedded: false`): its own field with Cancel and its own navigation
///   stack; results push the thread.
/// - Embedded (Mac list column, `embedded: true`): no navigation stack; opening a result selects
///   it via `app.open`. When the Mac toolbar's `.searchable` field is active above it
///   (`isSearching`), this screen hides its own field and follows `initialQuery` as it changes.
struct SearchScreen: View {
    private let embedded: Bool
    private let initialQuery: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSearching) private var isSearching
    @Environment(\.inkAccent) private var accent

    @State private var query: String
    /// The query the user submitted (Return, a recent search, retry): searched right away.
    @State private var submittedQuery: String?
    @State private var attempt = 0
    @State private var filter: SearchQuickFilter? = nil
    @State private var localResults: [Conversation] = []
    @State private var serverResults: [Conversation] = []
    @State private var serverState: SearchServerState = .idle
    @State private var path: [String] = []
    @FocusState private var isFieldFocused: Bool
    #if os(iOS)
    @Namespace private var zoom
    #endif

    init(embedded: Bool = false, initialQuery: String = "") {
        self.embedded = embedded
        self.initialQuery = initialQuery
        let trimmed = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        _query = State(initialValue: initialQuery)
        _submittedQuery = State(initialValue: trimmed.isEmpty ? nil : trimmed)
    }

    var body: some View {
        @Bindable var app = app
        if embedded {
            content
        } else {
            NavigationStack(path: $path) {
                content
                    #if os(iOS)
                    .toolbar(.hidden, for: .navigationBar)
                    #endif
                    .navigationDestination(for: String.self) { id in
                        destination(for: id)
                    }
            }
            #if os(iOS)
            // A full-screen cover hides RootView's sheets and toast, so a thread opened from the
            // results replies, snoozes and undoes from here (RootView holds its own back meanwhile).
            .overlay { ToastOverlay(bottomInset: path.isEmpty ? 0 : 64) }
            .sheet(item: $app.composeDraft) { draft in
                ComposeView(draft: draft)
                    .environment(app)
                    .environment(app.store)
                    .environment(app.settings)
                    .environment(\.inkAccent, accent)
                    .tint(accent)
            }
            .sheet(isPresented: $app.isSnoozePickerPresented, onDismiss: { app.snoozeTargets = [] }) {
                SnoozePicker(conversations: app.snoozeTargets)
                    .environment(app)
                    .environment(\.inkAccent, accent)
                    .tint(accent)
            }
            #endif
            .environment(app.store)
            .environment(app.settings)
        }
    }

    // MARK: Layout

    private var content: some View {
        VStack(spacing: 0) {
            if showsField {
                header
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    filterBar
                    if isIdle {
                        idleContent
                    } else {
                        resultsContent
                    }
                }
                .padding(.bottom, InkSpace.xxl)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.immediately)
            #endif
        }
        .background(Ink.background)
        .onAppear(perform: prepareScreenshot)
        .task { await focusField() }
        .task(id: trigger) { await search() }
        .onChange(of: initialQuery) { _, newValue in
            query = newValue
        }
    }

    private var header: some View {
        HStack(spacing: InkSpace.m) {
            InkSearchField(text: $query, prompt: "Search mail", onSubmit: submit, focus: $isFieldFocused)
            if !embedded {
                Button("Cancel", action: close)
                    .font(.body)
                    .foregroundStyle(Ink.primary)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
        }
        // Same edges as the chips and results below.
        .padding(.horizontal, InkSpace.gutter)
        .padding(.top, InkSpace.s)
        .padding(.bottom, InkSpace.xs)
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: InkSpace.s) {
                ForEach(SearchQuickFilter.allCases) { option in
                    Chip(title: option.title, systemImage: option.systemImage, isSelected: filter == option) {
                        withAnimation(InkMotion.snappy) { filter = filter == option ? nil : option }
                    }
                }
            }
            .padding(.horizontal, InkSpace.gutter)
            .padding(.vertical, InkSpace.s)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var idleContent: some View {
        let recents = Array(store.recentSearches.prefix(8))
        if recents.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "Search your mail",
                message: "People, subjects, words. Ink looks on this device first, then asks your server."
            )
            .padding(.top, InkSpace.xxl)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                SectionHeaderView("Recent")
                Button("Clear", action: clearRecents)
                    .font(InkFont.caption)
                    .foregroundStyle(Ink.secondary)
                    .buttonStyle(.plain)
                    .padding(.horizontal, InkSpace.gutter)
                    .padding(.vertical, InkSpace.s)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Clear recent searches")
            }
            ForEach(recents, id: \.self) { recent in
                recentRow(recent)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var resultsContent: some View {
        if trimmedQuery.isEmpty {
            // A quick filter on its own narrows the mailbox on screen.
            let matches = applyFilter(store.conversations)
            SectionHeaderView(filterOnlyTitle)
            if matches.isEmpty {
                EmptyStateView(
                    systemImage: filter?.systemImage ?? "tray",
                    title: "Nothing here",
                    message: filter?.emptyMessage(in: scopeTitle) ?? "Nothing in \(scopeTitle)."
                )
            } else {
                rows(matches)
            }
        } else {
            let localIDs = Set(localResults.map(\.id))
            let local = applyFilter(localResults)
            let more = applyFilter(serverResults.filter { !localIDs.contains($0.id) })
            rows(local)
            serverSection(more: more, hasLocal: !local.isEmpty)
        }
    }

    @ViewBuilder
    private func serverSection(more: [Conversation], hasLocal: Bool) -> some View {
        switch serverState {
        case .idle:
            EmptyView()
        case .loading:
            SectionHeaderView("More results")
            LoadingDots()
                .frame(maxWidth: .infinity)
                .padding(.vertical, InkSpace.xl)
        case .loaded:
            if !more.isEmpty {
                SectionHeaderView("More results")
                rows(more)
            } else if !hasLocal {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "No results",
                    message: "Nothing matches “\(trimmedQuery)”."
                )
                .padding(.top, InkSpace.xl)
            }
        case .failed(let message):
            SectionHeaderView("More results")
            failureRow(message)
        }
    }

    private func rows(_ conversations: [Conversation]) -> some View {
        let style = ConversationRowStyle(settings: settings, scope: .unified(.all), accountCount: store.accounts.count)
        let myAddresses = Set(store.accounts.map { $0.emailAddress.lowercased() })
        return ForEach(conversations) { conversation in
            resultRow(conversation, style: style, myAddresses: myAddresses)
        }
    }

    @ViewBuilder
    private func resultRow(_ conversation: Conversation, style: ConversationRowStyle, myAddresses: Set<String>) -> some View {
        let button = Button {
            open(conversation)
        } label: {
            ConversationRow(
                conversation: conversation,
                style: style,
                accountColorIndex: store.account(id: conversation.accountID)?.colorIndex ?? 0,
                myAddresses: myAddresses,
                snoozedUntil: store.snoozeDate(for: conversation)
            )
            .equatable()
            .overlay(alignment: .bottom) {
                SearchRowSeparator(leadingInset: separatorInset(for: style))
            }
        }
        .buttonStyle(SearchRowButtonStyle(isSelected: embedded && app.selection.contains(conversation.id)))
        .transition(.opacity)
        #if os(iOS)
        if embedded {
            button
        } else {
            button.matchedTransitionSource(id: conversation.id, in: zoom)
        }
        #else
        button
        #endif
    }

    private func recentRow(_ recent: String) -> some View {
        Button {
            apply(recent)
        } label: {
            HStack(spacing: InkSpace.m) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(Ink.tertiary)
                Text(recent)
                    .font(.body)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: InkSpace.s)
                Image(systemName: "arrow.up.left")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, InkSpace.gutter)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(SearchRowButtonStyle(isSelected: false))
        .accessibilityLabel("Search for \(recent)")
    }

    private func failureRow(_ message: String) -> some View {
        HStack(spacing: InkSpace.m) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Ink.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .lineLimit(2)
            Spacer(minLength: InkSpace.s)
            Button("Retry", action: retry)
                .font(InkFont.button)
                .foregroundStyle(accent)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, InkSpace.gutter)
        .padding(.vertical, InkSpace.m)
    }

    @ViewBuilder
    private func destination(for id: String) -> some View {
        #if os(iOS)
        ThreadScreen(conversationID: id)
            .navigationTransition(.zoom(sourceID: id, in: zoom))
        #else
        ThreadScreen(conversationID: id)
        #endif
    }

    // MARK: Derived

    private var store: MailStore { app.store }
    private var settings: AppSettings { app.settings }

    /// Our own field, unless a toolbar search field above us is already driving the query.
    private var showsField: Bool { !embedded || !isSearching }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isIdle: Bool { trimmedQuery.isEmpty && filter == nil }

    private var trigger: SearchTrigger {
        SearchTrigger(query: trimmedQuery, submitted: submittedQuery, attempt: attempt)
    }

    private var scopeTitle: String {
        let title = store.title(for: store.scope)
        return title.isEmpty ? "this mailbox" : title
    }

    private var filterOnlyTitle: String {
        guard let filter else { return scopeTitle }
        return "\(filter.title) in \(scopeTitle)"
    }

    private func applyFilter(_ conversations: [Conversation]) -> [Conversation] {
        guard let filter else { return conversations }
        return conversations.filter { filter.matches($0) }
    }

    private func separatorInset(for style: ConversationRowStyle) -> CGFloat {
        guard style.showAvatar else { return InkSpace.gutter }
        let avatar = style.compact ? InkSize.avatarSmall : InkSize.avatar
        return InkSpace.gutter + avatar + InkSpace.m
    }

    // MARK: Actions

    /// Local results after a 120 ms pause in typing, the server after 350 ms; a submitted query
    /// skips both waits. Typing again cancels the task and starts over.
    private func search() async {
        let current = trimmedQuery
        guard !current.isEmpty else {
            localResults = []
            serverResults = []
            serverState = .idle
            return
        }
        if serverState != .idle {
            // Results from the previous query no longer apply.
            withAnimation(InkMotion.snappy) {
                serverResults = []
                serverState = .idle
            }
        }
        let immediate = submittedQuery == current
        if !immediate {
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
        }
        let local = store.searchLocal(current)
        withAnimation(InkMotion.snappy) { localResults = local }
        if !immediate {
            try? await Task.sleep(for: .milliseconds(230))
            if Task.isCancelled { return }
        }
        withAnimation(InkMotion.snappy) { serverState = .loading }
        do {
            let found = try await store.searchServer(current)
            if Task.isCancelled { return }
            withAnimation(InkMotion.smooth) {
                serverResults = found
                serverState = .loaded
            }
        } catch {
            if Task.isCancelled { return }
            withAnimation(InkMotion.snappy) {
                serverResults = []
                serverState = .failed(error.localizedDescription)
            }
        }
    }

    private func submit() {
        let current = trimmedQuery
        guard !current.isEmpty else { return }
        store.recordSearch(current)
        submittedQuery = current
        attempt += 1
    }

    private func retry() {
        Haptics.tick()
        submittedQuery = trimmedQuery
        attempt += 1
    }

    private func apply(_ recent: String) {
        Haptics.tick()
        query = recent
        submit()
    }

    private func clearRecents() {
        Haptics.tick()
        withAnimation(InkMotion.snappy) { store.clearRecentSearches() }
    }

    private func open(_ conversation: Conversation) {
        let current = trimmedQuery
        if !current.isEmpty { store.recordSearch(current) }
        if embedded {
            app.open(conversation.id)
        } else {
            path.append(conversation.id)
        }
    }

    private func close() {
        app.isSearchPresented = false
        dismiss()
    }

    private func focusField() async {
        guard showsField, app.screenshot == nil else { return }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        isFieldFocused = true
    }

    /// The search screenshot shows results for a real-looking query.
    private func prepareScreenshot() {
        guard app.screenshot == .search, query.isEmpty else { return }
        query = "flight"
        submittedQuery = "flight"
    }
}

/// What restarts the search task.
private struct SearchTrigger: Equatable {
    var query: String
    var submitted: String?
    var attempt: Int
}

private enum SearchServerState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

private enum SearchQuickFilter: String, CaseIterable, Identifiable {
    case unread, starred, attachments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unread: return "Unread"
        case .starred: return "Starred"
        case .attachments: return "Attachments"
        }
    }

    func emptyMessage(in place: String) -> String {
        switch self {
        case .unread: return "No unread conversations in \(place)."
        case .starred: return "No starred conversations in \(place)."
        case .attachments: return "No conversations with attachments in \(place)."
        }
    }

    var systemImage: String {
        switch self {
        case .unread: return "envelope.badge"
        case .starred: return "star"
        case .attachments: return "paperclip"
        }
    }

    func matches(_ conversation: Conversation) -> Bool {
        switch self {
        case .unread: return conversation.isUnread
        case .starred: return conversation.isFlagged
        case .attachments: return conversation.hasAttachments
        }
    }
}

/// Pressed (and, on Mac, selected) rows get the selection tint.
private struct SearchRowButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || isSelected ? Ink.selection : Color.clear)
            .animation(InkMotion.snappy, value: configuration.isPressed)
    }
}

/// Hairline under a result, inset to the text column.
private struct SearchRowSeparator: View {
    let leadingInset: CGFloat
    @Environment(\.displayScale) private var displayScale

    init(leadingInset: CGFloat) {
        self.leadingInset = leadingInset
    }

    var body: some View {
        Rectangle()
            .fill(Ink.hairline)
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}
