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

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [DeviceProfile] = []
    @Published var selectedProfileID: String?
    @Published private(set) var currentOutput: OutputDevice?
    @Published private(set) var connectedDevices: [OutputDevice] = []
    @Published private(set) var engineStatus: EngineStatus = .idle

    private let engine = SystemEQEngine()
    private let storageKey = "profiles.v1"
    private var saveWork: DispatchWorkItem?

    init() {
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
    var otherProfiles: [DeviceProfile] { profiles.filter { $0.kind == .other } }

    func profile(id: String?) -> DeviceProfile? {
        profiles.first { $0.id == id }
    }

    func isCurrentOutput(_ profile: DeviceProfile) -> Bool {
        activeProfile?.id == profile.id
    }

    func isConnected(_ profile: DeviceProfile) -> Bool {
        connectedDevices.contains { profileID(for: $0) == profile.id }
    }

    func isProcessing(_ profile: DeviceProfile) -> Bool {
        isCurrentOutput(profile) && engine.isRunning
    }

    // MARK: - Editing

    func update(_ id: String, _ change: (inout DeviceProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let wasEnabled = profiles[index].isEnabled
        change(&profiles[index])
        scheduleSave()

        guard profiles[index].id == activeProfile?.id else { return }
        if wasEnabled != profiles[index].isEnabled {
            applyEngineState()
        } else {
            pushSettings()
        }
    }

    func setGain(_ gain: Double, band: Int, for id: String) {
        update(id) { profile in
            profile.gains[band] = (gain * 2).rounded() / 2
            profile.presetName = "Custom"
        }
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

    func retry() {
        applyEngineState()
    }

    // MARK: - Devices

    private func profileID(for device: OutputDevice) -> String {
        let kind = DeviceKind.detect(deviceName: device.name)
        return kind == .other ? "device:" + device.uid : kind.rawValue
    }

    private func refreshDevices() {
        connectedDevices = HAL.outputDevices()
    }

    private func outputDidChange() {
        let device = HAL.defaultOutputDevice()
        guard device != currentOutput || !engineMatches(device) else { return }
        currentOutput = device
        refreshDevices()

        if let device, profile(id: profileID(for: device)) == nil {
            profiles.append(.other(uid: device.uid, name: device.name))
            scheduleSave()
        }
        applyEngineState()
    }

    private func engineMatches(_ device: OutputDevice?) -> Bool {
        engine.runningDeviceUID == device?.uid && (activeProfile?.isEnabled ?? false)
    }

    // MARK: - Engine

    private func applyEngineState(isRetry: Bool = false) {
        guard SystemEQEngine.isSupported else {
            engineStatus = .unsupported
            return
        }
        guard let device = currentOutput, let profile = activeProfile, profile.isEnabled else {
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
        engine.processor.update(filters: profile.filters(sampleRate: engine.sampleRate), outputGain: gain)
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
        return known + stored.filter { $0.kind == .other }
    }
}
