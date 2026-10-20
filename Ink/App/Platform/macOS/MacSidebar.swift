#if os(macOS)
import SwiftUI
import InkCore

/// One selectable place in the sidebar.
struct MacSidebarItem: Identifiable, Hashable {
    let scope: MailScope
    let title: String
    let systemImage: String
    /// The account's name for per-account rows, used to qualify menu and palette titles.
    var accountName: String?
    var depth: Int = 0
    /// Parent folders that can't hold mail (`\Noselect`) are shown but not selectable.
    var isSelectable = true

    var id: MailScope { scope }

    /// "Work · Receipts" outside the sidebar, where the section header isn't there to say whose.
    var qualifiedTitle: String {
        guard let accountName else { return title }
        return "\(accountName) · \(title)"
    }

    /// Unread badges only where unread means something.
    var showsUnreadCount: Bool {
        guard let role = scope.role else { return true }
        return ![.sent, .drafts, .trash, .archive, .all].contains(role)
    }
}

/// The sidebar's contents in display order, shared with the Mailbox menu (⌘1…⌘9) and the palette.
@MainActor
enum MacSidebarCatalog {
    /// Smart mailboxes that span every account.
    static func smartMailboxes(store: MailStore) -> [MacSidebarItem] {
        MailboxRole.unifiedRoles.map { role in
            let title = role == .inbox ? (store.accounts.count > 1 ? "All Inboxes" : "Inbox") : role.title
            return MacSidebarItem(scope: .unified(role), title: title, systemImage: role.systemImage)
        }
    }

    /// An account's folders. With one account the smart mailboxes already cover the well-known
    /// roles, so only its own folders (and All Mail) are listed.
    static func folders(for account: AccountConfig, store: MailStore) -> [MacSidebarItem] {
        let multipleAccounts = store.accounts.count > 1
        let unifiedRoles = Set(MailboxRole.unifiedRoles)
        let name = displayName(of: account)
        let mailboxes = store.mailboxes(for: account.id)
        var items: [MacSidebarItem] = []
        var seenRoles = Set<MailboxRole>()

        if multipleAccounts {
            items.append(MacSidebarItem(scope: .account(accountID: account.id, role: .inbox), title: MailboxRole.inbox.title,
                                        systemImage: MailboxRole.inbox.systemImage, accountName: name))
            seenRoles.insert(.inbox)
        }
        for mailbox in mailboxes {
            if mailbox.role == .custom {
                guard mailbox.isSelectable || hasChildren(mailbox, in: mailboxes) else { continue }
                items.append(MacSidebarItem(scope: .mailbox(accountID: account.id, path: mailbox.path), title: mailbox.displayName,
                                            systemImage: MailboxRole.custom.systemImage, accountName: name,
                                            depth: mailbox.depth, isSelectable: mailbox.isSelectable))
            } else {
                guard !seenRoles.contains(mailbox.role) else { continue }
                if !multipleAccounts && unifiedRoles.contains(mailbox.role) { continue }
                seenRoles.insert(mailbox.role)
                items.append(MacSidebarItem(scope: .account(accountID: account.id, role: mailbox.role), title: mailbox.role.title,
                                            systemImage: mailbox.role.systemImage, accountName: name))
            }
        }
        return items
    }

    /// Every sidebar row, in order.
    static func all(store: MailStore) -> [MacSidebarItem] {
        smartMailboxes(store: store) + store.accounts.flatMap { folders(for: $0, store: store) }
    }

    static func displayName(of account: AccountConfig) -> String {
        let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? account.emailAddress : name
    }

    private static func hasChildren(_ mailbox: MailboxInfo, in mailboxes: [MailboxInfo]) -> Bool {
        guard let delimiter = mailbox.delimiter, !delimiter.isEmpty else { return false }
        let prefix = mailbox.path + delimiter
        return mailboxes.contains { $0.isSelectable && $0.path.hasPrefix(prefix) }
    }
}

