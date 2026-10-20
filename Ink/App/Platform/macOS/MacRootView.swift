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
    /// Where the keyboard was when the palette opened, to hand it back when it closes.
    @State private var paneBeforePalette: MacPane?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebar(focus: $focusedPane)
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 320)
        } content: {
            MacConversationColumn(searchQuery: searchText, searchSubmitCount: searchSubmitCount, focus: $focusedPane,
                                  endSearch: endSearch)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 560)
        } detail: {
            MacDetailColumn(focus: $focusedPane)
                // Room for a readable thread and its toolbar; the window grows to fit.
                .navigationSplitViewColumnWidth(min: 340, ideal: 640)
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
        .macUndoBridge(app: app)
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
            if presented {
                paneBeforePalette = focusedPane
                return
            }
            // Hand the keyboard back to the pane that had it, unless the palette asked for search.
            if !app.isSearchPresented { focusedPane = paneBeforePalette ?? .list }
            paneBeforePalette = nil
        }
        .onChange(of: store.scope) { _, _ in
            searchText = ""
        }
    }

    /// Esc on the results with nothing selected: back to the mailbox, keyboard on its list.
    private func endSearch() {
        withAnimation(InkMotion.smooth) { searchText = "" }
        // The results list is gone after this update; focus the mailbox list that replaces it.
        Task { @MainActor in focusedPane = .list }
    }

    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        store.recordSearch(query)
        searchSubmitCount += 1
        // Return means "show me": hand the keyboard to the results so j/k/e work at once.
        // / brings it back to the field.
        focusedPane = .list
    }
}
#endif
