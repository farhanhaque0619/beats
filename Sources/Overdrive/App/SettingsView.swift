import AppKit
import Darwin
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            SoundSettings()
                .tabItem { Label("Sound", systemImage: "slider.vertical.3") }
            DisplaySettings()
                .tabItem { Label("Display", systemImage: "sun.max") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 500)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.showInDock) private var showInDock = true
    @AppStorage(SettingsKey.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(SettingsKey.openWindowAtLaunch) private var openWindowAtLaunch = true
    @AppStorage(SettingsKey.accentStyle) private var accentStyle = AccentStyle.system.rawValue
    @AppStorage(SettingsKey.menuBarStats) private var menuBarStats = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Overdrive at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if loginItemNeedsApproval {
                    HStack {
                        Text("Allow Overdrive in Login Items to finish turning this on.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginItemError {
                    Text(loginItemError).foregroundStyle(.orange)
                }
                Toggle("Show the window when Overdrive opens", isOn: $openWindowAtLaunch)
            } header: {
                Text("Startup")
            } footer: {
                Text("With login enabled, your EQ is active as soon as you sign in.")
            }

            Section {
                Picker("Accent colour", selection: $accentStyle) {
                    ForEach(AccentStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                Toggle("Show CPU and temperature in the menu bar", isOn: $menuBarStats)
                    .disabled(!showMenuBarIcon)
                Toggle("Show in menu bar", isOn: $showMenuBarIcon)
                    .disabled(!showInDock)
                Toggle("Show in Dock", isOn: $showInDock)
                    .disabled(!showMenuBarIcon)
                    .onChange(of: showInDock) { _, visible in
                        NSApp.setActivationPolicy(visible ? .regular : .accessory)
                        if !visible { NSApp.activate(ignoringOtherApps: true) }
                    }
            } header: {
                Text("Appearance")
            } footer: {
                Text("System Accent follows the colour you chose in System Settings. Overdrive keeps running in the menu bar when you close its window, so your EQ and display settings stay on. The menu bar or the Dock always stays on so you can get back to it.")
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = "Couldn’t change the login item: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        loginItemNeedsApproval = status == .requiresApproval
        let isOn = status == .enabled || status == .requiresApproval
        if launchAtLogin != isOn { launchAtLogin = isOn }
    }
}

// MARK: - Sound

private struct SoundSettings: View {
    @EnvironmentObject private var model: SoundModel
    @AppStorage(SettingsKey.limiter) private var limiterEnabled = true
    @AppStorage(SettingsKey.showSpectrum) private var showSpectrum = true
    @AppStorage(SettingsKey.dismissedPermissionNote) private var dismissedPermissionNote = false
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $limiterEnabled) {
                    Text("Soft limiter")
                    Text("Rounds off the loudest peaks so heavy bass never crackles.")
                }
                .onChange(of: limiterEnabled) { _, _ in model.settingsDidChange() }
                Toggle(isOn: $showSpectrum) {
                    Text("Live spectrum")
                    Text("Shows the music’s frequencies behind the EQ curve while the window is open.")
                }
            } header: {
                Text("Processing")
            } footer: {
                Text("Overdrive only processes audio when the current device’s EQ is on and not flat. Otherwise sound goes straight to the device.")
            }

            Section("Devices") {
                LabeledContent("Saved devices", value: "\(model.profiles.count)")
                LabeledContent("Saved presets", value: "\(model.userPresets.count)")
                HStack {
                    Button("Forget Disconnected Devices") {
                        withAnimation(.smooth) { model.forgetDisconnectedDevices() }
                    }
                    Spacer()
                    Button("Reset All EQ…", role: .destructive) { confirmingReset = true }
                }
            }

            Section("Permissions") {
                LabeledContent("System audio access") {
                    Button("Open Privacy Settings", action: PrivacySettings.open)
                }
                if dismissedPermissionNote {
                    Button("Show the permission tip again") { dismissedPermissionNote = false }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset the EQ on every device?", isPresented: $confirmingReset) {
            Button("Reset All", role: .destructive) {
                withAnimation(.smooth(duration: 0.5)) { model.resetAllDevices() }
            }
        } message: {
            Text("Each device goes back to its recommended starting point.")
        }
    }
}

// MARK: - Display

private struct DisplaySettings: View {
    @EnvironmentObject private var displays: DisplayManager
    @AppStorage(SettingsKey.boostBatteryFloor) private var batteryFloor = 20

    var body: some View {
        Form {
            Section {
                Picker("Pause on battery below", selection: $batteryFloor) {
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                    Text("30%").tag(30)
                    Text("50%").tag(50)
                    Text("Never").tag(0)
                }
                LabeledContent("Maximum boost", value: "+\(Int(((DisplayManager.maxBoostFactor - 1) * 100).rounded()))%")
                LabeledContent("Status", value: displays.canBoost
                    ? (displays.boostEnabled ? (displays.boostPausedReason ?? "On") : "Off")
                    : "This Mac’s displays don’t have HDR headroom")
            } header: {
                Text("Extra Brightness")
            } footer: {
                Text("Extra Brightness always pauses when macOS reports your Mac is running hot, and turns off the moment Overdrive quits. It uses more power, so it can also pause when the battery runs low.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @EnvironmentObject private var updater: UpdateChecker
    @AppStorage(SettingsKey.autoCheckUpdates) private var autoCheck = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed version", value: "\(updater.currentVersion) (\(updater.currentBuild))")
                Toggle("Check for updates automatically", isOn: $autoCheck)
                LabeledContent("Last checked") {
                    Text(updater.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                }
            } footer: {
                Text("Overdrive checks its GitHub releases once a day.")
            }

            Section {
                statusView
                    .animation(.smooth(duration: 0.3), value: updater.state)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusView: some View {
        switch updater.state {
        case .idle:
            checkRow(message: "Check to see if a newer version is available.")
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            }
        case .upToDate:
            checkRow(message: "Overdrive is up to date.", symbol: "checkmark.circle.fill", color: .green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                checkRow(message: message, symbol: "exclamationmark.triangle.fill", color: .orange)
                Link("Open the Releases Page", destination: UpdateChecker.releasesURL)
            }
        case .available(let release):
            VStack(alignment: .leading, spacing: 10) {
                Label("Overdrive \(release.version) is available", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                if !release.notes.isEmpty {
                    Text(release.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
                HStack {
                    Button("Install and Relaunch") {
                        Task { await updater.install(release) }
                    }
                    .keyboardShortcut(.defaultAction)
                    Link("Download DMG", destination: release.dmgURL)
                }
            }
        case .installing(let release):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Installing Overdrive \(release.version). It will reopen by itself.")
            }
        }
    }

    private func checkRow(message: String, symbol: String? = nil, color: Color = .secondary) -> some View {
        HStack {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(color)
            }
            Text(message)
            Spacer()
            Button("Check Now") { Task { await updater.check() } }
        }
    }
}

// MARK: - About and performance

private struct AboutSettings: View {
    @EnvironmentObject private var model: SoundModel
    @EnvironmentObject private var updater: UpdateChecker
    @StateObject private var sampler = PerformanceSampler()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Overdrive").font(.title2.weight(.semibold))
                        Text("Version \(updater.currentVersion)").foregroundStyle(.secondary)
                        Link("View on GitHub", destination: UpdateChecker.repositoryURL)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Status", value: model.engine.isRunning ? "Equalizing" : "Idle, not processing audio")
                LabeledContent("Overdrive CPU use", value: String(format: "%.1f%%", sampler.cpuPercent))
                LabeledContent("EQ processing", value: model.engine.isRunning
                    ? String(format: "%.2f%% of the audio time budget", model.engine.processor.processingLoad * 100)
                    : "Off")
                LabeledContent("Memory", value: ByteCountFormatter.string(fromByteCount: Int64(sampler.memoryBytes), countStyle: .memory))
                if model.engine.isRunning {
                    LabeledContent("Sample rate", value: String(format: "%.1f kHz", model.engine.sampleRate / 1000))
                    LabeledContent("Added delay", value: String(format: "about %.0f ms", model.engine.addedLatency * 1000))
                }
            } header: {
                Text("Performance")
            } footer: {
                Text("Updated every second. CPU use is a share of one core and includes this Settings window.")
            }
        }
        .formStyle(.grouped)
        .onAppear { sampler.start() }
        .onDisappear { sampler.stop() }
    }
}

/// Samples this process's CPU time and memory footprint once a second.
@MainActor
private final class PerformanceSampler: ObservableObject {
    @Published var cpuPercent: Double = 0
    @Published var memoryBytes: UInt64 = 0

    private var timer: Timer?
    private var lastCPU: Double = 0
    private var lastWall: Double = 0

    func start() {
        sample()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let wall = ProcessInfo.processInfo.systemUptime
        if lastWall > 0, wall > lastWall {
            cpuPercent = max(0, (cpu - lastCPU) / (wall - lastWall) * 100)
        }
        lastCPU = cpu
        lastWall = wall
        memoryBytes = Self.memoryFootprint()
    }

    private static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
