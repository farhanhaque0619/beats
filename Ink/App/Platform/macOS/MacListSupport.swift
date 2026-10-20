#if os(macOS)
import SwiftUI
import InkCore

/// Per-list values every row needs, computed once per list render instead of once per row.
@MainActor
struct MacRowContext {
    let style: ConversationRowStyle
    let colorIndexByAccount: [String: Int]
    let myAddresses: Set<String>
    let showsSnoozeTime: Bool
    let store: MailStore

    init(store: MailStore, settings: AppSettings) {
        self.store = store
        style = ConversationRowStyle(settings: settings, scope: store.scope, accountCount: store.accounts.count)
        colorIndexByAccount = Dictionary(store.accounts.map { ($0.id, $0.colorIndex) }, uniquingKeysWith: { first, _ in first })
        myAddresses = Set(store.accounts.map { $0.emailAddress.lowercased() })
        showsSnoozeTime = store.scope.role == .snoozed
    }

    func row(_ conversation: Conversation) -> ConversationRow {
        ConversationRow(
            conversation: conversation,
            style: style,
            accountColorIndex: colorIndexByAccount[conversation.accountID] ?? 0,
            myAddresses: myAddresses,
            snoozedUntil: showsSnoozeTime ? store.snoozeDate(for: conversation) : nil
        )
    }
}

/// Right-click menu for one or more conversations in a list.
struct MacConversationMenu: View {
    let app: AppModel
    let ids: Set<String>

    var body: some View {
        let conversations = resolved
        let actions = MacActions(app: app)
        if !conversations.isEmpty {
            if conversations.count == 1, let message = conversations[0].latest {
                Button {
                    app.reply(to: message, mode: .reply)
                } label: {
                    Label(MacCommand.reply.title, systemImage: MacCommand.reply.systemImage)
                }
                Button {
                    app.reply(to: message, mode: .replyAll)
                } label: {
                    Label(MacCommand.replyAll.title, systemImage: MacCommand.replyAll.systemImage)
                }
                Button {
                    app.reply(to: message, mode: .forward)
                } label: {
                    Label(MacCommand.forward.title, systemImage: MacCommand.forward.systemImage)
                }
                Divider()
            }
            Button {
                actions.perform(.archive, on: conversations)
            } label: {
                Label(MacCommand.archive.title, systemImage: MacCommand.archive.systemImage)
            }
            Button {
                actions.perform(.trash, on: conversations)
            } label: {
                Label(MacCommand.trash.title, systemImage: MacCommand.trash.systemImage)
            }
            if app.store.scope.role != .junk {
                Button {
                    actions.perform(.markSpam, on: conversations)
                } label: {
                    Label(MacCommand.spam.title, systemImage: MacCommand.spam.systemImage)
                }
            }
            if app.store.scope.role != .inbox {
                Button {
                    actions.moveToInbox(conversations)
                } label: {
                    Label(actions.title(for: .moveToInbox), systemImage: MacCommand.moveToInbox.systemImage)
                }
            }
            Divider()
            Button {
                actions.perform(.toggleRead, on: conversations)
            } label: {
                let anyUnread = conversations.contains(where: \.isUnread)
                Label(anyUnread ? "Mark as Read" : "Mark as Unread", systemImage: anyUnread ? "envelope.open" : "envelope.badge")
            }
            Button {
                actions.perform(.flag, on: conversations)
            } label: {
                let allStarred = conversations.allSatisfy(\.isFlagged)
                Label(allStarred ? "Unstar" : "Star", systemImage: allStarred ? "star.slash" : "star")
            }
            Button {
                actions.perform(.snooze, on: conversations)
            } label: {
                Label(MacCommand.snooze.title, systemImage: MacCommand.snooze.systemImage)
            }
            moveMenu(conversations)
        }
    }

    private var resolved: [Conversation] {
        let listed = app.store.conversations.filter { ids.contains($0.id) }
        guard listed.count < ids.count else { return listed }
        let listedIDs = Set(listed.map(\.id))
        return listed + ids.subtracting(listedIDs).compactMap { app.store.conversation(id: $0) }
    }

    @ViewBuilder
    private func moveMenu(_ conversations: [Conversation]) -> some View {
        let accountIDs = Set(conversations.map(\.accountID))
        if accountIDs.count == 1, let accountID = accountIDs.first {
            let targets = moveTargets(accountID: accountID)
            if !targets.isEmpty {
                Menu {
                    ForEach(targets) { mailbox in
                        Button {
                            MacActions(app: app).move(conversations, to: mailbox)
                        } label: {
                            Label(Self.menuName(mailbox), systemImage: mailbox.role.systemImage)
                        }
                    }
                } label: {
                    Label("Move to", systemImage: "folder")
                }
            }
        }
    }

