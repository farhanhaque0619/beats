#if os(macOS)
import SwiftUI
import InkCore

/// The Mac menu bar: File › New Message, View › Command Palette and Search, a Mailbox menu
/// (Get New Mail, ⌘1…⌘9) and a Message menu acting on the selection. Shortcuts follow Mail.
/// Single-letter shortcuts are not here: they live on the focused pane (`MacKeyboardShortcuts`)
/// so they never fire while typing.
struct InkCommands: Commands {
    let app: AppModel

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .newItem) {
            MacMenuButton(app: app, command: .compose)
        }

        CommandGroup(before: .toolbar) {
            MacMenuButton(app: app, command: .commandPalette)
            MacMenuButton(app: app, command: .search)
            Divider()
        }

        CommandMenu("Mailbox") {
            MacMenuButton(app: app, command: .refresh)
            Divider()
            MacMailboxMenuItems(app: app)
            Divider()
            MacMenuButton(app: app, command: .addAccount)
        }

        CommandMenu("Message") {
            MacMenuButton(app: app, command: .reply)
            MacMenuButton(app: app, command: .replyAll)
            MacMenuButton(app: app, command: .forward)
            Divider()
            MacMenuButton(app: app, command: .archive)
            MacMenuButton(app: app, command: .trash)
            MacMenuButton(app: app, command: .spam)
            MacMenuButton(app: app, command: .moveToInbox)
            Divider()
            MacMenuButton(app: app, command: .toggleRead)
            MacMenuButton(app: app, command: .toggleStar)
            MacMenuButton(app: app, command: .snooze)
            Divider()
            MacMenuButton(app: app, command: .nextConversation)
            MacMenuButton(app: app, command: .previousConversation)
        }
    }
}

/// A menu item for a `MacCommand`. A view (not a plain Button in `Commands`) so its title and
/// enabled state track the selection through Observation.
struct MacMenuButton: View {
    let app: AppModel
    let command: MacCommand

    var body: some View {
        let actions = MacActions(app: app)
        Button {
            // ⌘⌫ means "delete to line start" while typing in a field; don't trash mail then.
            if command == .trash && MacTextInput.isEditing {
                MacTextInput.deleteToBeginningOfLine()
            } else {
                actions.run(command)
            }
        } label: {
            Text(actions.title(for: command))
        }
        .keyboardShortcut(command.menuShortcut)
        .disabled(!actions.isEnabledInMenu(command))
    }
}

/// Mailbox › the first nine sidebar places, on ⌘1…⌘9.
struct MacMailboxMenuItems: View {
    let app: AppModel

    var body: some View {
        let items = Array(MacSidebarCatalog.all(store: app.store).filter(\.isSelectable).prefix(9))
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            Button {
                app.select(scope: item.scope)
            } label: {
                Text(item.qualifiedTitle)
            }
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            .disabled(app.composeDraft != nil || app.isCommandPalettePresented)
        }
    }
}
#endif
