import SwiftUI
import InkCore

/// Chooses onboarding or the platform's main UI, and hosts app-wide sheets and the toast.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        let accent = app.settings.accent.color
        let composeDraft: Binding<OutgoingMessage?> = searchHostsSheets ? .constant(nil) : $app.composeDraft
        let isSnoozePickerPresented: Binding<Bool> = searchHostsSheets ? .constant(false) : $app.isSnoozePickerPresented
        Group {
            if showsWelcome {
                WelcomeFlow()
                    .transition(.opacity)
            } else {
                main
                    .transition(.opacity)
            }
        }
        .animation(InkMotion.smooth, value: showsWelcome)
        .background(Ink.background.ignoresSafeArea())
        .sheet(item: composeDraft) { draft in
            ComposeView(draft: draft)
                .environment(app)
                .environment(app.store)
                .environment(app.settings)
                .environment(\.inkAccent, accent)
                .tint(accent)
        }
        .sheet(isPresented: isSnoozePickerPresented, onDismiss: { app.snoozeTargets = [] }) {
            SnoozePicker(conversations: app.snoozeTargets)
                .environment(app)
                .environment(\.inkAccent, accent)
                .tint(accent)
        }
        .sheet(isPresented: $app.isAddAccountPresented) {
            AddAccountFlow()
                .environment(app)
                .environment(app.store)
                .environment(app.settings)
                .environment(\.inkAccent, accent)
                .tint(accent)
        }
        #if os(iOS)
        .sheet(isPresented: $app.isSettingsPresented) {
            SettingsView()
                .environment(app)
                .environment(app.store)
                .environment(app.settings)
                .environment(\.inkAccent, accent)
                .tint(accent)
        }
        #endif
        .overlay { ToastOverlay(bottomInset: toastInset) }
        .environment(\.inkAccent, accent)
        .tint(accent)
        .preferredColorScheme(app.settings.appearance.colorScheme)
        .onOpenURL { app.handleOpenURL($0) }
        .task { await app.start() }
    }

    private var showsWelcome: Bool {
        if let scene = app.screenshot { return scene == .welcome }
        return !app.store.hasAccounts
    }

    /// On iPhone, search is a full-screen cover, and a sheet can't present from underneath it.
    /// While it's up, `SearchScreen` hosts Compose and Snooze itself, so these stay closed here.
    private var searchHostsSheets: Bool {
        #if os(iOS)
        return app.isSearchPresented
        #else
        return false
        #endif
    }

    @ViewBuilder private var main: some View {
        #if os(iOS)
        PhoneRootView()
        #else
        MacRootView()
        #endif
    }

    private var toastInset: CGFloat {
        #if os(iOS)
        // Clear the floating compose button on the inbox.
        return app.phonePath.isEmpty ? InkSize.fab + InkSpace.s : 64
        #else
        return 0
        #endif
    }
}
