import SwiftUI
import InkCore

/// Settings: a themed grouped Form in a sheet on iPhone, tabs in the Settings window on Mac.
struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        SettingsMacRoot()
        #else
        SettingsPhoneRoot()
        #endif
    }
}

#if os(iOS)
private struct SettingsPhoneRoot: View {
    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.inkAccent) private var accent
    @Environment(\.dismiss) private var dismiss
    @State private var isAddingAccount = false

    var body: some View {
        NavigationStack {
            Form {
                SettingsAccountsSection(onAddAccount: { isAddingAccount = true })
                SettingsAppearanceSection()
                SettingsInboxSection()
                SettingsSwipesSection()
                SettingsSendingSection()
                SettingsPrivacySection()
                SettingsNotificationsSection()
                SettingsAboutSection()
            }
            .scrollContentBackground(.hidden)
            .background(Ink.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $isAddingAccount) {
            AddAccountFlow()
                .environment(app)
                .environment(store)
                .environment(settings)
                .environment(\.inkAccent, accent)
                .tint(accent)
        }
    }

    private func close() {
        app.isSettingsPresented = false
        dismiss()
    }
}
#endif
