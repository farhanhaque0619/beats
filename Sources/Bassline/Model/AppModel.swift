import AppKit
import Combine
import CoreAudio
import Foundation

enum EngineStatus: Equatable {
    case idle
    case running(deviceName: String)
    case failed(String)
    case unsupported
}

enum SettingsKey {
    static let limiter = "limiterEnabled"
    static let showInDock = "showInDock"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let openWindowAtLaunch = "openWindowAtLaunch"
    static let autoCheckUpdates = "autoCheckUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let dismissedPermissionNote = "hasDismissedPermissionNote"
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [DeviceProfile] = []
    @Published var selectedProfileID: String?
    @Published private(set) var currentOutput: OutputDevice?
    @Published private(set) var connectedDevices: [OutputDevice] = []
    @Published private(set) var engineStatus: EngineStatus = .idle

    let engine = SystemEQEngine()
    private let storageKey = "profiles.v1"
    private var saveWork: DispatchWorkItem?

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.limiter: true,
            SettingsKey.showInDock: true,
            SettingsKey.showMenuBarIcon: true,
            SettingsKey.openWindowAtLaunch: true,
            SettingsKey.autoCheckUpdates: true,
        ])

        profiles = Self.loadProfiles(key: storageKey)
        selectedProfileID = profiles.first?.id

        HAL.observeSystem(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            Task { @MainActor in self?.outputDidChange() }
        }
        HAL.observeSystem(kAudioHardwarePropertyDevices) { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.stop() }
        }

        refreshDevices()
        outputDidChange()
        if let active = activeProfile { selectedProfileID = active.id }
    }

    // MARK: - Queries

    /// The profile used for whatever the Mac is playing through right now.
    var activeProfile: DeviceProfile? {
        guard let currentOutput else { return nil }
        return profiles.first { $0.id == profileID(for: currentOutput) }
    }

    var knownProfiles: [DeviceProfile] { profiles.filter { $0.kind != .other } }

    /// Other outputs that are plugged in or paired right now.
    var connectedOtherProfiles: [DeviceProfile] {
        profiles.filter { $0.kind == .other && (isConnected($0) || isCurrentOutput($0)) }
    }

    /// Other outputs that aren't connected but have custom settings worth keeping.
    var savedOtherProfiles: [DeviceProfile] {
        profiles.filter { $0.kind == .other && !isConnected($0) && !isCurrentOutput($0) && !$0.isFlat }
    }

    var limiterEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.limiter) }

    func profile(id: String?) -> DeviceProfile? {
        profiles.first { $0.id == id }
    }

    func isCurrentOutput(_ profile: DeviceProfile) -> Bool {
        activeProfile?.id == profile.id
    }

    func isConnected(_ profile: DeviceProfile) -> Bool {
        device(for: profile) != nil
    }

    func device(for profile: DeviceProfile) -> OutputDevice? {
        connectedDevices.first { profileID(for: $0) == profile.id }
    }

    func isProcessing(_ profile: DeviceProfile) -> Bool {
        isCurrentOutput(profile) && engine.isRunning
    }

    func profile(for device: OutputDevice) -> DeviceProfile? {
        profile(id: profileID(for: device))
    }

    // MARK: - Editing

    func update(_ id: String, _ change: (inout DeviceProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let wasRunning = shouldProcess(profiles[index])
        change(&profiles[index])
        scheduleSave()

        guard profiles[index].id == activeProfile?.id else { return }
        if wasRunning != shouldProcess(profiles[index]) {
            applyEngineState()
        } else {
            pushSettings()
        }
    }

    func setGain(_ gain: Double, band: Int, for id: String) {
        update(id) { profile in
            profile.gains[band] = (gain * 10).rounded() / 10
            profile.presetName = "Custom"
        }
    }

    func apply(_ preset: EQPreset, to id: String) {
        update(id) { $0.apply(preset) }
    }

    func reset(_ id: String) {
        update(id) { profile in
            let fresh = profile.kind == .other
                ? DeviceProfile.other(uid: "", name: profile.displayName)
                : DeviceProfile.standard(for: profile.kind)
            profile.gains = fresh.gains
            profile.bassBoost = 0
            profile.preampDB = 0
            profile.preventsClipping = true
            profile.presetName = fresh.presetName
        }
    }

    func resetAllDevices() {
        for id in profiles.map(\.id) { reset(id) }
    }

    /// Removes settings for devices that aren't connected (the three tuned devices stay).
    func forgetDisconnectedDevices() {
        profiles.removeAll { $0.kind == .other && !isConnected($0) && !isCurrentOutput($0) }
        if profile(id: selectedProfileID) == nil { selectedProfileID = activeProfile?.id ?? profiles.first?.id }
        scheduleSave()
    }

    func forget(_ id: String) {
        guard let profile = profile(id: id), profile.kind == .other, !isConnected(profile) else { return }
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id { selectedProfileID = activeProfile?.id ?? profiles.first?.id }
        scheduleSave()
    }

    /// Switches the Mac's sound output to this device.
    func playThrough(_ profile: DeviceProfile) {
        guard let device = device(for: profile) else { return }
        HAL.setDefaultOutputDevice(device.id)
    }

    func playThrough(_ device: OutputDevice) {
        HAL.setDefaultOutputDevice(device.id)
    }

    func retry() {
        applyEngineState()
    }

    /// Re-sends settings to the audio thread after a global setting changes.
    func settingsDidChange() {
        pushSettings()
    }

    // MARK: - Devices

    private func profileID(for device: OutputDevice) -> String {
        let kind = DeviceKind.detect(deviceName: device.name)
        return kind == .other ? "device:" + device.uid : kind.rawValue
    }

    private func refreshDevices() {
        connectedDevices = HAL.outputDevices()
        var added = false
        for device in connectedDevices where profile(for: device) == nil {
            profiles.append(.other(uid: device.uid, name: device.name, transportType: device.transportType))
            added = true
        }
        if added { scheduleSave() }
    }

    private func outputDidChange() {
        let device = HAL.defaultOutputDevice()
        guard device != currentOutput || !engineMatches(device) else { return }
        currentOutput = device
        refreshDevices()
        applyEngineState()
    }

    private func engineMatches(_ device: OutputDevice?) -> Bool {
        engine.runningDeviceUID == device?.uid && (activeProfile.map(shouldProcess) ?? false)
    }

    // MARK: - Engine

    private func shouldProcess(_ profile: DeviceProfile) -> Bool {
        profile.isEnabled && !profile.isFlat
    }

    private func applyEngineState(isRetry: Bool = false) {
        guard SystemEQEngine.isSupported else {
            engineStatus = .unsupported
            return
        }
        guard let device = currentOutput, let profile = activeProfile, shouldProcess(profile) else {
            engine.stop()
            engineStatus = .idle
            return
        }

        do {
            pushSettings()
            try engine.start(on: device)
            pushSettings() // the device's real sample rate is known now
            engineStatus = .running(deviceName: profile.displayName)
        } catch {
            engineStatus = .failed(error.localizedDescription)
            // Bluetooth devices sometimes need a moment after connecting.
            if !isRetry {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.currentOutput == device else { return }
                    self.applyEngineState(isRetry: true)
                }
            }
        }
    }

    private func pushSettings() {
        guard let profile = activeProfile else { return }
        let gain = pow(10, profile.effectivePreampDB / 20)
        engine.processor.update(
            filters: profile.filters(sampleRate: engine.sampleRate),
            outputGain: gain,
            limiter: limiterEnabled,
            sampleRate: engine.sampleRate
        )
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = profiles
        let key = storageKey
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private static func loadProfiles(key: String) -> [DeviceProfile] {
        var stored: [DeviceProfile] = []
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([DeviceProfile].self, from: data) {
            stored = decoded.filter { $0.gains.count == EQBands.frequencies.count }
        }
        let known = [DeviceKind.beatsStudioPro, .airPodsPro2, .marshallActon3].map { kind in
            stored.first { $0.id == kind.rawValue } ?? .standard(for: kind)
        }
        // Version 1.0 saved other devices switched off and without an icon.
        let others = stored.filter { $0.kind == .other }.map { profile -> DeviceProfile in
            var profile = profile
            if profile.iconName == nil {
                profile.iconName = DeviceKind.symbol(forName: profile.displayName, transportType: 0)
                if profile.isFlat { profile.isEnabled = true }
            }
            return profile
        }
        return known + others
    }
}
