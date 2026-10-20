#if os(macOS)
import SwiftUI
import AppKit
import InkCore

/// The panes of the Mac window that take keyboard focus.
enum MacPane: Hashable {
    case sidebar
    case list
    case detail
}

/// Everything the Mac window can do from the menu bar, the toolbar, single-key shortcuts and the
/// command palette. One list, so every surface offers the same verbs with the same names.
enum MacCommand: String, CaseIterable, Identifiable {
    case compose, reply, replyAll, forward
    case archive, trash, snooze, toggleRead, toggleStar, spam, moveToInbox
    case nextConversation, previousConversation, clearSelection
    case refresh, search, commandPalette, addAccount, undo

    var id: String { rawValue }

    /// Menu-style title. Read/star titles depend on the selection: use `MacActions.title(for:)`.
    var title: String {
        switch self {
        case .compose: return "New Message"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        case .archive: return "Archive"
        case .trash: return "Move to Trash"
        case .snooze: return "Snooze…"
        case .toggleRead: return "Mark as Unread"
        case .toggleStar: return "Star"
        case .spam: return "Mark as Spam"
        case .moveToInbox: return "Move to Inbox"
        case .nextConversation: return "Next Conversation"
        case .previousConversation: return "Previous Conversation"
        case .clearSelection: return "Clear Selection"
        case .refresh: return "Get New Mail"
        case .search: return "Search Mail"
        case .commandPalette: return "Command Palette"
        case .addAccount: return "Add Account…"
        case .undo: return "Undo"
        }
    }

    var systemImage: String {
        switch self {
        case .compose: return "square.and.pencil"
        case .reply: return "arrowshape.turn.up.left"
        case .replyAll: return "arrowshape.turn.up.left.2"
        case .forward: return "arrowshape.turn.up.right"
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .snooze: return "clock"
        case .toggleRead: return "envelope.badge"
        case .toggleStar: return "star"
        case .spam: return "xmark.octagon"
        case .moveToInbox: return "tray.and.arrow.down"
        case .nextConversation: return "chevron.down"
        case .previousConversation: return "chevron.up"
        case .clearSelection: return "xmark"
        case .refresh: return "arrow.clockwise"
        case .search: return "magnifyingglass"
        case .commandPalette: return "command"
        case .addAccount: return "person.crop.circle.badge.plus"
        case .undo: return "arrow.uturn.backward"
        }
    }

    /// Menu bar key equivalent. Mail-like, and never a bare letter: single keys are handled
    /// with `.onKeyPress` so they can't fire while typing.
    var menuShortcut: KeyboardShortcut? {
        switch self {
        case .compose: return KeyboardShortcut("n", modifiers: .command)
        case .reply: return KeyboardShortcut("r", modifiers: .command)
        case .replyAll: return KeyboardShortcut("r", modifiers: [.command, .shift])
        case .forward: return KeyboardShortcut("f", modifiers: [.command, .shift])
        case .archive: return KeyboardShortcut("a", modifiers: [.command, .control])
        case .trash: return KeyboardShortcut(.delete, modifiers: .command)
        // ⌃⌘S belongs to Show/Hide Sidebar, so snooze takes its single-key letter.
        case .snooze: return KeyboardShortcut("h", modifiers: [.command, .control])
        case .toggleRead: return KeyboardShortcut("u", modifiers: [.command, .shift])
        case .toggleStar: return KeyboardShortcut("l", modifiers: [.command, .shift])
        case .spam: return KeyboardShortcut("j", modifiers: [.command, .shift])
        case .refresh: return KeyboardShortcut("n", modifiers: [.command, .shift])
        case .search: return KeyboardShortcut("f", modifiers: [.command, .option])
        case .commandPalette: return KeyboardShortcut("k", modifiers: .command)
        // Undo rides on Edit › Undo (⌘Z) through the window's undo manager: `MacUndoBridge`.
        case .moveToInbox, .nextConversation, .previousConversation, .clearSelection, .addAccount, .undo: return nil
        }
    }