/// Mac sidebar: smart mailboxes, then a collapsible section per account, then a footer with the
/// sync status, Add Account and Settings.
struct MacSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @State private var collapsedAccounts: Set<String> = []

    var body: some View {
        List(selection: scopeSelection) {
            Section {
                ForEach(MacSidebarCatalog.smartMailboxes(store: store)) { item in
                    MacSidebarRow(item: item, unread: unreadCount(item))
                        .tag(item.scope)
                }
            }
            ForEach(store.accounts) { account in
                let items = MacSidebarCatalog.folders(for: account, store: store)
                if !items.isEmpty {
                    Section(isExpanded: expansion(for: account.id)) {
                        ForEach(items) { item in
                            if item.isSelectable {
                                MacSidebarRow(item: item, unread: unreadCount(item))
                                    .tag(item.scope)
                            } else {
                                MacSidebarRow(item: item, unread: 0)
                                    .selectionDisabled()
                            }
                        }
                    } header: {
                        MacAccountHeader(account: account)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacSidebarFooter()
        }
    }

    private var scopeSelection: Binding<MailScope?> {
        Binding(
            get: { store.scope },
            set: { newValue in
                guard let newValue, newValue != store.scope else { return }
                Haptics.tick()
                app.select(scope: newValue)
            }
        )
    }

    private func expansion(for accountID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedAccounts.contains(accountID) },
            set: { expanded in
                withAnimation(InkMotion.snappy) {
                    if expanded {
                        collapsedAccounts.remove(accountID)
                    } else {
                        collapsedAccounts.insert(accountID)
                    }
                }
            }
        )
    }

    private func unreadCount(_ item: MacSidebarItem) -> Int {
        item.showsUnreadCount ? store.unreadCount(for: item.scope) : 0
    }
}

private struct MacSidebarRow: View {
    let item: MacSidebarItem
    let unread: Int

    var body: some View {
        let unreadDescription: String = unread > 0 ? "\(unread) unread" : ""
        HStack(spacing: InkSpace.s) {
            // Hierarchical styles (not Ink colours) so the selected row's text inverts like the
            // rest of the system sidebar; icons stay monochrome instead of taking the accent.
            Label {
                Text(item.title)
                    .lineLimit(1)
                    .foregroundStyle(item.isSelectable ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
            } icon: {
                Image(systemName: item.systemImage)
                    .foregroundStyle(HierarchicalShapeStyle.secondary)
            }
            Spacer(minLength: InkSpace.xs)
            if unread > 0 {
                Text(InkFormat.badge(unread))
                    .font(InkFont.mono)
                    .foregroundStyle(HierarchicalShapeStyle.tertiary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.leading, CGFloat(min(item.depth, 6)) * InkSpace.m)
        .animation(InkMotion.snappy, value: unread)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: unreadDescription))
    }
}

private struct MacAccountHeader: View {
    let account: AccountConfig

    var body: some View {
        HStack(spacing: 6) {
            AccountDot(colorIndex: account.colorIndex)
            Text(MacSidebarCatalog.displayName(of: account))
                .lineLimit(1)
        }
        .help(account.emailAddress)
        .accessibilityLabel(account.emailAddress)
    }
}

/// Sync status, Add Account and Settings, pinned under the sidebar list.
private struct MacSidebarFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpace.s) {
            MacSyncStatusLine()
            HStack(spacing: InkSpace.s) {
                Button {
                    app.isAddAccountPresented = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                        .font(InkFont.caption)
                        .foregroundStyle(Ink.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help("Add an email account")
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, InkSpace.l)
        .padding(.top, InkSpace.s)
        .padding(.bottom, InkSpace.m)
        .overlay(alignment: .top) {
            Rectangle().fill(Ink.hairline).frame(height: 0.5)
        }
    }
}

/// "Updated 2 min ago", "Checking for mail…" or the last error. Click to check now.
private struct MacSyncStatusLine: View {
    @Environment(MailStore.self) private var store

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        let failure = failureMessage
        let isSyncing = store.syncStatus == .syncing
        Button {
            let mailStore = store
            Task { await mailStore.refresh() }
        } label: {
            HStack(spacing: 6) {
                if isSyncing {
                    LoadingDots()
                        .scaleEffect(0.7)
                        .frame(width: 26, height: 10)
                    Text("Checking for mail…")
                } else if let failure {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Ink.danger)
                    Text(failure)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if let lastSynced = store.lastSyncedAt {
                    TimelineView(.everyMinute) { context in
                        Text(Self.updatedText(lastSynced, now: context.date))
                    }
                } else {
                    Text(store.isDemoActive ? "Demo inbox" : "Not checked yet")
                }
            }
            .font(InkFont.caption)
            .foregroundStyle(Ink.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .animation(InkMotion.fade, value: isSyncing)
        }
        .buttonStyle(.plain)
        .disabled(isSyncing)
        .help(failure ?? "Check for new mail")
        .accessibilityHint("Checks for new mail")
    }

    private var failureMessage: String? {
        if case .failed(let message) = store.syncStatus { return message }
        return nil
    }

    private static func updatedText(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "Updated just now" }
        return "Updated " + relative.localizedString(for: date, relativeTo: now)
    }
}
#endif
