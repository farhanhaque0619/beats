import SwiftUI
import InkCore

struct ConversationRowStyle: Equatable {
    var showAvatar = true
    /// Lines of snippet (0 hides it).
    var previewLines = 2
    var compact = false
    /// Unified views with several accounts show a dot in the account's colour.
    var showAccountDot = false
    /// Sent and Drafts show who it went to instead of who sent it.
    var showRecipients = false

    init(showAvatar: Bool = true, previewLines: Int = 2, compact: Bool = false, showAccountDot: Bool = false, showRecipients: Bool = false) {
        self.showAvatar = showAvatar
        self.previewLines = previewLines
        self.compact = compact
        self.showAccountDot = showAccountDot
        self.showRecipients = showRecipients
    }

    @MainActor
    init(settings: AppSettings, scope: MailScope, accountCount: Int) {
        self.init(
            showAvatar: settings.showAvatars,
            previewLines: settings.previewLines,
            compact: settings.density == .compact,
            showAccountDot: scope.accountID == nil && accountCount > 1,
            showRecipients: scope.role == .sent || scope.role == .drafts
        )
    }
}

/// One conversation in a list. Equatable so SwiftUI skips re-rendering unchanged rows while
/// scrolling or when another row changes.
struct ConversationRow: View, Equatable {
    let conversation: Conversation
    var style = ConversationRowStyle()
    var accountColorIndex = 0
    /// Lowercased addresses of your accounts, shown as "me".
    var myAddresses: Set<String> = []
    var snoozedUntil: Date?

    static func == (lhs: ConversationRow, rhs: ConversationRow) -> Bool {
        lhs.conversation == rhs.conversation && lhs.style == rhs.style && lhs.accountColorIndex == rhs.accountColorIndex
            && lhs.myAddresses == rhs.myAddresses && lhs.snoozedUntil == rhs.snoozedUntil
    }

    /// `.increased` on a selected row in a focused Mac list (white on the accent highlight).
    @Environment(\.backgroundProminence) private var prominence

    private var onHighlight: Bool { prominence == .increased }
    private var primaryText: Color { onHighlight ? .white : Ink.primary }
    private var secondaryText: Color { onHighlight ? .white.opacity(0.78) : Ink.secondary }
    private var tertiaryText: Color { onHighlight ? .white.opacity(0.6) : Ink.tertiary }

    var body: some View {
        let unread = conversation.isUnread
        HStack(alignment: .top, spacing: InkSpace.m) {
            if style.showAvatar {
                AvatarView(address: headlinePerson, size: style.compact ? InkSize.avatarSmall : InkSize.avatar)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: style.compact ? 1 : 3) {
                HStack(alignment: .firstTextBaseline, spacing: InkSpace.xs) {
                    if style.showAccountDot {
                        AccountDot(colorIndex: accountColorIndex)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    }
                    Text(peopleLine)
                        .font(unread ? InkFont.sender : InkFont.senderRead)
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                    if conversation.count > 1 {
                        Text("\(conversation.count)")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(tertiaryText)
                    }
                    Spacer(minLength: InkSpace.s)
                    trailingMeta(unread: unread)
                }
                Text(conversation.subject)
                    .font(unread ? InkFont.subject : InkFont.subjectRead)
                    .foregroundStyle(unread ? primaryText : primaryText.opacity(0.78))
                    .lineLimit(1)
                if style.previewLines > 0, !conversation.snippet.isEmpty {
                    Text(conversation.snippet)
                        .font(InkFont.snippet)
                        .foregroundStyle(secondaryText)
                        .lineLimit(style.previewLines)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(.leading, InkSpace.gutter)
        .padding(.trailing, InkSpace.gutter)
        .padding(.vertical, style.compact ? InkSpace.rowVerticalCompact : InkSpace.rowVertical)
        .overlay(alignment: .topLeading) {
            if unread && !onHighlight {
                UnreadDot()
                    .padding(.leading, 7)
                    .padding(.top, unreadDotTop)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(InkMotion.snappy, value: unread)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func trailingMeta(unread: Bool) -> some View {
        HStack(spacing: 5) {
            if conversation.hasAttachments {
                Image(systemName: "paperclip")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tertiaryText)
            }
            if conversation.isFlagged {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(Ink.star)
            }
            if let snoozedUntil {
                Label(InkDate.listTimestamp(snoozedUntil), systemImage: "clock")
                    .labelStyle(.titleAndIcon)
                    .font(InkFont.meta)
                    .foregroundStyle(Ink.snooze)
            } else {
                Text(InkDate.listTimestamp(conversation.date))
                    .font(InkFont.meta)
                    .foregroundStyle(unread ? primaryText : secondaryText)
            }
        }
        .fixedSize()
    }

    /// Lines the unread dot up with the sender line (beside the avatar's centre when shown).
    private var unreadDotTop: CGFloat {
        let rowPadding: CGFloat = style.compact ? InkSpace.rowVerticalCompact : InkSpace.rowVertical
        let lineOffset: CGFloat
        if style.showAvatar {
            lineOffset = style.compact ? 10 : 16
        } else {
            lineOffset = 7
        }
        return rowPadding + lineOffset
    }

    /// The person whose avatar represents the row: the latest sender who isn't you (or the
    /// recipient for sent mail).
    private var headlinePerson: EmailAddress? {
        if style.showRecipients { return conversation.latest?.to.first }
        let others = conversation.messages.reversed().compactMap(\.sender).filter { !myAddresses.contains($0.normalized) }
        return others.first ?? conversation.latest?.sender
    }

    /// "Ana, Ben & me" / "To: Ana".
    private var peopleLine: String {
        if style.showRecipients {
            let to = conversation.latest.map { ($0.to + $0.cc).uniqued() } ?? []
            return to.isEmpty ? "No recipients" : "To: " + to.shortList()
        }
        let senders = conversation.senders
        guard !senders.isEmpty else { return "Unknown sender" }
        if senders.count == 1 {
            let only = senders[0]
            return myAddresses.contains(only.normalized) ? "me" : only.displayName
        }
        let names = senders.map { myAddresses.contains($0.normalized) ? "me" : $0.firstName }
        if names.count <= 3 { return ListFormatterLite.join(names) }
        return names.prefix(2).joined(separator: ", ") + " … " + (names.last ?? "")
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if conversation.isUnread { parts.append("Unread") }
        if conversation.isFlagged { parts.append("Starred") }
        parts.append("From \(peopleLine)")
        parts.append(conversation.subject)
        parts.append(InkDate.listTimestamp(conversation.date))
        if conversation.count > 1 { parts.append("\(conversation.count) messages") }
        if conversation.hasAttachments { parts.append("Has attachments") }
        parts.append(conversation.snippet)
        return parts.joined(separator: ", ")
    }
}
