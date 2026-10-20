import SwiftUI
import InkCore

/// An account in a list: its colour dot, name and address.
struct SettingsAccountRow: View {
    let account: AccountConfig

    var body: some View {
        HStack(spacing: InkSpace.m) {
            AccountDot(colorIndex: account.colorIndex, size: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if account.isDemo { return "Demo inbox" }
        let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? account.emailAddress : name
    }

    private var subtitle: String {
        if account.isDemo { return "Sample mail that never leaves this device" }
        let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? OnboardingProvider.info(for: account.provider).name : account.emailAddress
    }
}

#if os(iOS)
/// Settings › Accounts on iPhone: each account pushes its detail; add one; remove the demo.
struct SettingsAccountsSection: View {
    var onAddAccount: () -> Void

    @Environment(MailStore.self) private var store
    @Environment(AppModel.self) private var app
    @State private var confirmsDemoRemoval = false

    var body: some View {
        Section {
            ForEach(store.accounts) { account in
                if account.isDemo {
                    SettingsAccountRow(account: account)
                } else {
                    NavigationLink {
                        SettingsAccountDetail(accountID: account.id, onRemoved: closeIfEmpty)
                    } label: {
                        SettingsAccountRow(account: account)
                    }
                }
            }
            Button(action: onAddAccount) {
                Label("Add account", systemImage: "plus")
            }
            if store.isDemoActive {
                Button(role: .destructive) {
                    confirmsDemoRemoval = true
                } label: {
                    Label("Remove demo inbox", systemImage: "trash")
                }
                .confirmationDialog("Remove the demo inbox?", isPresented: $confirmsDemoRemoval, titleVisibility: .visible) {
                    Button("Remove demo inbox", role: .destructive, action: removeDemo)
                } message: {
                    Text("The sample mail goes away. Your own accounts aren't touched.")
                }
            }
        } header: {
            Text("Accounts")
        }
        .settingsSectionStyle()
    }

    private func removeDemo() {
        guard let demo = store.accounts.first(where: \.isDemo) else { return }
        Task {
            await store.removeAccount(id: demo.id)
            Haptics.success()
            closeIfEmpty()
        }
    }

    /// With no accounts left the app goes back to the welcome screen, so Settings steps aside.
    private func closeIfEmpty() {
        if !store.hasAccounts { app.isSettingsPresented = false }
    }
}
#endif

/// One account's details: name, signature, colour, servers, and removing it.
struct SettingsAccountDetail: View {
    let accountID: String
    var onRemoved: () -> Void = {}

    @Environment(MailStore.self) private var store
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var draft: AccountConfig?
    @State private var confirmsRemoval = false
    @State private var isRemoving = false

    var body: some View {
        Group {
            if let account = Binding($draft) {
                editor(account)
            } else {
                EmptyStateView(systemImage: "person.crop.circle.badge.xmark", title: "This account is gone", message: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if os(iOS)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if draft == nil { draft = store.account(id: accountID) }
        }
        .task(id: draft) { await saveSoon() }
        .onDisappear { save() }
    }

    private func editor(_ account: Binding<AccountConfig>) -> some View {
        Form {
            Section {
                HStack(spacing: InkSpace.m) {
                    AccountDot(colorIndex: account.wrappedValue.colorIndex, size: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.wrappedValue.emailAddress)
                            .font(InkFont.headline)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(OnboardingProvider.info(for: account.wrappedValue.provider).name)
                            .font(.subheadline)
                            .foregroundStyle(Ink.secondary)
                    }
                }
                .padding(.vertical, InkSpace.xs)
                .animation(InkMotion.snappy, value: account.wrappedValue.colorIndex)
            }
            .settingsSectionStyle()

            Section {
                TextField("Your name", text: account.displayName)
                    #if os(iOS)
                    .textContentType(.name)
                    #endif
            } header: {
                Text("Name")
            } footer: {
                Text("Shown to people you email.")
            }
            .settingsSectionStyle()

            Section {
                TextEditor(text: signatureBinding(account))
                    .font(.body)
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Signature")
            } footer: {
                Text("Added below new messages and replies from this account.")
            }
            .settingsSectionStyle()

            Section {
                SettingsAccountColorPicker(selection: account.colorIndex)
            } header: {
                Text("Colour")
            } footer: {
                Text("A dot in this colour marks the account's mail in All Inboxes.")
            }
            .settingsSectionStyle()

            Section {
                LabeledContent("Incoming", value: Self.serverLine(account.wrappedValue.imap))
                LabeledContent("Outgoing", value: Self.serverLine(account.wrappedValue.smtp))
                LabeledContent("Sign-in", value: Self.signInMethod(account.wrappedValue))
            } header: {
                Text("Servers")
            }
            .settingsSectionStyle()

            Section {
                Button(role: .destructive) {
                    confirmsRemoval = true
                } label: {
                    Text("Remove account")
                }
                .disabled(isRemoving)
                .confirmationDialog("Remove \(account.wrappedValue.emailAddress)?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                    Button("Remove account", role: .destructive, action: remove)
                } message: {
                    Text("Its mail is cleared from this device. Nothing is deleted from the server.")
                }
            } footer: {
                Text("Removes the account, its password and its mail from this device. Nothing changes on the server.")
            }
            .settingsSectionStyle()
        }
        .formStyle(.grouped)
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Ink.background)
        #endif
    }

    private func signatureBinding(_ account: Binding<AccountConfig>) -> Binding<String> {
        Binding(
            get: { account.wrappedValue.signature ?? "" },
            set: { account.wrappedValue.signature = $0.isEmpty ? nil : $0 }
        )
    }

    private static func serverLine(_ server: ServerConfig) -> String {
        "\(server.host):\(server.port) · \(server.security.onboardingTitle)"
    }

    private static func signInMethod(_ account: AccountConfig) -> String {
        switch account.authMethod {
        case .password:
            return account.provider == .other ? "Password" : "App password"
        case .oauth2:
            return account.oauthProvider == .google ? "Sign in with Google" : "Sign in with Microsoft"
        }
    }

    // MARK: Saving

    /// Saves a moment after typing stops, so every keystroke doesn't hit the disk.
    private func saveSoon() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        save()
    }

    private func save() {
        guard !isRemoving, var updated = draft, let current = store.account(id: accountID) else { return }
        let name = updated.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.displayName = name.isEmpty ? current.displayName : name
        if let signature = updated.signature, signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.signature = nil
        }
        guard updated != current else { return }
        store.updateAccount(updated)
    }

    private func remove() {
        guard !isRemoving else { return }
        isRemoving = true
        let id = accountID
        Task {
            await store.removeAccount(id: id)
            Haptics.success()
            #if os(iOS)
            dismiss()
            #endif
            onRemoved()
        }
    }
}

/// The account colour swatches.
struct SettingsAccountColorPicker: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: InkSpace.m) {
            ForEach(AccountPalette.colors.indices, id: \.self) { index in
                let isSelected = index == selection
                Button {
                    guard !isSelected else { return }
                    Haptics.tick()
                    withAnimation(InkMotion.bouncy) { selection = index }
                } label: {
                    Circle()
                        .fill(AccountPalette.color(index))
                        .frame(width: 26, height: 26)
                        .padding(3)
                        .overlay(Circle().stroke(Ink.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 1.5))
                        .scaleEffect(isSelected ? 1.08 : 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(index + 1)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, InkSpace.xs)
        .animation(InkMotion.bouncy, value: selection)
    }
}
