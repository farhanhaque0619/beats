#if os(macOS)
import SwiftUI
import InkCore

/// The right column: the open thread, the bulk panel for several conversations, or a calm empty
/// state. An open thread brings its own toolbar (`ThreadScreen`); otherwise this column shows
/// the same buttons acting on the selection, so the toolbar keeps its shape.
struct MacDetailColumn: View {
    var focus: FocusState<MacPane?>.Binding

    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.inkAccent) private var accent

    @State private var isSnoozePopoverPresented = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ink.background)
            .animation(InkMotion.smooth, value: app.focusedConversationID)
            .animation(InkMotion.smooth, value: app.selection.count > 1)
            .focusable(interactions: .edit)
            .focusEffectDisabled()
            .focused(focus, equals: .detail)
            .macKeyboardShortcuts(app: app, handlesArrowKeys: true)
            .toolbar { messageToolbar }
            .onChange(of: app.snoozeTargets.isEmpty) { _, isEmpty in
                if isEmpty { isSnoozePopoverPresented = false }
            }
            .onChange(of: isSnoozePopoverPresented) { _, presented in
                // Closed by clicking outside: forget the targets (unless the sheet took over).
                if !presented && !app.isSnoozePickerPresented { app.snoozeTargets = [] }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let id = app.focusedConversationID {
            ThreadScreen(conversationID: id)
                .id(id)
                .transition(.opacity)
        } else if app.selection.count > 1 {
            MacBulkSelectionPanel(conversations: MacActions(app: app).selected)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            MacEmptyDetail()
                .transition(.opacity)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var messageToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if app.focusedConversationID == nil {
                toolbarButton(.archive, help: "Archive (E)")
                toolbarButton(.trash, help: "Move to Trash (#)")
                snoozeButton
                starButton
                replyMenu
            }
        }
    }

    private func toolbarButton(_ command: MacCommand, help: String) -> some View {
        let actions = MacActions(app: app)
        return Button {
            actions.run(command)
        } label: {
            Label(command.title, systemImage: command.systemImage)
        }
        .help(help)
        .disabled(!actions.isEnabledInMenu(command))
    }

    private var snoozeButton: some View {
        let actions = MacActions(app: app)
        return Button {
            let targets = actions.selected
            guard !targets.isEmpty else { return }
            app.snoozeTargets = targets
            isSnoozePopoverPresented = true
        } label: {
            Label("Snooze", systemImage: MacCommand.snooze.systemImage)
        }
        .help("Snooze (H)")
        .disabled(!actions.isEnabledInMenu(.snooze))
        .popover(isPresented: $isSnoozePopoverPresented) {
            SnoozePicker(conversations: app.snoozeTargets)
                .environment(app)
                .environment(store)
                .environment(settings)
                .environment(\.inkAccent, accent)
                .tint(accent)
        }
    }

    private var starButton: some View {
        let actions = MacActions(app: app)
        return Button {
            actions.run(.toggleStar)
        } label: {
            Label(actions.title(for: .toggleStar), systemImage: actions.systemImage(for: .toggleStar))
        }
        .help("Star (S)")
        .disabled(!actions.isEnabledInMenu(.toggleStar))
    }

    private var replyMenu: some View {
        let actions = MacActions(app: app)
        return Menu {
            Button {
                actions.run(.replyAll)
            } label: {
                Label(MacCommand.replyAll.title, systemImage: MacCommand.replyAll.systemImage)
            }
            Button {
                actions.run(.forward)
            } label: {
                Label(MacCommand.forward.title, systemImage: MacCommand.forward.systemImage)
            }
        } label: {
            Label(MacCommand.reply.title, systemImage: MacCommand.reply.systemImage)
        } primaryAction: {
            actions.run(.reply)
        }
        .help("Reply (R) · Reply All (A) · Forward (F)")
        .disabled(!actions.isEnabledInMenu(.reply))
    }
}

/// Nothing selected: the Ink mark and a hint of the keyboard.
private struct MacEmptyDetail: View {
    @Environment(MailStore.self) private var store
    @State private var appeared = false

    var body: some View {
        VStack(spacing: InkSpace.xl) {
            MacInkMark(dropped: appeared)
            VStack(spacing: InkSpace.s) {
                Text(store.conversations.isEmpty ? "All quiet" : "No conversation selected")
                    .font(InkFont.headline)
                    .foregroundStyle(Ink.secondary)
                HStack(spacing: InkSpace.xs) {
                    KeyCap("J")
                    KeyCap("K")
                    Text("to move")
                    Text(verbatim: "·").padding(.horizontal, InkSpace.xxs)
                    KeyCap("⌘K")
                    Text("for everything")
                }
                .font(InkFont.caption)
                .foregroundStyle(Ink.tertiary)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(InkMotion.bouncy.delay(0.05)) { appeared = true }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "ink" set in heavy type, the dot of the i in the accent: it drops in with a bounce.
private struct MacInkMark: View {
    var dropped: Bool
    @Environment(\.inkAccent) private var accent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: "\u{131}")
                .overlay(alignment: .top) {
                    Circle()
                        .fill(accent)
                        .frame(width: 11, height: 11)
                        .offset(y: dropped ? 12 : -18)
                        .opacity(dropped ? 1 : 0)
                }
            Text(verbatim: "nk")
        }
        .font(.system(size: 64, weight: .bold, design: .default))
        .tracking(-1.5)
        .foregroundStyle(Ink.primary.opacity(0.12))
        .accessibilityHidden(true)
    }
}
#endif
