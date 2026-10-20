#if os(macOS)
import SwiftUI
import InkCore

/// Shown in the detail column when several conversations are selected: a little stack of cards
/// that grows with the selection, the count, and the actions that apply to all of them.
struct MacBulkSelectionPanel: View {
    let conversations: [Conversation]

    @Environment(AppModel.self) private var app

    var body: some View {
        let actions = MacActions(app: app)
        VStack(spacing: InkSpace.xl) {
            MacCardStack(conversations: conversations)
            VStack(spacing: InkSpace.xs) {
                Text("\(conversations.count) conversations selected")
                    .font(InkFont.title)
                    .tracking(InkTracking.title)
                    .foregroundStyle(Ink.primary)
                    .contentTransition(.numericText())
                if !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(Ink.secondary)
                }
            }
            .multilineTextAlignment(.center)
            HStack(spacing: InkSpace.s) {
                ForEach(commands(actions)) { command in
                    MacBulkActionButton(
                        title: shortTitle(command, actions: actions),
                        systemImage: actions.systemImage(for: command),
                        tint: tint(command),
                        hint: command.paletteHint
                    ) {
                        actions.run(command)
                    }
                }
            }
            Button("Clear selection") {
                withAnimation(InkMotion.smooth) { app.selection = [] }
            }
            .buttonStyle(.plain)
            .font(InkFont.caption)
            .foregroundStyle(Ink.tertiary)
            .help("Clear selection (Esc)")
        }
        .padding(InkSpace.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(InkMotion.bouncy, value: conversations.count)
    }

    private func commands(_ actions: MacActions) -> [MacCommand] {
        var result: [MacCommand] = [.archive, .trash, .toggleRead, .toggleStar, .snooze, .spam]
        if actions.isAvailable(.moveToInbox) { result.append(.moveToInbox) }
        return result
    }

    private func shortTitle(_ command: MacCommand, actions: MacActions) -> String {
        switch command {
        case .trash: return "Trash"
        case .snooze: return "Snooze"
        case .spam: return "Spam"
        case .moveToInbox: return "Inbox"
        case .toggleRead: return conversations.contains(where: \.isUnread) ? "Read" : "Unread"
        default: return actions.title(for: command)
        }
    }

    private func tint(_ command: MacCommand) -> Color {
        switch command {
        case .archive: return Ink.archive
        case .trash: return Ink.trash
        case .snooze: return Ink.snooze
        case .toggleStar: return Ink.star
        default: return Ink.primary
        }
    }

    /// "4 unread · 2 starred · 3 accounts".
    private var summary: String {
        var parts: [String] = []
        let unread = conversations.filter(\.isUnread).count
        if unread > 0 { parts.append("\(unread) unread") }
        let starred = conversations.filter(\.isFlagged).count
        if starred > 0 { parts.append("\(starred) starred") }
        let messages = conversations.reduce(0) { $0 + $1.count }
        if messages > conversations.count { parts.append("\(messages) messages") }
        return parts.joined(separator: " · ")
    }
}

/// Up to three cards fanned behind each other; the front one shows the newest conversation.
private struct MacCardStack: View {
    let conversations: [Conversation]

    var body: some View {
        let visible = Array(conversations.prefix(3))
        ZStack {
            ForEach(Array(visible.enumerated().reversed()), id: \.element.id) { index, conversation in
                card(conversation, isFront: index == 0)
                    .scaleEffect(1 - CGFloat(index) * 0.06)
                    .offset(y: CGFloat(index) * -12)
                    .rotationEffect(.degrees(Double(index) * (index % 2 == 0 ? 2.5 : -2.5)))
                    .opacity(1 - Double(index) * 0.18)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(width: 300, height: 120)
        .padding(.top, InkSpace.xl)
        .accessibilityHidden(true)
    }

    private func card(_ conversation: Conversation, isFront: Bool) -> some View {
        HStack(alignment: .top, spacing: InkSpace.m) {
            AvatarView(address: conversation.latest?.sender, size: InkSize.avatarSmall)
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.latest?.sender?.displayName ?? "")
                    .font(InkFont.sender)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(conversation.subject)
                    .font(InkFont.subjectRead)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(InkSpace.l)
        .frame(width: 300, height: 84, alignment: .topLeading)
        .background(Ink.elevated, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous).stroke(Ink.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(isFront ? 0.12 : 0.05), radius: isFront ? 16 : 8, y: isFront ? 8 : 4)
    }
}

/// Round icon over a short label; the icon picks up the action's colour on hover.
private struct MacBulkActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let hint: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isHovering ? tint : Ink.primary)
                    .frame(width: InkSize.hit, height: InkSize.hit)
                    .background(isHovering ? tint.opacity(0.14) : Ink.fill, in: Circle())
                    .scaleEffect(isHovering ? 1.06 : 1)
                Text(title)
                    .font(InkFont.caption)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering in
            withAnimation(InkMotion.snappy) { isHovering = hovering }
        }
        .help(hint.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
    }
}
#endif
