#if os(macOS)
import SwiftUI
import InkCore

/// Gmail-style single-key shortcuts for the focused pane: j/k move, e archives, # or ⌫ trashes,
/// r/a/f reply, c composes, / searches, s stars, u toggles read, h snoozes, ! marks spam,
/// z undoes, Esc clears the selection.
///
/// Uses `.onKeyPress`, so keys only arrive while this pane (or something inside it) has focus,
/// and they step aside while a text field is being edited, a sheet is up or the palette is open.
/// Keys with ⌘, ⌃ or ⌥ are left to the menu bar.
struct MacKeyboardShortcuts: ViewModifier {
    let app: AppModel
    /// Which pane this is. The reader also moves between conversations with ↑/↓; the list and
    /// the sidebar leave arrows to their `List` (which moves, and extends, its own selection),
    /// and the sidebar leaves ⌫ alone so it never trashes mail by surprise.
    var pane: MacPane
    /// Called after j/k moved the selection, so the sidebar can hand the keyboard to the list.
    var didNavigate: (() -> Void)?
    /// Esc with nothing selected (search results use it to end the search).
    var escapeWithoutSelection: (() -> Void)?

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
            if command == .clearSelection, let escapeWithoutSelection {
                escapeWithoutSelection()
                return .handled
            }
            // Let Esc and ⌫ fall through to the system; swallow letters so nothing beeps.
            return isLetterShortcut(press) ? .handled : .ignored
        }
        actions.run(command)
        if command == .nextConversation || command == .previousConversation {
            didNavigate?()
        }
        return .handled
    }

    private func command(for press: KeyPress) -> MacCommand? {
        if press.key == .escape { return .clearSelection }
        if press.key == .delete || press.key == .deleteForward {
            return pane == .sidebar ? nil : .trash
        }
        if pane == .detail {
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
        case "z": return .undo
        default: return nil
        }
    }

    /// Lowercases letters typed with Caps Lock on; shifted symbols (#, !) stay as typed.
    private func normalizedCharacters(_ press: KeyPress) -> String {
        press.modifiers.contains(.shift) ? press.characters : press.characters.lowercased()
    }

    private func isLetterShortcut(_ press: KeyPress) -> Bool {
        press.key != .escape && press.key != .delete && press.key != .deleteForward
            && press.key != .upArrow && press.key != .downArrow
    }
}

extension View {
    /// Single-key mail shortcuts for a focusable pane. See `MacKeyboardShortcuts`.
    func macKeyboardShortcuts(app: AppModel, pane: MacPane, didNavigate: (() -> Void)? = nil,
                              escapeWithoutSelection: (() -> Void)? = nil) -> some View {
        modifier(MacKeyboardShortcuts(app: app, pane: pane, didNavigate: didNavigate, escapeWithoutSelection: escapeWithoutSelection))
    }
}
#endif
