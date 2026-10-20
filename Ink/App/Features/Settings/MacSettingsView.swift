#if os(macOS)
import SwiftUI
import InkCore

/// The Mac Settings window: General, Accounts, Appearance, Swipes, Privacy.
struct SettingsMacRoot: View {
    var body: some View {
        TabView {
            SettingsMacPane {
                SettingsInboxSection()
                SettingsSendingSection()
                SettingsNotificationsSection()
                SettingsAboutSection()
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            SettingsMacAccountsPane()
                .tabItem { Label("Accounts", systemImage: "at") }

            SettingsMacPane {
                SettingsAppearanceSection()
            }
            .tabItem { Label("Appearance", systemImage: "paintbrush") }

            SettingsMacPane {
                SettingsSwipesSection()
            }
            .tabItem { Label("Swipes", systemImage: "hand.draw") }

            SettingsMacPane {
                SettingsPrivacySection()
            }
            .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 560, height: 540)
    }
}

private struct SettingsMacPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
    }
}

/// Accounts on Mac: the list on the left with + and −, the selected account on the right.
private struct SettingsMacAccountsPane: View {
    @Environment(MailStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(\.inkAccent) private var accent
    @State private var selection: String?
    @State private var isAddingAccount = false
    @State private var removalCandidate: AccountConfig?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.accounts) { account in
                        SettingsAccountRow(account: account)
                            .tag(account.id)
                    }
                }
                .listStyle(.inset)

                Divider()

                HStack(spacing: 0) {
                    Button {
                        isAddingAccount = true
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .help("Add account")
                    .accessibilityLabel("Add account")

                    Divider()
                        .frame(height: 16)

                    Button {
                        removalCandidate = selectedAccount
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .disabled(selectedAccount == nil)
                    .help("Remove account")
                    .accessibilityLabel("Remove account")

                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, InkSpace.s)
                .padding(.vertical, InkSpace.xs)
            }
            .frame(width: 210)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $isAddingAccount) {
            AddAccountFlow()
                .environment(app)
                .environment(store)
                .environment(settings)
                .environment(\.inkAccent, accent)
                .tint(accent)
        }
        .confirmationDialog(
            "Remove this account?",
            isPresented: isConfirmingRemoval,
            titleVisibility: .visible,
            presenting: removalCandidate
        ) { account in
            Button(Self.removalTitle(for: account), role: .destructive) {
                remove(account)
            }
        } message: { account in
            Text(Self.removalMessage(for: account))
        }
        .onAppear {
            if selection == nil { selection = store.accounts.first?.id }
        }
        .onChange(of: store.accounts.map(\.id)) { _, ids in
            if let current = selection, ids.contains(current) { return }
            selection = ids.first
        }
    }

    @ViewBuilder private var detail: some View {
        if let account = selectedAccount {
            if account.isDemo {
                VStack(spacing: InkSpace.l) {
                    EmptyStateView(
                        systemImage: "sparkles",
                        title: "Demo inbox",
                        message: "Sample mail that never leaves this Mac, for trying Ink without an account."
                    )
                    Button("Remove demo inbox", role: .destructive) {
                        removalCandidate = account
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SettingsAccountDetail(accountID: account.id)
                    .id(account.id)
            }
        } else {
            VStack(spacing: InkSpace.l) {
                EmptyStateView(
                    systemImage: "at",
                    title: store.accounts.isEmpty ? "No accounts yet" : "No account selected",
                    message: store.accounts.isEmpty ? "Add one to bring your mail in." : "Choose an account on the left."
                )
                if store.accounts.isEmpty {
                    Button("Add Account…") { isAddingAccount = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedAccount: AccountConfig? {
        selection.flatMap { store.account(id: $0) }
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(
            get: { removalCandidate != nil },
            set: { isPresented in
                if !isPresented { removalCandidate = nil }
            }
        )
    }

    private static func removalTitle(for account: AccountConfig) -> String {
        account.isDemo ? "Remove demo inbox" : "Remove \(account.emailAddress)"
    }

    private static func removalMessage(for account: AccountConfig) -> String {
        account.isDemo
            ? "The sample mail goes away. Your own accounts aren't touched."
            : "Its mail is cleared from this Mac. Nothing is deleted from the server."
    }

    private func remove(_ account: AccountConfig) {
        removalCandidate = nil
        Task {
            await store.removeAccount(id: account.id)
            Haptics.success()
        }
    }
}
#endif