    /// Folders a conversation can be filed into: selectable, not virtual, not where it is now.
    private func moveTargets(accountID: String) -> [MailboxInfo] {
        let skippedRoles: Set<MailboxRole> = [.flagged, .snoozed, .drafts, .all]
        let scope = app.store.scope
        var currentPath: String?
        if case .mailbox(_, let path) = scope { currentPath = path }
        let currentRole = scope.role
        return app.store.mailboxes(for: accountID).filter { mailbox in
            mailbox.isSelectable
                && !skippedRoles.contains(mailbox.role)
                && mailbox.path != currentPath
                && (mailbox.role == .custom || mailbox.role != currentRole)
        }
    }

    /// "Projects › Ink" for nested folders, the role title for well-known ones.
    static func menuName(_ mailbox: MailboxInfo) -> String {
        guard mailbox.role == .custom, mailbox.depth > 0, let delimiter = mailbox.delimiter, !delimiter.isEmpty else {
            return mailbox.displayName
        }
        return mailbox.path.components(separatedBy: delimiter).joined(separator: " › ")
    }
}

/// Trackpad swipes on a list row, mapped from the user's swipe settings: the finger moving right
/// reveals the leading actions (long first, so a full swipe runs it), left the trailing ones.
struct MacSwipeActions: ViewModifier {
    let conversation: Conversation
    let swipes: SwipeConfiguration
    let accent: Color
    let perform: (SwipeAction) -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: swipes.rightLong != .none) {
                buttons(Self.ordered(long: swipes.rightLong, short: swipes.rightShort))
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: swipes.leftLong != .none) {
                buttons(Self.ordered(long: swipes.leftLong, short: swipes.leftShort))
            }
    }

    private static func ordered(long: SwipeAction, short: SwipeAction) -> [SwipeAction] {
        var result: [SwipeAction] = []
        for action in [long, short] where action != .none && !result.contains(action) {
            result.append(action)
        }
        return result
    }

    private func buttons(_ actions: [SwipeAction]) -> some View {
        ForEach(actions) { action in
            Button {
                perform(action)
            } label: {
                Label(title(for: action), systemImage: systemImage(for: action))
            }
            .tint(action.tint(accent: accent))
        }
    }

    private func title(for action: SwipeAction) -> String {
        switch action {
        case .toggleRead: return conversation.isUnread ? "Read" : "Unread"
        case .flag: return conversation.isFlagged ? "Unstar" : "Star"
        default: return action.title
        }
    }

    private func systemImage(for action: SwipeAction) -> String {
        switch action {
        case .toggleRead: return conversation.isUnread ? "envelope.open.fill" : "envelope.badge.fill"
        case .flag: return conversation.isFlagged ? "star.slash.fill" : "star.fill"
        default: return action.systemImage
        }
    }
}

extension View {
    /// Adds the configured trackpad swipe actions to a conversation row.
    func macSwipeActions(for conversation: Conversation, swipes: SwipeConfiguration, accent: Color, perform: @escaping (SwipeAction) -> Void) -> some View {
        modifier(MacSwipeActions(conversation: conversation, swipes: swipes, accent: accent, perform: perform))
    }

    /// Archive, Trash, Read/Unread and Snooze buttons on the hovered row, for a mouse that
    /// can't swipe. See `MacRowHoverActions`.
    func macHoverActions(for conversation: Conversation, perform: @escaping (SwipeAction) -> Void) -> some View {
        modifier(MacRowHoverActions(conversation: conversation, perform: perform))
    }
}

/// A small bar of triage buttons that fades in at the row's bottom-trailing corner while the
/// pointer is over it. Hidden from VoiceOver: the same actions are in the context menu, the
/// swipe actions and the keyboard.
struct MacRowHoverActions: ViewModifier {
    let conversation: Conversation
    let perform: (SwipeAction) -> Void

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if isHovering {
                    MacHoverActionBar(isUnread: conversation.isUnread, perform: perform)
                        .padding(.trailing, InkSpace.m)
                        .padding(.bottom, InkSpace.s)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                }
            }
            .onHover { hovering in
                withAnimation(InkMotion.fade) { isHovering = hovering }
            }
            // A row scrolled away under the pointer never hears it leave.
            .onDisappear { isHovering = false }
    }
}

private struct MacHoverActionBar: View {
    let isUnread: Bool
    let perform: (SwipeAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button(.archive, systemImage: "archivebox", help: "Archive (E)")
            button(.trash, systemImage: "trash", help: "Move to Trash (#)")
            button(.toggleRead, systemImage: isUnread ? "envelope.open" : "envelope.badge",
                   help: isUnread ? "Mark as Read (U)" : "Mark as Unread (U)")
            button(.snooze, systemImage: "clock", help: "Snooze (H)")
        }
        .padding(.horizontal, 3)
        .background(Ink.elevated, in: Capsule())
        .overlay(Capsule().stroke(Ink.hairline, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private func button(_ action: SwipeAction, systemImage: String, help: String) -> some View {
        MacHoverActionButton(systemImage: systemImage, tint: action.tint(accent: Ink.primary)) {
            perform(action)
        }
        .help(help)
    }
}

/// One icon in the hover bar; it takes the action's swipe colour under the pointer.
private struct MacHoverActionButton: View {
    let systemImage: String
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? tint : Ink.secondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering in
            withAnimation(InkMotion.fade) { isHovering = hovering }
        }
    }
}
#endif
