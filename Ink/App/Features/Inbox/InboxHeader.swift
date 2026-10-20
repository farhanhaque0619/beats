#if os(iOS)
import SwiftUI
import InkCore

/// The top of the inbox: the mailbox title (tap to switch), unread count, search and settings,
/// and the Focus / Other pill for inboxes. It drifts and fades as the list scrolls over it.
struct InboxHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let scope = store.scope
        let showsSplit = scope.role == .inbox && store.focusedInboxEnabled
        let otherBadge = store.otherUnreadCount > 0 ? store.otherUnreadCount : store.otherCount
        VStack(alignment: .leading, spacing: InkSpace.m) {
            HStack(alignment: .center, spacing: 0) {
                InboxTitleButton(title: store.title(for: scope), unreadCount: store.unreadCount(for: scope)) {
                    Haptics.tick()
                    app.isMailboxSwitcherPresented = true
                }
                .layoutPriority(1)
                Spacer(minLength: InkSpace.s)
                HStack(spacing: 0) {
                    IconButton("magnifyingglass", label: "Search") { app.isSearchPresented = true }
                    IconButton("gearshape", label: "Settings") { app.isSettingsPresented = true }
                }
                .padding(.trailing, -InkSpace.m)
            }
            if showsSplit {
                InboxFilterPill(
                    selection: $store.inboxFilter,
                    otherBadge: otherBadge,
                    otherHasUnread: store.otherUnreadCount > 0
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            }
        }
        .padding(.horizontal, InkSpace.gutter)
        .padding(.top, InkSpace.s)
        .padding(.bottom, showsSplit ? InkSpace.xs : 0)
        .animation(InkMotion.smooth, value: showsSplit)
        .visualEffect { content, proxy in
            let travel = max(0, -proxy.frame(in: .scrollView).minY)
            let progress = min(travel / 110, 1)
            return content
                .opacity(1 - progress)
                .offset(y: travel * 0.3)
        }
    }
}

/// "Inbox 12 ⌄" in the big tight title face; opens the mailbox switcher.
private struct InboxTitleButton: View {
    let title: String
    let unreadCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: InkSpace.s) {
                Text(title)
                    .inkLargeTitle()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if unreadCount > 0 {
                    Text(InkFormat.badge(unreadCount))
                        .font(.system(.title2, design: .default, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Ink.tertiary)
                        .contentTransition(.numericText(value: Double(unreadCount)))
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
                Image(systemName: "chevron.down")
                    .font(.system(.footnote, design: .default, weight: .heavy))
                    .foregroundStyle(Ink.tertiary)
            }
            .animation(InkMotion.snappy, value: unreadCount)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .accessibilityLabel(unreadCount > 0 ? "\(title), \(unreadCount) unread" : title)
        .accessibilityHint("Shows your mailboxes")
    }
}

/// Two-segment Focus / Other control; the selection capsule slides between segments.
struct InboxFilterPill: View {
    @Binding var selection: InboxFilter
    /// Number shown beside "Other" (hidden at zero).
    var otherBadge: Int
    /// Tints the number with the accent when it counts unread mail.
    var otherHasUnread: Bool

    @Environment(\.inkAccent) private var accent
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            segment(.focused)
            segment(.other)
        }
        .padding(3)
        .background(Ink.fill, in: Capsule())
    }

    private func segment(_ filter: InboxFilter) -> some View {
        let isSelected = selection == filter
        let showsBadge = filter == .other && otherBadge > 0
        return Button {
            guard !isSelected else { return }
            Haptics.tick()
            withAnimation(InkMotion.smooth) { selection = filter }
        } label: {
            HStack(spacing: 5) {
                Text(filter.title)
                    .font(InkFont.button)
                if showsBadge {
                    Text(InkFormat.badge(otherBadge))
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(badgeColor(isSelected: isSelected))
                        .contentTransition(.numericText(value: Double(otherBadge)))
                }
            }
            .foregroundStyle(isSelected ? Ink.onInverse : Ink.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Ink.inverse)
                        .matchedGeometryEffect(id: "selection", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(InkMotion.snappy, value: otherBadge)
        .accessibilityLabel(spokenTitle(for: filter))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func spokenTitle(for filter: InboxFilter) -> String {
        guard filter == .other, otherBadge > 0 else { return filter.title }
        return otherHasUnread ? "\(filter.title), \(otherBadge) unread" : "\(filter.title), \(otherBadge)"
    }

    private func badgeColor(isSelected: Bool) -> Color {
        if isSelected { return Ink.onInverse.opacity(0.7) }
        return otherHasUnread ? accent : Ink.tertiary
    }
}

/// A slim notice under the header when syncing failed, with Retry.
struct InboxSyncBanner: View {
    @Environment(MailStore.self) private var store
    @Environment(\.inkAccent) private var accent

    var body: some View {
        let message = failureMessage
        VStack(spacing: 0) {
            if let message {
                HStack(spacing: InkSpace.m) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Ink.danger)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        Haptics.tick()
                        Task { await store.refresh() }
                    } label: {
                        Text("Retry")
                            .font(InkFont.button)
                            .foregroundStyle(accent)
                            .padding(.vertical, InkSpace.xs)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
                .padding(.horizontal, InkSpace.m)
                .padding(.vertical, 10)
                .background(Ink.fill, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
                .padding(.horizontal, InkSpace.l)
                .padding(.top, InkSpace.s)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(InkMotion.smooth, value: message)
    }

    private var failureMessage: String? {
        switch store.syncStatus {
        case .failed(let message): return message
        case .idle, .syncing: return nil
        }
    }
}

/// The thin bar that replaces the big title once it scrolls away. Tapping the title scrolls back
/// to the top.
struct InboxCompactBar: View {
    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(\.displayScale) private var displayScale

    var onTitleTap: () -> Void

    var body: some View {
        let scope = store.scope
        let title = store.title(for: scope)
        let unread = store.unreadCount(for: scope)
        HStack(spacing: 0) {
            Color.clear
                .frame(width: InkSize.hit, height: InkSize.hit)
            Button(action: onTitleTap) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(InkFont.headline)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if unread > 0 {
                        Text(InkFormat.badge(unread))
                            .font(InkFont.meta)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: InkSize.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(unread > 0 ? "\(title), \(unread) unread" : title)
            .accessibilityHint("Scrolls to the top")
            IconButton("magnifyingglass", label: "Search") { app.isSearchPresented = true }
        }
        .padding(.horizontal, InkSpace.xs)
        .background {
            ZStack(alignment: .bottom) {
                Rectangle().fill(.ultraThinMaterial)
                Ink.background.opacity(0.55)
                Ink.hairline.frame(height: 1 / max(displayScale, 1))
            }
            .ignoresSafeArea(edges: .top)
        }
    }
}
#endif
