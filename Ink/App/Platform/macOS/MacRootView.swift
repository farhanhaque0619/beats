#if os(macOS)
import SwiftUI
import InkCore

/// The Mac window: sidebar | conversation list | reader, a toolbar search field whose results
/// replace the list, and the ⌘K command palette over everything.
struct MacRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchText = ""
    @State private var searchSubmitCount = 0
    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedPane: MacPane?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 320)
        } content: {
            MacConversationColumn(searchQuery: searchText, searchSubmitCount: searchSubmitCount, focus: $focusedPane)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 560)
        } detail: {
            MacDetailColumn(focus: $focusedPane)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Search mail"))
        .searchFocused($isSearchFocused)
        .searchSuggestions {
            if searchText.isEmpty {
                ForEach(Array(store.recentSearches.prefix(6)), id: \.self) { recent in
                    Label(recent, systemImage: "clock.arrow.circlepath")
                        .searchCompletion(recent)
                }
            }
        }
        .onSubmit(of: .search) { submitSearch() }
        .overlay {
            if app.isCommandPalettePresented {
                CommandPalette()
                    .transition(.opacity)
            }
        }
        .animation(InkMotion.snappy, value: app.isCommandPalettePresented)
        .background(Ink.background)
        .task {
            focusedPane = .list
        }
        .onChange(of: app.isSearchPresented) { _, presented in
            guard presented else { return }
            isSearchFocused = true
            // Reset on the next turn so other observers of this change still see it.
            Task { @MainActor in app.isSearchPresented = false }
        }
        .onChange(of: app.isCommandPalettePresented) { _, presented in
            // Hand the keyboard back to the list, unless the palette just asked for search.
            if !presented && !app.isSearchPresented { focusedPane = .list }
        }
        .onChange(of: store.scope) { _, _ in
            searchText = ""
        }
    }

    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        store.recordSearch(query)
        searchSubmitCount += 1
    }
}
#endif
