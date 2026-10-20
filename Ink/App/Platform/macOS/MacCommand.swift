#if os(macOS)
import SwiftUI
import AppKit
import InkCore

/// The panes of the Mac window that take keyboard focus.
enum MacPane: Hashable {
    case list
    case detail
}

/// Everything the Mac window can do from the menu bar, the toolbar, single-key shortcuts and the
/// command palette. One list, so every surface offers the same verbs with the same names.
enum MacCommand: String, CaseIterable, Identifiable {
    case compose, reply, replyAll, forward
    case archive, trash, snooze, toggleRead, toggleStar, spam, moveToInbox
    case nextConversation, previousConversation, clearSelection
    case refresh, search, commandPalette, addAccount

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
        case .moveToInbox, .nextConversation, .previousConversation, .clearSelection, .addAccount: return nil
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
        }
    }

    /// Navigation keys may auto-repeat; actions that change mail never do.
    var repeats: Bool {
        self == .nextConversation || self == .previousConversation
    }

    /// Commands the palette lists, in order of usefulness.
    static let paletteCommands: [MacCommand] = [
        .compose, .reply, .replyAll, .forward, .archive, .trash, .snooze, .toggleRead, .toggleStar,
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
        case .archive, .trash, .snooze, .toggleRead, .toggleStar, .spam, .clearSelection:
            return !app.selection.isEmpty
        case .moveToInbox:
            return !app.selection.isEmpty && store.scope.role != .inbox
        case .nextConversation, .previousConversation:
            return !store.conversations.isEmpty
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
            step(1, order: order ?? store.conversations.map(\.id))
        case .previousConversation:
            step(-1, order: order ?? store.conversations.map(\.id))
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
        }
    }

    /// Swipe/menu actions on specific conversations, animated and with a haptic.
    func perform(_ action: SwipeAction, on conversations: [Conversation]) {
        guard action != .none, !conversations.isEmpty else { return }
        if action == .snooze {
            app.perform(.snooze, on: conversations)
            return
        }
        if action.removesFromList { Haptics.success() } else { Haptics.tick() }
        withAnimation(InkMotion.rowRemoval) {
            app.perform(action, on: conversations)
        }
    }

    func moveToInbox(_ conversations: [Conversation]) {
        guard !conversations.isEmpty else { return }
        Haptics.success()
        if store.scope.role != .inbox { advanceSelection(past: conversations) }
        withAnimation(InkMotion.rowRemoval) {
            store.moveToInbox(conversations)
        }
    }

    func move(_ conversations: [Conversation], to mailbox: MailboxInfo) {
        guard !conversations.isEmpty else { return }
        Haptics.success()
        advanceSelection(past: conversations)
        withAnimation(InkMotion.rowRemoval) {
            store.move(conversations, to: mailbox)
        }
    }

    // MARK: Private

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
