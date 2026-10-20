#if os(iOS)
import SwiftUI
import InkCore

/// Something chosen from a conversation's long-press menu.
enum InboxRowCommand {
    /// The same actions swipes run (snooze opens the picker).
    case action(SwipeAction)
    /// Files the conversation into a folder of its account.
    case move(MailboxInfo)
    /// Back to the inbox from Archive, Trash, Spam or a folder.
    case moveToInbox
    /// Brings a snoozed conversation back now.
    case unsnooze
}

/// The long-press menu of an inbox row. Items adapt to where the list is: no Archive inside
/// Archive, "Not spam" style "Move to Inbox" outside the inbox, "Unsnooze" in Snoozed.
struct InboxRowMenu: View {
    let conversation: Conversation
    let scope: MailScope
    /// Folders of the conversation's account it can be moved to.
    let folders: [MailboxInfo]
    let handle: (InboxRowCommand) -> Void

    var body: some View {
        Section {
            if scope.role == .snoozed {
                Button { handle(.unsnooze) } label: {
                    Label("Unsnooze", systemImage: "clock.arrow.circlepath")
                }
            }
            if showsMoveToInbox {
                Button { handle(.moveToInbox) } label: {
                    Label("Move to Inbox", systemImage: "tray.and.arrow.down")
                }
            }
            if scope.role != .archive {
                Button { handle(.action(.archive)) } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
            Button { handle(.action(.toggleRead)) } label: {
                Label(
                    conversation.isUnread ? "Mark as read" : "Mark as unread",
                    systemImage: conversation.isUnread ? "envelope.open" : "envelope.badge"
                )
            }
            Button { handle(.action(.flag)) } label: {
                Label(conversation.isFlagged ? "Unstar" : "Star", systemImage: conversation.isFlagged ? "star.slash" : "star")
            }
            if scope.role != .snoozed {
                Button { handle(.action(.snooze)) } label: {
                    Label("Snooze…", systemImage: "clock")
                }
            }
            if !folders.isEmpty {
                Menu {
                    ForEach(folders) { folder in
                        Button { handle(.move(folder)) } label: {
                            Label(folder.displayName, systemImage: folder.role.systemImage)
                        }
                    }
                } label: {
                    Label("Move to…", systemImage: "folder")
                }
            }
        }
        Section {
            if scope.role != .junk {
                Button { handle(.action(.markSpam)) } label: {
                    Label("Spam", systemImage: "xmark.octagon")
                }
            }
            if scope.role != .trash {
                Button(role: .destructive) { handle(.action(.trash)) } label: {
                    Label("Trash", systemImage: "trash")
                }
            }
        }
    }

    private var showsMoveToInbox: Bool {
        switch scope {
        case .mailbox:
            return true
        case .unified(let role), .account(_, let role):
            return role == .archive || role == .trash || role == .junk
        }
    }
}

/// The card shown above the long-press menu: who, what, and more of the message than the row
/// has room for.
struct InboxRowPreview: View {
    let conversation: Conversation
    /// Lowercased addresses of your accounts, shown as "me".
    let myAddresses: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpace.s) {
            HStack(spacing: InkSpace.s) {
                AvatarView(address: conversation.latest?.sender, size: InkSize.avatarSmall)
                Text(senderName)
                    .font(InkFont.headline)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: InkSpace.s)
                Text(InkDate.listTimestamp(conversation.date))
                    .font(InkFont.meta)
                    .foregroundStyle(Ink.secondary)
            }
            Text(conversation.subject)
                .font(.system(.title3, design: .default, weight: .semibold))
                .tracking(InkTracking.title)
                .foregroundStyle(Ink.primary)
                .lineLimit(3)
                .padding(.top, InkSpace.xs)
            if !conversation.snippet.isEmpty {
                Text(conversation.snippet)
                    .font(InkFont.readerBody)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(8)
            }
            if conversation.count > 1 {
                Text("\(conversation.count) messages")
                    .font(InkFont.caption)
                    .foregroundStyle(Ink.tertiary)
                    .padding(.top, InkSpace.xxs)
            }
        }
        .padding(InkSpace.xl)
        .frame(width: 340, alignment: .leading)
        .background(Ink.elevated)
    }

    private var senderName: String {
        guard let sender = conversation.latest?.sender else { return "Unknown sender" }
        return myAddresses.contains(sender.normalized) ? "me" : sender.displayName
    }
}
#endif
