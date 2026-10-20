#if os(iOS)
import SwiftUI
import InkCore

/// Where to go after the switcher closes, for destinations that are sheets of their own.
enum MailboxSwitcherFollowUp: Equatable {
    case addAccount
    case settings
}

/// The iPhone mailbox picker, shown as a sheet from the inbox title: All Inboxes and each
/// account's inbox, the unified smart mailboxes, then every account's folders in collapsible
/// sections. Picking one switches the list and closes the sheet.
struct MailboxSwitcher: View {
    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(\.inkAccent) private var accent

    private let onFollowUp: ((MailboxSwitcherFollowUp) -> Void)?
    @State private var collapsedAccounts: Set<String> = []

    private static let indentStep: CGFloat = 16

    /// - Parameter onFollowUp: Receives Add Account / Settings so the presenter can open them
    ///   once this sheet has finished closing. Without it the switcher sets the flags itself.
    init(onFollowUp: ((MailboxSwitcherFollowUp) -> Void)? = nil) {
        self.onFollowUp = onFollowUp
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                inboxes
                smartMailboxes
                ForEach(store.accounts) { account in
                    accountFolders(account)
                }
                footer
            }
            .padding(.bottom, InkSpace.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Ink.background)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center) {
            Text("Mailboxes")
                .font(InkFont.title)
                .tracking(InkTracking.title)
                .foregroundStyle(Ink.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: InkSpace.s)
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 30, height: 30)
                    .background(Ink.fill, in: Circle())
                    .frame(width: InkSize.hit, height: InkSize.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Close")
        }
        .padding(.leading, InkSpace.gutter)
        .padding(.trailing, InkSpace.s)
        .padding(.top, InkSpace.xl)
        .padding(.bottom, InkSpace.s)
    }

    @ViewBuilder private var inboxes: some View {
        let multipleAccounts = store.accounts.count > 1
        row(
            scope: .allInboxes,
            title: store.title(for: .allInboxes),
            leading: .symbol(multipleAccounts ? "tray.2" : "tray"),
            badge: store.unreadCount(for: .allInboxes)
        )
        if multipleAccounts {
            ForEach(store.accounts) { account in
                let scope = MailScope.account(accountID: account.id, role: .inbox)
                row(
                    scope: scope,
                    title: account.emailAddress,
                    leading: .dot(account.colorIndex),
                    badge: store.unreadCount(for: scope)
                )
            }
        }
    }

    @ViewBuilder private var smartMailboxes: some View {
        SectionHeaderView("Smart mailboxes")
        ForEach(Self.smartRoles) { role in
            row(scope: .unified(role), title: role.title, leading: .symbol(role.systemImage))
        }
    }

    @ViewBuilder
    private func accountFolders(_ account: AccountConfig) -> some View {
        let folders = visibleFolders(for: account)
        if !folders.isEmpty {
            let isCollapsed = collapsedAccounts.contains(account.id)
            accountHeader(account, isCollapsed: isCollapsed)
            if !isCollapsed {
                ForEach(folders) { folder in
                    folderRow(folder)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func accountHeader(_ account: AccountConfig, isCollapsed: Bool) -> some View {
        Button {
            Haptics.tick()
            withAnimation(InkMotion.snappy) {
                collapsedAccounts.formSymmetricDifference([account.id])
            }
        } label: {
            HStack(spacing: InkSpace.s) {
                AccountDot(colorIndex: account.colorIndex)
                Text(account.emailAddress)
                    .font(.system(.caption, design: .default, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: InkSpace.s)
                Image(systemName: "chevron.down")
                    .font(.system(.caption, design: .default, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
            }
            .padding(.horizontal, InkSpace.gutter)
            .padding(.top, InkSpace.xl)
            .padding(.bottom, InkSpace.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(account.emailAddress)
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func folderRow(_ folder: MailboxInfo) -> some View {
        let indent = folder.role == .custom ? folder.depth : 0
        if folder.isSelectable {
            let scope = mailScope(for: folder)
            row(
                scope: scope,
                title: folder.displayName,
                leading: .symbol(folder.role.systemImage),
                indent: indent,
                badge: folder.role == .custom ? store.unreadCount(for: scope) : 0
            )
        } else {
            HStack(spacing: InkSpace.m) {
                Image(systemName: "folder")
                    .frame(width: 26)
                Text(folder.displayName)
                    .lineLimit(1)
            }
            .font(.body)
            .foregroundStyle(Ink.tertiary)
            .padding(.leading, InkSpace.gutter + CGFloat(indent) * Self.indentStep)
            .frame(minHeight: InkSize.hit)
            .accessibilityElement(children: .combine)
        }
    }

    private var footer: some View {
        HStack(spacing: InkSpace.m) {
            Button {
                follow(.addAccount)
            } label: {
                Label("Add account", systemImage: "plus")
                    .lineLimit(1)
            }
            Button {
                follow(.settings)
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .lineLimit(1)
            }
        }
        .buttonStyle(.inkSecondary)
        .padding(.horizontal, InkSpace.gutter)
        .padding(.top, InkSpace.xxl)
    }

    // MARK: Rows

    private enum RowLeading {
        case symbol(String)
        case dot(Int)
    }

    private func row(scope: MailScope, title: String, leading: RowLeading, indent: Int = 0, badge: Int = 0) -> some View {
        let isSelected = store.scope == scope
        return Button {
            select(scope)
        } label: {
            HStack(spacing: InkSpace.m) {
                leadingView(leading, isSelected: isSelected)
                    .frame(width: 26)
                Text(title)
                    .font(isSelected ? InkFont.headline : .body)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: InkSpace.s)
                if badge > 0 {
                    Text(InkFormat.badge(badge))
                        .font(InkFont.meta)
                        .foregroundStyle(Ink.tertiary)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(.subheadline, design: .default, weight: .bold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.leading, InkSpace.gutter + CGFloat(indent) * Self.indentStep)
            .padding(.trailing, InkSpace.gutter)
            .padding(.vertical, InkSpace.s)
            .frame(minHeight: InkSize.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(MailboxSwitcherRowStyle())
        .accessibilityValue(badge > 0 ? "\(badge) unread" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func leadingView(_ leading: RowLeading, isSelected: Bool) -> some View {
        switch leading {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(.body, design: .default, weight: .medium))
                .foregroundStyle(isSelected ? accent : Ink.secondary)
        case .dot(let colorIndex):
            AccountDot(colorIndex: colorIndex, size: 9)
        }
    }

    // MARK: Data

    private static var smartRoles: [MailboxRole] {
        MailboxRole.unifiedRoles.filter { $0 != .inbox }
    }

    /// An account's folders minus its inbox (listed above). With a single account the smart
    /// mailboxes already are its Sent, Trash and so on, so only its own folders remain. Parents
    /// that can't be opened stay only when they hold custom folders, to keep the tree readable.
    private func visibleFolders(for account: AccountConfig) -> [MailboxInfo] {
        let all = store.mailboxes(for: account.id)
        let isOnlyAccount = store.accounts.count == 1
        return all.filter { folder in
            if folder.role == .inbox { return false }
            if isOnlyAccount, MailboxRole.unifiedRoles.contains(folder.role) { return false }
            if folder.isSelectable { return true }
            guard let delimiter = folder.delimiter, !delimiter.isEmpty else { return false }
            let prefix = folder.path + delimiter
            return all.contains { $0.role == .custom && $0.path.hasPrefix(prefix) }
        }
    }

    private func mailScope(for folder: MailboxInfo) -> MailScope {
        if folder.role == .custom {
            return .mailbox(accountID: folder.accountID, path: folder.path)
        }
        return .account(accountID: folder.accountID, role: folder.role)
    }

    // MARK: Actions

    private func select(_ scope: MailScope) {
        Haptics.tick()
        if store.scope != scope {
            app.select(scope: scope)
        }
        close()
    }

    private func close() {
        app.isMailboxSwitcherPresented = false
    }

    private func follow(_ followUp: MailboxSwitcherFollowUp) {
        Haptics.tick()
        close()
        if let onFollowUp {
            onFollowUp(followUp)
            return
        }
        switch followUp {
        case .addAccount: app.isAddAccountPresented = true
        case .settings: app.isSettingsPresented = true
        }
    }
}

/// Highlights a mailbox row while it's pressed.
private struct MailboxSwitcherRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Ink.selection.opacity(configuration.isPressed ? 1 : 0))
            .animation(InkMotion.fade, value: configuration.isPressed)
    }
}
#endif
