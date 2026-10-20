#if os(macOS)
import SwiftUI
import InkCore

/// Search results in the middle column: instant local matches as you type (120 ms debounce),
/// then server results under "More results" after 350 ms of quiet or on Return.
struct MacSearchResults: View {
    let query: String
    let submitCount: Int
    var focus: FocusState<MacPane?>.Binding

    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.inkAccent) private var accent

    @State private var local: [Conversation] = []
    @State private var remote: [Conversation] = []
    @State private var remoteState: RemoteState = .idle
    @State private var hasSearchedLocally = false
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
        let order = (local + remote).map(\.id)
        VStack(spacing: 0) {
            header
            List(selection: $app.selection) {
                if !local.isEmpty {
                    Section {
                        ForEach(local) { conversation in
                            resultRow(conversation, context: context, actions: actions)
                        }
                    } header: {
                        sectionTitle("In your mail")
                    }
                }
                Section {
                    ForEach(remote) { conversation in
                        resultRow(conversation, context: context, actions: actions)
                    }
                    remoteStatus
                } header: {
                    sectionTitle("More results")
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                MacConversationMenu(app: app, ids: ids)
            }
            .focused(focus, equals: .list)
            .macKeyboardShortcuts(app: app, order: order, handlesArrowKeys: false)
            .overlay {
                if isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass", title: "No results", message: "Nothing matches “\(query)”.")
                        .transition(.opacity)
                }
            }
            .animation(InkMotion.smooth, value: isEmpty)
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

    private var header: some View {
        let count = local.count + remote.count
        return HStack(alignment: .firstTextBaseline, spacing: InkSpace.s) {
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

    private func resultRow(_ conversation: Conversation, context: MacRowContext, actions: MacActions) -> some View {
        context.row(conversation)
            .equatable()
            .listRowInsets(EdgeInsets())
            .listRowSeparatorTint(Ink.hairline)
            .macSwipeActions(for: conversation, swipes: settings.swipes, accent: accent) { action in
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

    @ViewBuilder
    private var remoteStatus: some View {
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
            if remote.isEmpty && !local.isEmpty {
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

    private var isEmpty: Bool {
        hasSearchedLocally && local.isEmpty && remote.isEmpty && remoteState == .done
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