    /// The hint shown beside the command in the palette: its single key when it has one.
    var paletteHint: String? {
        switch self {
        case .compose: return "C"
        case .reply: return "R"
        case .replyAll: return "A"
        case .forward: return "F"
        case .archive: return "E"
        case .trash: return "#"
        case .snooze: return "H"
        case .toggleRead: return "U"
        case .toggleStar: return "S"
        case .spam: return "!"
        case .nextConversation: return "J"
        case .previousConversation: return "K"
        case .clearSelection: return "esc"
        case .refresh: return "⇧⌘N"
        case .search: return "/"
        case .commandPalette: return "⌘K"
        case .undo: return "Z"
        case .moveToInbox, .addAccount: return nil
        }
    }

    /// Extra words the palette matches on.
    var keywords: String {
        switch self {
        case .compose: return "write new email mail draft"
        case .reply: return "respond answer"
        case .replyAll: return "respond everyone"
        case .forward: return "send on share"
        case .archive: return "done remove"
        case .trash: return "delete bin remove"
        case .snooze: return "later remind remind me"
        case .toggleRead: return "read unread seen"
        case .toggleStar: return "flag important favourite favorite"
        case .spam: return "junk"
        case .moveToInbox: return "unarchive restore not spam"
        case .nextConversation: return "down"
        case .previousConversation: return "up"
        case .clearSelection: return "deselect"
        case .refresh: return "sync fetch check get mail reload"
        case .search: return "find look"
        case .commandPalette: return "commands"
        case .addAccount: return "connect sign in gmail icloud outlook"
        case .undo: return "revert back oops restore"
        }
    }

    /// Navigation keys may auto-repeat; actions that change mail never do.
    var repeats: Bool {
        self == .nextConversation || self == .previousConversation
    }

    /// Commands the palette lists, in order of usefulness.
    static let paletteCommands: [MacCommand] = [
        .undo, .compose, .reply, .replyAll, .forward, .archive, .trash, .snooze, .toggleRead, .toggleStar,
        .spam, .moveToInbox, .refresh, .search, .addAccount,
    ]
}

/// Runs `MacCommand`s against the current selection. A value type over `AppModel` so menus,
/// toolbar, keyboard and palette all share one implementation.
@MainActor
struct MacActions {
    let app: AppModel

    private var store: MailStore { app.store }

    /// The selected conversations, in list order (search results not in the list come last).
    var selected: [Conversation] {
        let ids = app.selection
        guard !ids.isEmpty else { return [] }
        let listed = store.conversations.filter { ids.contains($0.id) }
        guard listed.count < ids.count else { return listed }
        let listedIDs = Set(listed.map(\.id))
        let others = ids.subtracting(listedIDs)
            .compactMap { store.conversation(id: $0) }
            .sorted { $0.date > $1.date }
        return listed + others
    }

    /// The single conversation shown in the reader.
    var focused: Conversation? {
        app.focusedConversationID.flatMap { store.conversation(id: $0) }
    }

    /// A sheet is up (compose, add account, snooze), so window commands step aside.
    var isModalPresented: Bool {
        app.composeDraft != nil || app.isAddAccountPresented || app.isSnoozePickerPresented
    }

    /// Whether the command makes sense for the current selection and scope.
    func isAvailable(_ command: MacCommand) -> Bool {
        switch command {
        case .compose, .refresh, .search, .commandPalette:
            return store.hasAccounts
        case .addAccount:
            return true
        case .reply, .replyAll, .forward:
            return focused?.latest != nil
        case .archive, .trash, .snooze, .toggleRead, .toggleStar, .clearSelection:
            return !app.selection.isEmpty
        case .spam:
            // Already there: Spam offers "Not Spam" (Move to Inbox) instead.
            return !app.selection.isEmpty && store.scope.role != .junk
        case .moveToInbox:
            return !app.selection.isEmpty && store.scope.role != .inbox
        case .nextConversation, .previousConversation:
            if let searchOrder = MacVisibleList.searchOrder { return !searchOrder.isEmpty }
            return !store.conversations.isEmpty
        case .undo:
            return store.toast?.undoable == true
        }
    }

    /// Menu items are also off while a sheet or the palette has the keyboard.
    func isEnabledInMenu(_ command: MacCommand) -> Bool {
        guard !isModalPresented else { return false }
        if command == .commandPalette { return isAvailable(command) }
        guard !app.isCommandPalettePresented else { return false }
        return isAvailable(command)
    }

