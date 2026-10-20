#if os(iOS)
import SwiftUI
import InkCore

/// The iPhone (and iPad) app: the inbox in a navigation stack whose threads zoom out of the row
/// you tapped, a floating compose button, and the mailbox switcher and search presented from
/// `AppModel` flags. Settings, Compose, Snooze and Add Account sheets live in `RootView`.
struct PhoneRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.inkAccent) private var accent

    @Namespace private var zoomNamespace
    /// Set by the mailbox switcher; acted on once its sheet has fully closed.
    @State private var switcherFollowUp: MailboxSwitcherFollowUp?
    /// Zero on phones with a Home button, where the compose button needs more room below it.
    @State private var bottomSafeArea: CGFloat = 34

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.phonePath) {
            InboxScreen(zoomNamespace: zoomNamespace)
                .navigationDestination(for: String.self) { conversationID in
                    ThreadScreen(conversationID: conversationID)
                        .navigationTransition(.zoom(sourceID: conversationID, in: zoomNamespace))
                }
        }
        .background {
            // Measured edge to edge, so the proxy reports the device's bottom inset.
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.safeAreaInsets.bottom
                } action: { inset in
                    bottomSafeArea = inset
                }
        }
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                if app.phonePath.isEmpty {
                    PhoneComposeButton()
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .animation(InkMotion.bouncy, value: app.phonePath.isEmpty)
            .padding(.trailing, InkSpace.gutter)
            .padding(.bottom, bottomSafeArea > 0 ? InkSpace.s : InkSpace.m)
        }
        .sheet(isPresented: $app.isMailboxSwitcherPresented, onDismiss: { runSwitcherFollowUp() }) {
            MailboxSwitcher(onFollowUp: { followUp in switcherFollowUp = followUp })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Ink.surface)
                .presentationCornerRadius(InkRadius.sheet)
                .environment(app)
                .environment(store)
                .environment(settings)
                .environment(\.inkAccent, accent)
                .tint(accent)
        }
        .fullScreenCover(isPresented: $app.isSearchPresented) {
            SearchScreen()
                .environment(app)
                .environment(store)
                .environment(settings)
                .environment(\.inkAccent, accent)
                .tint(accent)
        }
    }

    /// Opens the sheet the switcher asked for, now that it is out of the way.
    private func runSwitcherFollowUp() {
        guard let followUp = switcherFollowUp else { return }
        switcherFollowUp = nil
        switch followUp {
        case .addAccount: app.isAddAccountPresented = true
        case .settings: app.isSettingsPresented = true
        }
    }
}

/// The floating accent circle that starts a new message. Shrinks under the finger with a light
/// tap of haptics, and springs back.
private struct PhoneComposeButton: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(\.inkAccent) private var accent

    var body: some View {
        Button {
            app.compose()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(settings.accent.onColor)
                .offset(x: 1, y: -1)
                .frame(width: InkSize.fab, height: InkSize.fab)
                .background(accent, in: Circle())
                .shadow(color: accent.opacity(0.32), radius: 14, y: 6)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(PhoneComposeButtonStyle())
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityLabel("New message")
    }
}

private struct PhoneComposeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(InkMotion.bouncy, value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, isPressed in
                isPressed
            }
    }
}
#endif
