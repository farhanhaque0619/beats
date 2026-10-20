import SwiftUI
import InkCore

/// Chooses onboarding or the platform's main UI, and hosts app-wide sheets and the toast.
struct RootView: View {
    @Environment(AppModel.self) private var app
    /// The conversations the snooze sheet was opened for, kept while it slides away (the model
    /// clears its targets the moment a time is picked).
    @State private var snoozeSubjects: [Conversation] = []

    var body: some View {
        @Bindable var app = app
        let accent = app.settings.accent.color
        let composeDraft: Binding<OutgoingMessage?> = searchHostsSheets ? .constant(nil) : $app.composeDraft
        let isSnoozePickerPresented: Binding<Bool> = searchHostsSheets ? .constant(false) : $app.isSnoozePickerPresented
        Group {
            switch stage {
            case .launching:
                LaunchPlaceholder()
                    .transition(.opacity)
            case .welcome:
                WelcomeFlow()
                    .transition(.opacity)
            case .main:
                main
                    .transition(.opacity)
            }
        }
        .animation(InkMotion.smooth, value: stage)
        .background(Ink.background.ignoresSafeArea())
        .sheet(item: composeDraft) { draft in
            ComposeView(draft: draft)
                .environment(app)
                .environment(app.store)
                .environment(app.settings)
                .environment(\.inkAccent, accent)
                .tint(accent)
        }
        .sheet(isPresented: isSnoozePickerPresented, onDismiss: {
            app.snoozeTargets = []
            snoozeSubjects = []
        }) {
            SnoozePicker(conversations: app.snoozeTargets.isEmpty ? snoozeSubjects : app.snoozeTargets)
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
        .onChange(of: app.snoozeTargets) { _, targets in
            if !targets.isEmpty { snoozeSubjects = targets }
        }
        .task { await app.start() }
    }

    private enum Stage: Equatable {
        /// Accounts are still being read from disk.
        case launching
        case welcome
        case main
    }

    private var stage: Stage {
        if let scene = app.screenshot { return scene == .welcome ? .welcome : .main }
        guard app.isReady else { return .launching }
        return app.store.hasAccounts ? .main : .welcome
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

/// The launch screen's plain background while accounts load. Dots appear only if that takes
/// long enough to notice (a very large mail cache).
private struct LaunchPlaceholder: View {
    @State private var showsDots = false

    var body: some View {
        ZStack {
            if showsDots {
                LoadingDots()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(InkMotion.fade) { showsDots = true }
        }
    }
}
