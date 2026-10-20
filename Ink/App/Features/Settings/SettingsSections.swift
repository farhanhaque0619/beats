import SwiftUI
import InkCore
#if canImport(UIKit)
import UIKit
#endif

// Sections shared by the iPhone Form and the Mac Settings tabs.

extension View {
    /// Grouped rows on the theme's surface on iPhone; the system look on Mac.
    func settingsSectionStyle() -> some View {
        #if os(iOS)
        return self
            .listRowBackground(Ink.surface)
            .listRowSeparatorTint(Ink.hairline)
        #else
        return self
        #endif
    }
}

/// A segmented choice: title above the control on iPhone, beside it on Mac.
struct SettingsSegmentedRow<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder var options: Options

    var body: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: InkSpace.s) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
            Picker(title, selection: $selection) { options }
                .pickerStyle(.segmented)
                .labelsHidden()
        }
        .padding(.vertical, InkSpace.xs)
        #else
        Picker(title, selection: $selection) { options }
            .pickerStyle(.segmented)
        #endif
    }
}

// MARK: - Appearance

struct SettingsAppearanceSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            SettingsSegmentedRow(title: "Theme", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            SettingsAccentRow()
            SettingsSegmentedRow(title: "Reading font", selection: $settings.readingFont) {
                ForEach(ReadingFont.allCases) { font in
                    Text(font.title).tag(font)
                }
            }
            SettingsSegmentedRow(title: "List density", selection: $settings.density.animation(InkMotion.smooth)) {
                ForEach(ListDensity.allCases) { density in
                    Text(density.title).tag(density)
                }
            }
            SettingsSegmentedRow(title: "Preview lines", selection: $settings.previewLines.animation(InkMotion.smooth)) {
                Text("None").tag(0)
                Text("1 line").tag(1)
                Text("2 lines").tag(2)
            }
            Toggle("Avatars", isOn: $settings.showAvatars.animation(InkMotion.smooth))
        } header: {
            Text("Appearance")
        }
        .settingsSectionStyle()
    }
}

/// The accent swatches. Picking one recolours the whole app with a spring.
struct SettingsAccentRow: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: InkSpace.s) {
            Text("Accent")
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
            swatches
        }
        .padding(.vertical, InkSpace.xs)
        #else
        LabeledContent("Accent") { swatches }
        #endif
    }

    private var swatches: some View {
        HStack(spacing: InkSpace.m) {
            ForEach(AccentTint.allCases) { tint in
                let isSelected = tint == settings.accent
                Button {
                    guard !isSelected else { return }
                    Haptics.tick()
                    withAnimation(InkMotion.smooth) { settings.accent = tint }
                } label: {
                    Circle()
                        .fill(tint.color)
                        .frame(width: 28, height: 28)
                        .overlay {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(tint.onColor)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .padding(3)
                        .overlay(Circle().stroke(Ink.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 1.5))
                        .scaleEffect(isSelected ? 1.06 : 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tint.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(InkMotion.bouncy, value: settings.accent)
    }
}

// MARK: - Inbox

struct SettingsInboxSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MailStore.self) private var store

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Focus & Other", isOn: $settings.focusedInbox.animation(InkMotion.smooth))
                .onChange(of: settings.focusedInbox) { _, _ in
                    settings.apply(to: store)
                }
            Toggle("Mark as read when opened", isOn: $settings.markReadOnOpen)
            #if os(iOS)
            Picker("After archiving", selection: $settings.advanceToNext) {
                Text("Open the next one").tag(true)
                Text("Go back to the list").tag(false)
            }
            #endif
        } header: {
            Text("Inbox")
        } footer: {
            Text("Focus keeps mail from people up top. Newsletters and notifications wait in Other.")
        }
        .settingsSectionStyle()
    }
}

// MARK: - Sending

struct SettingsSendingSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MailStore.self) private var store

    private static let delays = [5, 10, 20, 30]

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Undo Send", selection: $settings.undoSendDelay) {
                Text("Off").tag(0)
                ForEach(Self.delays, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            }
            .onChange(of: settings.undoSendDelay) { _, _ in
                settings.apply(to: store)
            }
        } header: {
            Text("Sending")
        } footer: {
            Text(footer)
        }
        .settingsSectionStyle()
    }

    private var footer: String {
        if settings.undoSendDelay == 0 { return "Messages leave as soon as you tap Send." }
        return "Messages wait \(settings.undoSendDelay) seconds before they leave, with Undo at the bottom of the screen."
    }
}

// MARK: - Privacy

struct SettingsPrivacySection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Load remote images", isOn: $settings.loadRemoteImages)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Senders hide tiny invisible images in emails to learn when, where and how often you open them. With this off, Ink blocks every remote image and counts the trackers it caught. You can still load images for one message at a time.")
        }
        .settingsSectionStyle()
    }
}

// MARK: - Notifications

struct SettingsNotificationsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var wasDenied = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("New mail", isOn: $settings.notificationsEnabled)
                .onChange(of: settings.notificationsEnabled) { _, isOn in
                    if isOn { requestPermission() }
                }
            #if os(iOS)
            if wasDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(url) }
            }
            #endif
        } header: {
            Text("Notifications")
        } footer: {
            Text(footer)
        }
        .settingsSectionStyle()
    }

    /// Asks iOS / macOS for permission; switches back off when the answer is no.
    private func requestPermission() {
        let settings = self.settings
        Task {
            let granted = await Notifier.requestAuthorization()
            withAnimation(InkMotion.snappy) {
                wasDenied = !granted
                if !granted { settings.notificationsEnabled = false }
            }
        }
    }

    private var footer: String {
        if wasDenied {
            #if os(iOS)
            return "Notifications are off for Ink. Allow them in Settings, then turn this on again."
            #else
            return "Notifications are off for Ink. Allow them in System Settings, Notifications, then turn this on again."
            #endif
        }
        #if os(iOS)
        return "New mail from people, not newsletters. Ink checks in the background when iOS allows, so alerts can arrive a few minutes late."
        #else
        return "New mail from people, not newsletters."
        #endif
    }
}

// MARK: - About

struct SettingsAboutSection: View {
    var body: some View {
        Section {
            LabeledContent("Version", value: Self.version)
            Text("Your mail goes straight from your device to your provider. Ink has no servers.")
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = OnboardingLinks.researchNotes {
                Link(destination: url) {
                    Label("Research notes", systemImage: "book")
                }
            }
            if let url = OnboardingLinks.accountsGuide {
                Link(destination: url) {
                    Label("Connecting your email", systemImage: "questionmark.circle")
                }
            }
        } header: {
            Text("About")
        }
        .settingsSectionStyle()
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}
