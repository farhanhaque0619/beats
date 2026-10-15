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
    static let showSpectrum = "showSpectrum"
    static let extraOutputs = "extraOutputUIDs"
    static let outputDelays = "outputDelaysMs"
    static let userPresets = "userPresets.v1"
}

@MainActor
final class AppModel: ObservableObject {
    /// Sidebar selection for the Multi-Output page.
    static let groupSelectionID = "multi-output"
    static let maxGroupSize = EQProcessor.maxRoutes

    @Published private(set) var profiles: [DeviceProfile] = []
    @Published var selectedProfileID: String?
    @Published private(set) var currentOutput: OutputDevice?
    @Published private(set) var connectedDevices: [OutputDevice] = []
    @Published private(set) var engineStatus: EngineStatus = .idle

    /// Devices that play along with the Mac's sound output (by UID).
    @Published private(set) var extraOutputUIDs: [String] = []
    /// Sync delay per device UID, in milliseconds.
    @Published private(set) var outputDelays: [String: Double] = [:]
    /// While true (Hold to Compare), every device plays the original sound.
    @Published private(set) var isBypassed = false
    @Published private(set) var userPresets: [EQPreset] = []

    let engine = SystemEQEngine()
    private let storageKey = "profiles.v1"
    private var saveWork: DispatchWorkItem?
    private var pendingStop: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            SettingsKey.limiter: true,
            SettingsKey.showInDock: true,
            SettingsKey.showMenuBarIcon: true,
            SettingsKey.openWindowAtLaunch: true,
            SettingsKey.autoCheckUpdates: true,
            SettingsKey.showSpectrum: true,
        ])

        profiles = Self.loadProfiles(key: storageKey)
        extraOutputUIDs = defaults.stringArray(forKey: SettingsKey.extraOutputs) ?? []
        outputDelays = (defaults.dictionary(forKey: SettingsKey.outputDelays) as? [String: Double]) ?? [:]
        if let data = defaults.data(forKey: SettingsKey.userPresets),
           let presets = try? JSONDecoder().decode([EQPreset].self, from: data) {
            userPresets = presets
        }
        selectedProfileID = profiles.first?.id

        HAL.observeSystem(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            Task { @MainActor in self?.outputDidChange() }
        }
        HAL.observeSystem(kAudioHardwarePropertyDevices) { [weak self] in
            Task { @MainActor in self?.devicesDidChange() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.stop() }
        }

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

    func profile(for device: OutputDevice) -> DeviceProfile? {
        profile(id: profileID(for: device))
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

    /// True while the device is part of what the Mac is playing through.
    func isPlaying(_ profile: DeviceProfile) -> Bool {
        activeGroup.contains { profileID(for: $0) == profile.id }
    }

    func isProcessing(_ profile: DeviceProfile) -> Bool {
        isPlaying(profile) && engine.isRunning && shouldProcess(profile) && !isBypassed
    }

    /// The meter/route index for a profile's device in the running engine.
    func route(for profile: DeviceProfile) -> Int? {
        engine.routes.firstIndex { route in
            connectedDevices.first { $0.uid == route.deviceUID }.map { profileID(for: $0) } == profile.id
        }
    }

    func route(for device: OutputDevice) -> Int? {
        engine.routes.firstIndex { $0.deviceUID == device.uid }
    }

    // MARK: - Presets

    func presets(for profile: DeviceProfile) -> [EQPreset] {
        profile.presets + userPresets
    }

    @discardableResult
    func saveUserPreset(named rawName: String, from id: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let profile = profile(id: id) else { return false }
        let taken = Set((profile.presets + userPresets).map { $0.name.lowercased() })
        guard !taken.contains(name.lowercased()), name != "Custom" else { return false }
        userPresets.append(EQPreset(name: name, gains: profile.gains, bassBoost: profile.bassBoost, isCustom: true))
        saveUserPresets()
        update(id) { $0.presetName = name }
        return true
    }

    func deleteUserPreset(_ preset: EQPreset) {
        userPresets.removeAll { $0.name == preset.name }
        saveUserPresets()
        for profile in profiles where profile.presetName == preset.name {
            update(profile.id) { $0.presetName = "Custom" }
        }
    }

    // MARK: - Editing

    func update(_ id: String, _ change: (inout DeviceProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[index])
        scheduleSave()
        if isPlaying(profiles[index]) { applyEngineState() }
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

    /// Keyboard shortcut: EQ on/off for whatever is playing.
    func toggleActiveEQ() {
        guard let id = activeProfile?.id else { return }
        update(id) { $0.isEnabled.toggle() }
    }

    /// Keyboard shortcut: nudge Bass Boost on whatever is playing.
    func nudgeBassBoost(by step: Double) {
        guard let id = activeProfile?.id else { return }
        update(id) { profile in
            profile.bassBoost = min(max(profile.bassBoost + step, EQBands.bassBoostRange.lowerBound), EQBands.bassBoostRange.upperBound)
            if !profile.isEnabled { profile.isEnabled = true }
        }
    }

    /// Removes settings for devices that aren't connected (the three tuned devices stay).
    func forgetDisconnectedDevices() {
        profiles.removeAll { $0.kind == .other && !isConnected($0) && !isCurrentOutput($0) }
        if selectedProfileID != Self.groupSelectionID, profile(id: selectedProfileID) == nil {
            selectedProfileID = activeProfile?.id ?? profiles.first?.id
        }
        scheduleSave()
    }

    func forget(_ id: String) {
        guard let profile = profile(id: id), profile.kind == .other, !isConnected(profile) else { return }
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id { selectedProfileID = activeProfile?.id ?? profiles.first?.id }
        scheduleSave()
    }

    /// Hold to Compare: play the original sound while `bypassed` is true.
    func setBypass(_ bypassed: Bool) {
        guard isBypassed != bypassed else { return }
        isBypassed = bypassed
        pushSettings()
    }

    /// Switches the Mac's sound output to this device.
    func playThrough(_ profile: DeviceProfile) {
        guard let device = device(for: profile) else { return }
        playThrough(device)
    }

    func playThrough(_ device: OutputDevice) {
        HAL.setDefaultOutputDevice(device.id)
    }

    func retry() {
        applyEngineState(forceRestart: true)
    }

    /// Re-sends settings to the audio thread after a global setting changes.
    func settingsDidChange() {
        pushSettings()
    }

    // MARK: - Multi-Output

    /// Everything the Mac is playing through: the sound output first, then any extras.
    var activeGroup: [OutputDevice] {
        guard let currentOutput else { return [] }
        let extras = extraOutputUIDs.compactMap { uid in
            connectedDevices.first { $0.uid == uid && $0.uid != currentOutput.uid }
        }
        return Array(([currentOutput] + extras).prefix(Self.maxGroupSize))
    }

    var isGroupActive: Bool { activeGroup.count > 1 }

    func isInGroup(_ device: OutputDevice) -> Bool {
        device.uid == currentOutput?.uid || extraOutputUIDs.contains(device.uid)
    }

    func canAddToGroup(_ device: OutputDevice) -> Bool {
        isInGroup(device) || activeGroup.count < Self.maxGroupSize
    }

    /// Adds or removes a device from Multi-Output. The sound output itself always plays.
    func toggleGroupMember(_ device: OutputDevice) {
        guard device.uid != currentOutput?.uid else { return }
        if let index = extraOutputUIDs.firstIndex(of: device.uid) {
            extraOutputUIDs.remove(at: index)
        } else {
            guard activeGroup.count < Self.maxGroupSize else { return }
            extraOutputUIDs.append(device.uid)
            if outputDelays[device.uid] == nil { autoSync(save: false) }
        }
        saveGroup()
        applyEngineState()
    }

    func stopGroup() {
        extraOutputUIDs.removeAll()
        saveGroup()
        applyEngineState()
    }

    func delay(for device: OutputDevice) -> Double {
        outputDelays[device.uid] ?? 0
    }

    func setDelay(_ milliseconds: Double, for device: OutputDevice) {
        outputDelays[device.uid] = (milliseconds).rounded()
        saveGroup()
        pushSettings()
    }

    /// Delays the faster devices so every device plays in time with the slowest one,
    /// using the latency each driver reports (Bluetooth includes its codec delay).
    func autoSync(save: Bool = true) {
        let members = currentOutput.map { [$0] } ?? []
        let devices = members + extraOutputUIDs.compactMap { uid in connectedDevices.first { $0.uid == uid } }
        guard !devices.isEmpty else { return }
        let latencies = devices.map { ($0.uid, HAL.outputLatency($0.id)) }
        let slowest = latencies.map(\.1).max() ?? 0
        for (uid, latency) in latencies {
            outputDelays[uid] = ((slowest - latency) * 1000).rounded()
        }
        if save { saveGroup() }
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
        currentOutput = HAL.defaultOutputDevice()
        refreshDevices()
        applyEngineState()
    }

    private func devicesDidChange() {
        refreshDevices()
        // A device in the group may have come or gone.
        applyEngineState()
    }

    // MARK: - Engine

    private func shouldProcess(_ profile: DeviceProfile) -> Bool {
        profile.isEnabled && !profile.isFlat
    }

    /// Starts, restarts, or stops the engine to match what should be playing. Cheap to call
    /// repeatedly: when nothing changed it only refreshes the filter settings.
    private func applyEngineState(isRetry: Bool = false, forceRestart: Bool = false) {
        guard SystemEQEngine.isSupported else {
            engineStatus = .unsupported
            return
        }
        let group = activeGroup
        let needsEngine = group.count > 1 || (activeProfile.map(shouldProcess) ?? false)
        pendingStop?.cancel()
        pendingStop = nil
        guard needsEngine, let primary = group.first else {
            if engine.isRunning, engine.runningDeviceUIDs == group.map(\.uid) {
                // Same device, EQ just went flat or off: pass audio through for a moment
                // before stopping, so dragging a band through 0 dB doesn't restart the engine.
                pushSettings()
                pendingStop = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let self, !Task.isCancelled else { return }
                    self.engine.stop()
                    self.engineStatus = .idle
                }
            } else {
                if engine.isRunning { engine.stop() }
                engineStatus = .idle
            }
            return
        }
        let statusName = group.count > 1 ? "\(group.count) devices" : (activeProfile?.displayName ?? primary.name)

        if !forceRestart, engine.isRunning, engine.runningDeviceUIDs == group.map(\.uid) {
            pushSettings()
            engineStatus = .running(deviceName: statusName)
            return
        }

        do {
            pushSettings()
            try engine.start(on: group)
            pushSettings() // routes and the real sample rate are known now
            engineStatus = .running(deviceName: statusName)
        } catch {
            engineStatus = .failed(error.localizedDescription)
            // Bluetooth devices sometimes need a moment after connecting.
            if !isRetry {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.currentOutput == primary else { return }
                    self.applyEngineState(isRetry: true)
                }
            }
        }
    }

    private func pushSettings() {
        let rate = engine.sampleRate
        let grouped = engine.routes.count > 1

        func settings(for profile: DeviceProfile?) -> (filters: [Biquad], gain: Double) {
            guard let profile, shouldProcess(profile), !isBypassed else { return ([], 1) }
            return (profile.filters(sampleRate: rate), pow(10, profile.effectivePreampDB / 20))
        }

        var routes: [EQProcessor.Route] = []
        if engine.isRunning, !engine.routes.isEmpty {
            for route in engine.routes {
                let device = connectedDevices.first { $0.uid == route.deviceUID }
                let eq = settings(for: device.flatMap(profile(for:)))
                let delayMs = grouped ? (outputDelays[route.deviceUID] ?? 0) : 0
                routes.append(EQProcessor.Route(
                    firstBuffer: route.firstBuffer,
                    bufferCount: route.bufferCount,
                    filters: eq.filters,
                    gain: eq.gain,
                    delayFrames: Int(delayMs / 1000 * rate)
                ))
            }
        } else {
            let eq = settings(for: activeProfile)
            routes = [EQProcessor.Route(firstBuffer: 0, bufferCount: 64, filters: eq.filters, gain: eq.gain, delayFrames: 0)]
        }
        engine.processor.update(routes: routes, limiter: limiterEnabled, sampleRate: rate)
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

    private func saveGroup() {
        UserDefaults.standard.set(extraOutputUIDs, forKey: SettingsKey.extraOutputs)
        UserDefaults.standard.set(outputDelays, forKey: SettingsKey.outputDelays)
    }

    private func saveUserPresets() {
        if let data = try? JSONEncoder().encode(userPresets) {
            UserDefaults.standard.set(data, forKey: SettingsKey.userPresets)
        }
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
