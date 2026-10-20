#if os(macOS)
import SwiftUI
import InkCore

/// Search results in the middle column: instant local matches as you type (120 ms debounce),
/// then server results under "More results" after 350 ms of quiet or on Return.
struct MacSearchResults: View {
    let query: String
    let submitCount: Int
    var focus: FocusState<MacPane?>.Binding
    /// Clears the search field and goes back to the mailbox (Esc with nothing selected).
    var endSearch: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.inkAccent) private var accent

    @State private var local: [Conversation] = []
    @State private var remote: [Conversation] = []
    @State private var remoteState: RemoteState = .idle
    @State private var hasSearchedLocally = false
    /// Results that have since left (archived, trashed, moved) and are no longer shown.
    @State private var hiddenIDs: Set<String> = []
    @State private var lastServerQuery: String?
    /// The submit count already acted on, so a fresh results view doesn't treat an old Return
    /// as a new one.
    @State private var handledSubmitCount: Int?

    private enum RemoteState: Equatable {
        case idle, loading, done
        case failed(String)
    }

    var body: some View {
        @Bindable var app = app
        let context = MacRowContext(store: store, settings: settings)
        let actions = MacActions(app: app)
        let shownLocal = local.filter { !hiddenIDs.contains($0.id) }
        let shownRemote = remote.filter { !hiddenIDs.contains($0.id) }
        let order = (shownLocal + shownRemote).map(\.id)
        let isEmpty = hasSearchedLocally && order.isEmpty && remoteState == .done
        VStack(spacing: 0) {
            header(count: order.count)
            ScrollViewReader { proxy in
                List(selection: $app.selection) {
                    if !shownLocal.isEmpty {
                        Section {
                            ForEach(shownLocal) { conversation in
                                resultRow(conversation, context: context, actions: actions)
                            }
                        } header: {
                            sectionTitle("In your mail")
                        }
                    }
                    if showsRemoteSection(shownRemote: shownRemote, shownLocal: shownLocal) {
                        Section {
                            ForEach(shownRemote) { conversation in
                                resultRow(conversation, context: context, actions: actions)
                            }
                            remoteStatus(hasLocal: !shownLocal.isEmpty, hasRemote: !shownRemote.isEmpty)
                        } header: {
                            sectionTitle("More results")
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: String.self) { ids in
                    MacConversationMenu(app: app, ids: ids)
                }
                .focused(focus, equals: .list)
                .macKeyboardShortcuts(app: app, pane: .list, escapeWithoutSelection: endSearch)
                .overlay {
                    if isEmpty {
                        EmptyStateView(systemImage: "magnifyingglass", title: "No results", message: "Nothing matches “\(query)”.")
                            .transition(.opacity)
                    }
                }
                .animation(InkMotion.smooth, value: isEmpty)
                .onChange(of: app.focusedConversationID) { _, id in
                    // j/k from the list or the reader: keep the selected result in view.
                    guard let id, order.contains(id) else { return }
                    withAnimation(InkMotion.snappy) { proxy.scrollTo(id) }
                }
            }
        }
        .onChange(of: order, initial: true) { _, newOrder in
            MacVisibleList.searchOrder = newOrder
        }
        .onDisappear {
            MacVisibleList.searchOrder = nil
        }
        .onChange(of: store.toast?.id) { _, _ in
            updateHiddenResults()
        }
        .onChange(of: store.lastSyncedAt) { _, _ in
            updateHiddenResults()
        }
        .task(id: query) {
            await searchAsYouType()
        }
        .task(id: submitCount) {
            guard let handled = handledSubmitCount else {
                handledSubmitCount = submitCount
                return
            }
            guard submitCount != handled else { return }
            handledSubmitCount = submitCount
            await searchServer(force: true)
        }
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: InkSpace.s) {
            Text("Search")
                .font(InkFont.title)
                .tracking(InkTracking.title)
                .foregroundStyle(Ink.primary)
                .accessibilityAddTraits(.isHeader)
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(InkFont.meta)
                    .foregroundStyle(Ink.tertiary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, InkSpace.gutter)
        .padding(.top, InkSpace.m)
        .padding(.bottom, InkSpace.s)
        .animation(InkMotion.snappy, value: count)
    }

    /// A result drawn from the store's current copy, so starring or reading it shows at once.
    private func resultRow(_ snapshot: Conversation, context: MacRowContext, actions: MacActions) -> some View {
        let conversation = store.conversation(id: snapshot.id) ?? snapshot
        return context.row(conversation)
            .equatable()
            .listRowInsets(EdgeInsets())
            .listRowSeparatorTint(Ink.hairline)
            .macSwipeActions(for: conversation, swipes: settings.swipes, accent: accent) { action in
                actions.perform(action, on: [conversation])
            }
            .macHoverActions(for: conversation) { action in
                actions.perform(action, on: [conversation])
            }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption2, design: .default, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Ink.tertiary)
    }

    /// "More results" appears once there's something to say there.
    private func showsRemoteSection(shownRemote: [Conversation], shownLocal: [Conversation]) -> Bool {
        switch remoteState {
        case .idle: return !shownRemote.isEmpty
        case .loading, .failed: return true
        case .done: return !shownRemote.isEmpty || !shownLocal.isEmpty
        }
    }

    @ViewBuilder
    private func remoteStatus(hasLocal: Bool, hasRemote: Bool) -> some View {
        switch remoteState {
        case .loading:
            HStack {
                Spacer()
                LoadingDots()
                Spacer()
            }
            .padding(.vertical, InkSpace.m)
            .listRowSeparator(.hidden)
            .selectionDisabled()
        case .failed(let message):
            HStack(spacing: InkSpace.s) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(2)
                Spacer(minLength: InkSpace.s)
                Button("Try again") {
                    Task { await searchServer(force: true) }
                }
                .buttonStyle(.plain)
                .font(InkFont.button)
                .foregroundStyle(accent)
                .fixedSize()
            }
            .padding(.horizontal, InkSpace.gutter)
            .padding(.vertical, InkSpace.s)
            .listRowSeparator(.hidden)
            .selectionDisabled()
        case .done:
            if !hasRemote && hasLocal {
                Text("Nothing else on the server.")
                    .font(.subheadline)
                    .foregroundStyle(Ink.tertiary)
                    .padding(.horizontal, InkSpace.gutter)
                    .padding(.vertical, InkSpace.s)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
        case .idle:
            EmptyView()
        }
    }

    /// Hides results that have left since the search ran: moved out locally (archive, trash,
    /// spam, another folder: the store no longer has them) or now sitting in Trash or Spam.
    /// Undo brings them back, since the store has them again.
    private func updateHiddenResults() {
        let listed = Dictionary(store.conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var filedAway: [String: Set<String>] = [:]
        var hidden: Set<String> = []
        for snapshot in local + remote {
            guard let conversation = listed[snapshot.id] ?? store.conversation(id: snapshot.id) else {
                hidden.insert(snapshot.id)
                continue
            }
            let accountID = conversation.accountID
            let paths: Set<String>
            if let known = filedAway[accountID] {
                paths = known
            } else {
                paths = Set(store.mailboxes(for: accountID).filter { $0.role == .trash || $0.role == .junk }.map(\.path))
                filedAway[accountID] = paths
            }
            if !paths.isEmpty, !conversation.messages.isEmpty, conversation.messages.allSatisfy({ paths.contains($0.mailboxPath) }) {
                hidden.insert(snapshot.id)
            }
        }
        guard hidden != hiddenIDs else { return }
        withAnimation(InkMotion.rowRemoval) { hiddenIDs = hidden }
    }

    private func searchAsYouType() async {
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        let matches = store.searchLocal(query)
        withAnimation(InkMotion.snappy) {
            local = matches
            remote = []
            remoteState = .idle
            hasSearchedLocally = true
            hiddenIDs = []
        }
        lastServerQuery = nil
        try? await Task.sleep(nanoseconds: 230_000_000)
        guard !Task.isCancelled else { return }
        await searchServer(force: false)
    }

    /// Server search for the current query; skipped when it already ran unless forced (Return).
    private func searchServer(force: Bool) async {
        let current = query
        guard force || lastServerQuery != current else { return }
        lastServerQuery = current
        remoteState = .loading
        do {
            let results = try await store.searchServer(current)
            guard !Task.isCancelled, current == lastServerQuery else { return }
            let known = Set(local.map(\.id))
            withAnimation(InkMotion.smooth) {
                remote = results.filter { !known.contains($0.id) }
                remoteState = .done
            }
        } catch {
            guard !Task.isCancelled, current == lastServerQuery else { return }
            remoteState = .failed(error.localizedDescription)
        }
    }
}
#endif
