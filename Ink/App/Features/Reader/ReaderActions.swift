import SwiftUI
import InkCore

/// What the reader can do to the open conversation. Shared by the iPhone bottom capsule, the
/// navigation bar menu and the Mac toolbar so every surface behaves the same.
@MainActor
struct ReaderActions {
    let conversation: Conversation
    let app: AppModel
    let store: MailStore
    /// Called right before the conversation leaves the store, so the screen can keep drawing
    /// it while it goes away.
    let willLeave: () -> Void
    /// Called right before the snooze picker opens for this conversation.
    let willSnooze: () -> Void

    var isFlagged: Bool { conversation.isFlagged }
    var snoozedUntil: Date? { store.snoozeDate(for: conversation) }

    var isInInbox: Bool {
        let inboxPath = path(for: .inbox) ?? "INBOX"
        return conversation.messages.contains { message in
            message.mailboxPath.caseInsensitiveCompare(inboxPath) == .orderedSame
                || message.gmailLabels.contains { $0.caseInsensitiveCompare("\\Inbox") == .orderedSame }
        }
    }

    var isInJunk: Bool {
        guard let junkPath = path(for: .junk), let latest = conversation.latest else { return false }
        return latest.mailboxPath == junkPath
    }

    /// Folders the conversation can move to: selectable, not where it already is, and not the
    /// virtual ones (Starred, Snoozed, All Mail) or Drafts.
    var moveTargets: [MailboxInfo] {
        let current = Set(conversation.messages.map(\.mailboxPath))
        let excluded: Set<MailboxRole> = [.flagged, .snoozed, .drafts, .all]
        return store.mailboxes(for: conversation.accountID).filter { mailbox in
            mailbox.isSelectable && !excluded.contains(mailbox.role) && !current.contains(mailbox.path)
        }
    }

    // MARK: Triage

    func archive() { remove(.archive) }
    func trash() { remove(.trash) }
    func markSpam() { remove(.markSpam) }

    func snooze() {
        Haptics.tick()
        willSnooze()
        app.perform(.snooze, on: [conversation])
    }

    func toggleStar() {
        Haptics.tick()
        store.toggleFlag([conversation])
    }

    /// Marks it unread and goes back to the list on iPhone, so it isn't read again on the way out.
    func markUnread() {
        Haptics.tick()
        store.setRead(false, [conversation])
        #if os(iOS)
        if app.phonePath.last == conversation.id {
            app.phonePath.removeLast()
        }
        #endif
    }

    func moveToInbox() {
        relocate { store.moveToInbox([conversation]) }
    }

    func unsnooze() {
        relocate { store.unsnooze([conversation]) }
    }

    func move(to mailbox: MailboxInfo) {
        relocate { store.move([conversation], to: mailbox) }
    }

    // MARK: Writing

    /// Replies to the newest message (a reply to your own message goes to its recipients).
    func reply(_ mode: ReplyMode) {
        guard let message = conversation.latest else { return }
        Haptics.tick()
        app.reply(to: message, mode: mode)
    }

    // MARK: Helpers

    private func remove(_ action: SwipeAction) {
        Haptics.success()
        willLeave()
        app.perform(action, on: [conversation])
        app.didRemoveFocusedConversation(conversation.id)
    }

    /// Moves that go straight to the store rather than through a swipe action: leave the screen
    /// the same way, and on Mac select a neighbour so the detail column doesn't go blank.
    private func relocate(_ change: () -> Void) {
        Haptics.success()
        willLeave()
        #if os(macOS)
        if app.selection.contains(conversation.id) {
            if let neighbour = app.conversation(after: conversation.id, offset: 1) ?? app.conversation(after: conversation.id, offset: -1),
               neighbour.id != conversation.id {
                app.selection = [neighbour.id]
            } else {
                app.selection = []
            }
        }
        #endif
        change()
        app.didRemoveFocusedConversation(conversation.id)
    }

    private func path(for role: MailboxRole) -> String? {
        store.mailboxes(for: conversation.accountID).first { $0.role == role }?.path
    }
}

// MARK: - iPhone bottom capsule

/// The floating capsule at the bottom of the reader on iPhone: Archive, Trash, Snooze and Reply.
struct ReaderActionBar: View {
    let actions: ReaderActions