    /// Title reflecting the selection ("Mark as Read" when anything selected is unread).
    func title(for command: MacCommand) -> String {
        switch command {
        case .moveToInbox:
            return store.scope.role == .junk ? "Not Spam" : command.title
        case .toggleRead:
            return selected.contains(where: \.isUnread) ? "Mark as Read" : "Mark as Unread"
        case .toggleStar:
            let conversations = selected
            return !conversations.isEmpty && conversations.allSatisfy(\.isFlagged) ? "Unstar" : "Star"
        default:
            return command.title
        }
    }

    /// Symbol reflecting the selection (filled star when everything is starred).
    func systemImage(for command: MacCommand) -> String {
        switch command {
        case .toggleRead:
            return selected.contains(where: \.isUnread) ? "envelope.open" : "envelope.badge"
        case .toggleStar:
            let conversations = selected
            return !conversations.isEmpty && conversations.allSatisfy(\.isFlagged) ? "star.slash" : "star"
        default:
            return command.systemImage
        }
    }

    /// Runs the command. `order` is the visible list order for next/previous (search results);
    /// it defaults to the mailbox list.
    func run(_ command: MacCommand, order: [String]? = nil) {
        switch command {
        case .compose:
            app.compose()
        case .reply:
            reply(.reply)
        case .replyAll:
            reply(.replyAll)
        case .forward:
            reply(.forward)
        case .archive:
            perform(.archive, on: selected)
        case .trash:
            perform(.trash, on: selected)
        case .snooze:
            app.perform(.snooze, on: selected)
        case .toggleRead:
            perform(.toggleRead, on: selected)
        case .toggleStar:
            perform(.flag, on: selected)
        case .spam:
            perform(.markSpam, on: selected)
        case .moveToInbox:
            moveToInbox(selected)
        case .nextConversation:
            step(1, order: order ?? visibleOrder)
        case .previousConversation:
            step(-1, order: order ?? visibleOrder)
        case .clearSelection:
            app.selection = []
        case .refresh:
            let mailStore = app.store
            Task { await mailStore.refresh() }
        case .search:
            app.isSearchPresented = true
        case .commandPalette:
            app.isCommandPalettePresented.toggle()
        case .addAccount:
            app.isAddAccountPresented = true
        case .undo:
            undo()
        }
    }

    /// Undoes the last triage action while its toast still offers Undo, and puts the selection
    /// back on the conversations it took away.
    func undo() {
        guard store.toast?.undoable == true else { return }
        let toastID = store.toast?.id
        Haptics.tick()
        withAnimation(InkMotion.rowRemoval) {
            store.undo()
        }
        restoreSelection(afterUndoOf: toastID)
    }

    /// After an undo (from here, the toast's button or ⌘Z): selects again what the undone
    /// removal took away, once it's back. A toast that was only dismissed restores nothing,
    /// since its conversations are still gone.
    func restoreSelection(afterUndoOf toastID: UUID?) {
        guard let memory = MacVisibleList.selectionBeforeRemoval, memory.toastID == toastID else { return }
        MacVisibleList.selectionBeforeRemoval = nil
        let listed = Set(store.conversations.map(\.id))
        let searching = MacVisibleList.searchOrder != nil
        let back = memory.selection.filter { id in
            listed.contains(id) || (searching && store.conversation(id: id) != nil)
        }
        guard !back.isEmpty else { return }
        app.selection = back
    }

    /// Swipe/menu actions on specific conversations, animated and with a haptic.
    func perform(_ action: SwipeAction, on conversations: [Conversation]) {
        guard action != .none, !conversations.isEmpty else { return }
        if action == .snooze {
            app.perform(.snooze, on: conversations)
            return
        }
        guard action.removesFromList else {
            Haptics.tick()
            withAnimation(InkMotion.rowRemoval) {
                app.perform(action, on: conversations)
            }
            return
        }
        Haptics.success()
        let before = app.selection
        let searchNeighbour = neighbourInSearch(past: conversations)
        withAnimation(InkMotion.rowRemoval) {
            app.perform(action, on: conversations)
            // AppModel steps along the mailbox; while searching, stay within the results.
            if let searchNeighbour { app.selection = searchNeighbour }
        }
        rememberSelection(before, removing: conversations)
    }

    func moveToInbox(_ conversations: [Conversation]) {
        guard !conversations.isEmpty else { return }
        Haptics.success()
        let before = app.selection
        withAnimation(InkMotion.rowRemoval) {
            if store.scope.role != .inbox { advanceSelection(past: conversations) }
            store.moveToInbox(conversations)
        }
        rememberSelection(before, removing: conversations)
    }

