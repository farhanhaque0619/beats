import SwiftUI
import InkCore

/// One message in a thread. Collapsed it's a single line (avatar, sender, snippet, date) that
/// expands on tap; expanded it shows the header, optional details, and the body.
struct MessageCard: View {
    let message: MessageSummary
    let isExpanded: Bool
    /// The newest message: tapping its header shows details instead of collapsing it, and it
    /// carries the Unsubscribe button.
    let isLatest: Bool
    /// Fold quoted text that repeats earlier messages (everything but the first message).
    let collapseQuotes: Bool
    /// Hairline above the card (off right after the "N more" pill, which draws its own line).
    var showsSeparator = true
    let onToggle: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    @State private var showsDetails = false
    @ScaledMetric(relativeTo: .footnote) private var detailLabelWidth: CGFloat = 60

    var body: some View {
        Group {
            if isExpanded {
                expanded
                    .transition(.opacity)
            } else {
                collapsed
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if showsSeparator {
                Rectangle()
                    .fill(Ink.hairline)
                    .frame(height: 1 / displayScale)
                    .padding(.leading, InkSpace.gutter)
            }
        }
    }

    // MARK: Collapsed

    private var collapsed: some View {
        Button(action: onToggle) {
            // Two lines, like Apple Mail: who and when on top, what they said underneath, so the
            // preview gets the full width instead of what's left beside the name.
            HStack(alignment: .top, spacing: InkSpace.m) {
                AvatarView(address: message.sender, size: InkSize.avatarSmall)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: InkSpace.s) {
                        Text(senderName)
                            .font(message.isUnread ? InkFont.sender : InkFont.senderRead)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        Spacer(minLength: InkSpace.s)
                        if message.hasAttachments {
                            Image(systemName: "paperclip")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Ink.tertiary)
                        }
                        Text(InkDate.listTimestamp(message.date))
                            .font(InkFont.meta)
                            .foregroundStyle(Ink.tertiary)
                            .fixedSize()
                    }
                    if !message.snippet.isEmpty {
                        Text(message.snippet)
                            .font(InkFont.snippet)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, InkSpace.gutter)
            .padding(.vertical, InkSpace.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(ReaderRowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(senderName), \(InkDate.listTimestamp(message.date)), \(message.snippet)")
        .accessibilityHint("Shows the whole message")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: InkSpace.m) {
            header
                .padding(.horizontal, InkSpace.gutter)
            if showsDetails {
                details
                    .padding(.horizontal, InkSpace.gutter)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            ReaderMessageBody(message: message, collapseQuotes: collapseQuotes)
        }
        .padding(.top, InkSpace.l)
        .padding(.bottom, InkSpace.xl)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: InkSpace.m) {
            AvatarView(address: message.sender)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: InkSpace.s) {
                    Text(senderName)
                        .font(InkFont.sender)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Spacer(minLength: InkSpace.xs)
                    Text(InkDate.reader(message.date))
                        .font(InkFont.meta)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                HStack(spacing: InkSpace.s) {
                    detailsToggle
                    Spacer(minLength: InkSpace.xs)
                    if isLatest, let unsubscribe = ReaderUnsubscribe(message: message) {
                        ReaderUnsubscribeButton(message: message, method: unsubscribe)
                    }
                    replyMenu
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { headerTapped() }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(headerActionName)) {
            headerTapped()
        }
    }

    private var detailsToggle: some View {
        Button {
            toggleDetails()
        } label: {
            HStack(spacing: 4) {
                Text(recipientSummary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(showsDetails ? 180 : 0))
            }
            .font(.subheadline)
            .foregroundStyle(Ink.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recipientSummary)
        .accessibilityHint(showsDetails ? "Hides the details" : "Shows sender, recipients and date")
    }

    private var replyMenu: some View {
        Menu {
            Button { reply(.reply) } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button { reply(.replyAll) } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            Button { reply(.forward) } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }
        } label: {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .frame(width: 34, height: 28)
                .contentShape(Rectangle())
        } primaryAction: {
            reply(.reply)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Reply to this message")
        .accessibilityHint("Touch and hold for Reply All and Forward")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: InkSpace.xs) {
            detailRow("From", value: addresses(message.from))
            if !message.replyTo.isEmpty, message.replyTo != message.from {
                detailRow("Reply to", value: addresses(message.replyTo))
            }
            detailRow("To", value: addresses(message.to))
            if !message.cc.isEmpty {
                detailRow("Cc", value: addresses(message.cc))
            }
            if !message.bcc.isEmpty {
                detailRow("Bcc", value: addresses(message.bcc))
            }
            detailRow("Date", value: InkDate.full(message.date))
        }
        .font(.footnote)
        .textSelection(.enabled)
        .padding(InkSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: InkSpace.m) {
            Text(title)
                .foregroundStyle(Ink.tertiary)
                .frame(width: detailLabelWidth, alignment: .trailing)
            Text(value)
                .foregroundStyle(Ink.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Behaviour

    private var headerActionName: String {
        guard isLatest else { return "Collapse" }
        return showsDetails ? "Hide details" : "Show details"
    }

    private func headerTapped() {
        if isLatest {
            toggleDetails()
        } else {
            onToggle()
        }
    }

    private func toggleDetails() {
        Haptics.tick()
        withAnimation(InkMotion.snappy) { showsDetails.toggle() }
    }

    private func reply(_ mode: ReplyMode) {
        Haptics.tick()
        app.reply(to: message, mode: mode)
    }

    // MARK: Text

    private var senderName: String {
        message.sender?.displayName ?? "Unknown sender"
    }

    /// "to me, Ana" / "to me, Ana & 3 more".
    private var recipientSummary: String {
        let people = (message.to + message.cc).uniqued()
        guard !people.isEmpty else { return "to undisclosed recipients" }
        var names = people.map { store.isMe($0) ? "me" : $0.firstName }
        if let index = names.firstIndex(of: "me"), index > 0 {
            names.remove(at: index)
            names.insert("me", at: 0)
        }
        if names.count > 3 {
            return "to " + names.prefix(2).joined(separator: ", ") + " & \(names.count - 2) more"
        }
        return "to " + names.joined(separator: ", ")
    }

    private func addresses(_ list: [EmailAddress]) -> String {
        list.isEmpty ? "—" : list.map(\.formatted).joined(separator: ", ")
    }
}

/// Rows highlight while pressed instead of shrinking (they span the full width).
private struct ReaderRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Ink.selection : Color.clear)
            .animation(InkMotion.snappy, value: configuration.isPressed)
    }
}