    var body: some View {
        HStack(spacing: 0) {
            IconButton("archivebox", label: "Archive") { actions.archive() }
            IconButton("trash", label: "Move to Trash") { actions.trash() }
            IconButton("clock", label: "Snooze") { actions.snooze() }
            Spacer(minLength: InkSpace.m)
            ReaderReplyButton(actions: actions)
        }
        .padding(.leading, InkSpace.xs)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: 440)
        .inkGlass(in: Capsule(), interactive: true)
        .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        .padding(.horizontal, InkSpace.l)
        .padding(.bottom, InkSpace.xs)
    }
}

/// The accent "Reply" capsule. Tap replies; touch and hold for Reply All and Forward.
struct ReaderReplyButton: View {
    let actions: ReaderActions

    @Environment(AppSettings.self) private var settings
    @Environment(\.inkAccent) private var accent

    var body: some View {
        Menu {
            Button { actions.reply(.replyAll) } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            Button { actions.reply(.forward) } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                .labelStyle(.titleAndIcon)
                .font(InkFont.button)
                .foregroundStyle(settings.accent.onColor)
                .padding(.horizontal, InkSpace.l)
                .frame(minHeight: InkSize.hit)
                .background(accent, in: Capsule())
                .contentShape(Capsule())
        } primaryAction: {
            actions.reply(.reply)
        }
        .menuStyle(.button)
        .buttonStyle(PressableStyle(scale: 0.95))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Reply")
        .accessibilityHint("Touch and hold for Reply All and Forward")
    }
}

// MARK: - Menus and toolbar

/// Mark unread, Move to Inbox / Unsnooze / Not Spam, Move to…, Report Spam.
struct ReaderMoreMenuItems: View {
    let actions: ReaderActions

    var body: some View {
        Button { actions.markUnread() } label: {
            Label("Mark as Unread", systemImage: "envelope.badge")
        }
        if actions.snoozedUntil != nil {
            Button { actions.unsnooze() } label: {
                Label("Unsnooze", systemImage: "clock.arrow.circlepath")
            }
        } else if actions.isInJunk {
            Button { actions.moveToInbox() } label: {
                Label("Not Spam", systemImage: "checkmark.shield")
            }
        } else if !actions.isInInbox {
            Button { actions.moveToInbox() } label: {
                Label("Move to Inbox", systemImage: "tray.and.arrow.down")
            }
        }
        let targets = actions.moveTargets
        if !targets.isEmpty {
            Menu {
                ForEach(targets) { mailbox in
                    Button { actions.move(to: mailbox) } label: {
                        Label(String(repeating: "   ", count: mailbox.depth) + mailbox.displayName, systemImage: mailbox.role.systemImage)
                    }
                }
            } label: {
                Label("Move to…", systemImage: "folder")
            }
        }
        if !actions.isInJunk {
            Divider()
            Button(role: .destructive) { actions.markSpam() } label: {
                Label("Report Spam", systemImage: "xmark.octagon")
            }
        }
    }
}

/// Navigation bar items on iPhone (fading subject, star, More) and the toolbar on Mac
/// (Archive, Trash, Snooze, Star, Reply, More).
@MainActor
struct ReaderToolbar: ToolbarContent {
    let actions: ReaderActions
    let subject: String
    /// The subject has scrolled under the bar (iPhone shows it inline).
    let showsTitle: Bool

    var body: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .principal) {
            Text(subject)
                .font(InkFont.headline)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .opacity(showsTitle ? 1 : 0)
                .offset(y: showsTitle ? 0 : 6)
                .animation(InkMotion.snappy, value: showsTitle)
                .accessibilityHidden(!showsTitle)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            starButton
            moreMenu
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            Button { actions.archive() } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .help("Archive")
            Button { actions.trash() } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .help("Move to Trash")
            Button { actions.snooze() } label: {
                Label("Snooze", systemImage: "clock")
            }
            .help("Snooze")
            starButton
            Menu {
                Button { actions.reply(.replyAll) } label: {
                    Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                }
                Button { actions.reply(.forward) } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                }
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            } primaryAction: {
                actions.reply(.reply)
            }
            .help("Reply")
            moreMenu
        }
        #endif
    }

    private var starButton: some View {
        Button { actions.toggleStar() } label: {
            Label(actions.isFlagged ? "Unstar" : "Star", systemImage: actions.isFlagged ? "star.fill" : "star")
                .foregroundStyle(actions.isFlagged ? Ink.star : Ink.primary)
        }
        .symbolEffect(.bounce, value: actions.isFlagged)
        .help(actions.isFlagged ? "Unstar" : "Star")
    }

    private var moreMenu: some View {
        Menu {
            ReaderMoreMenuItems(actions: actions)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("More")
    }
}