    func move(_ conversations: [Conversation], to mailbox: MailboxInfo) {
        guard !conversations.isEmpty else { return }
        Haptics.success()
        let before = app.selection
        withAnimation(InkMotion.rowRemoval) {
            advanceSelection(past: conversations)
            store.move(conversations, to: mailbox)
        }
        rememberSelection(before, removing: conversations)
    }

    // MARK: Private

    /// What j/k walk: the search results while they're shown, otherwise the mailbox.
    private var visibleOrder: [String] {
        MacVisibleList.searchOrder ?? store.conversations.map(\.id)
    }

    private func reply(_ mode: ReplyMode) {
        guard let message = focused?.latest else { return }
        app.reply(to: message, mode: mode)
    }

    /// Moves the selection one row along `order`, from the last (or first) selected row.
    private func step(_ offset: Int, order: [String]) {
        guard !order.isEmpty else { return }
        let selectedIndices = order.indices.filter { app.selection.contains(order[$0]) }
        let target: Int
        if let anchor = offset > 0 ? selectedIndices.last : selectedIndices.first {
            target = anchor + offset
        } else {
            target = offset > 0 ? 0 : order.count - 1
        }
        guard order.indices.contains(target) else { return }
        app.selection = [order[target]]
    }

    /// Keeps the selection on a neighbour when selected conversations leave the list.
    private func advanceSelection(past removed: [Conversation]) {
        if let searchNeighbour = neighbourInSearch(past: removed) {
            app.selection = searchNeighbour
            return
        }
        let ids = Set(removed.map(\.id))
        guard !app.selection.isDisjoint(with: ids) else { return }
        let list = store.conversations
        guard let lastIndex = list.lastIndex(where: { ids.contains($0.id) }) else {
            app.selection.subtract(ids)
            return
        }
        let after = list[(lastIndex + 1)...].first { !ids.contains($0.id) }
        let before = list[..<lastIndex].last { !ids.contains($0.id) }
        app.selection = (after ?? before).map { [$0.id] } ?? []
    }

    /// While search results are shown: the result to select once `removed` are dealt with, or
    /// nil when not searching or the selection isn't affected.
    private func neighbourInSearch(past removed: [Conversation]) -> Set<String>? {
        guard let order = MacVisibleList.searchOrder else { return nil }
        let ids = Set(removed.map(\.id))
        guard !app.selection.isDisjoint(with: ids) else { return nil }
        guard let lastIndex = order.lastIndex(where: { ids.contains($0) }) else { return Set<String>() }
        let after = order[(lastIndex + 1)...].first { !ids.contains($0) }
        let before = order[..<lastIndex].last { !ids.contains($0) }
        guard let neighbour = after ?? before else { return Set<String>() }
        return Set([neighbour])
    }

    /// Remembers what was selected before an undoable removal, so Undo can put it back.
    private func rememberSelection(_ selection: Set<String>, removing removed: [Conversation]) {
        let ids = Set(removed.map(\.id))
        guard store.toast?.undoable == true, !selection.isDisjoint(with: ids) else {
            MacVisibleList.selectionBeforeRemoval = nil
            return
        }
        MacVisibleList.selectionBeforeRemoval = (store.toast?.id, selection)
    }
}

/// Window-wide facts about what the list column shows, for commands that run from anywhere
/// (menu bar, reader, palette). Ink has one main window, so plain statics are enough; nothing
/// here drives rendering.
@MainActor
enum MacVisibleList {
    /// Conversation IDs of the search results in display order while search replaces the
    /// mailbox list; nil otherwise.
    static var searchOrder: [String]?
    /// The selection before the last undoable removal, and the toast that offers its Undo.
    static var selectionBeforeRemoval: (toastID: UUID?, selection: Set<String>)?
}

/// AppKit facts SwiftUI doesn't expose.
@MainActor
enum MacTextInput {
    /// True while the user is typing in a text field or text view of the key window (the field
    /// editor is an `NSText`). Single-key shortcuts and ⌘⌫ step aside then.
    static var isEditing: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    /// What ⌘⌫ means in a text field: delete to the start of the line.
    static func deleteToBeginningOfLine() {
        _ = NSApp.sendAction(NSSelectorFromString("deleteToBeginningOfLine:"), to: nil, from: nil)
    }
}
#endif
