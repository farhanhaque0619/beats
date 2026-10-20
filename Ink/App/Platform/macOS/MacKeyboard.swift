#if os(macOS)
import SwiftUI
import InkCore

/// Gmail-style single-key shortcuts for the focused list or reader: j/k move, e archives,
/// # or ⌫ trashes, r/a/f reply, c composes, / searches, s stars, u toggles read, h snoozes,
/// ! marks spam, Esc clears the selection.
///
/// Uses `.onKeyPress`, so keys only arrive while this pane (or something inside it) has focus,
/// and they step aside while a text field is being edited, a sheet is up or the palette is open.
/// Keys with ⌘, ⌃ or ⌥ are left to the menu bar.
struct MacKeyboardShortcuts: ViewModifier {
    let app: AppModel
    /// Conversation IDs in display order, for j/k (search results); nil means the mailbox list.
    var order: [String]?
    /// The reader moves between conversations with ↑/↓ too; the list leaves arrows to `List`,
    /// which already moves (and extends) the selection with them.
    var handlesArrowKeys: Bool

    func body(content: Content) -> some View {
        content.onKeyPress(phases: [.down, .repeat]) { press in
            handle(press)
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let actions = MacActions(app: app)
        guard !actions.isModalPresented, !app.isCommandPalettePresented, !MacTextInput.isEditing else {
            return .ignored
        }
        guard let command = command(for: press) else { return .ignored }
        if press.phase == .repeat && !command.repeats { return .handled }
        guard actions.isAvailable(command) else {
            // Let Esc and ⌫ fall through to the system; swallow letters so nothing beeps.
            return isLetterShortcut(press) ? .handled : .ignored
        }
        actions.run(command, order: order)
        return .handled
    }

    private func command(for press: KeyPress) -> MacCommand? {
        if press.key == .escape { return .clearSelection }
        if press.key == .delete || press.key == .deleteForward { return .trash }
        if handlesArrowKeys {
            if press.key == .downArrow { return .nextConversation }
            if press.key == .upArrow { return .previousConversation }
        }
        switch normalizedCharacters(press) {
        case "j": return .nextConversation
        case "k": return .previousConversation
        case "e": return .archive
        case "#": return .trash
        case "r": return .reply
        case "a": return .replyAll
        case "f": return .forward
        case "c": return .compose
        case "/": return .search
        case "s": return .toggleStar
        case "u": return .toggleRead
        case "h": return .snooze
        case "!": return .spam
        default: return nil
        }
    }

    /// Lowercases letters typed with Caps Lock on; shifted symbols (#, !) stay as typed.
    private func normalizedCharacters(_ press: KeyPress) -> String {
        press.modifiers.contains(.shift) ? press.characters : press.characters.lowercased()
    }

    private func isLetterShortcut(_ press: KeyPress) -> Bool {
        press.key != .escape && press.key != .delete && press.key != .deleteForward
    }
}

extension View {
    /// Single-key mail shortcuts for a focusable pane. See `MacKeyboardShortcuts`.
    func macKeyboardShortcuts(app: AppModel, order: [String]? = nil, handlesArrowKeys: Bool) -> some View {
        modifier(MacKeyboardShortcuts(app: app, order: order, handlesArrowKeys: handlesArrowKeys))
    }
}
#endif
