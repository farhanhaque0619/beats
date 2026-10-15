import AudioToolbox
import CoreAudio
import Foundation

/// A playback device the Mac can send audio to.
struct OutputDevice: Identifiable, Equatable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var isVirtual: Bool { transportType == kAudioDeviceTransportTypeVirtual }
}

struct CoreAudioError: LocalizedError {
    let message: String
    let status: OSStatus

    init(_ message: String, _ status: OSStatus = noErr) {
        self.message = message
        self.status = status
    }

    var errorDescription: String? {
        status == noErr ? message : "\(message) (error \(status))"
    }
}

/// Thin, synchronous wrappers around the Core Audio HAL property API.
enum HAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref)
        guard err == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func uint32(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }

    @discardableResult
    static func setNominalSampleRate(_ id: AudioObjectID, _ rate: Double) -> Bool {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = rate
        let size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectSetPropertyData(id, &addr, 0, nil, size, &value) == noErr
    }

    /// How far behind real time this device plays, as the driver reports it. Bluetooth
    /// devices include their codec delay here, which is what makes Auto-Sync work.
    static func outputLatency(_ id: AudioObjectID) -> TimeInterval {
        let rate = nominalSampleRate(id) ?? 48_000
        var frames = Double(uint32(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) ?? 0)
        frames += Double(uint32(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput) ?? 0)
        if let stream = outputStreamIDs(id).first {
            frames += Double(uint32(stream, kAudioStreamPropertyLatency) ?? 0)
        }
        return frames / rate
    }

    static func outputStreamIDs(_ id: AudioObjectID) -> [AudioStreamID] {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    // MARK: Volume

    private static var volumeAddress: AudioObjectPropertyAddress {
        address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
    }

    /// The device's own volume, 0…1, if it has one.
    static func volume(_ id: AudioObjectID) -> Float? {
        var addr = volumeAddress
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func canSetVolume(_ id: AudioObjectID) -> Bool {
        var addr = volumeAddress
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &addr, &settable) == noErr && settable.boolValue
    }

    static func setVolume(_ id: AudioObjectID, _ volume: Float) {
        var addr = volumeAddress
        var value = Float32(min(max(volume, 0), 1))
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func bufferFrameSize(_ id: AudioObjectID) -> Int? {
        uint32(id, kAudioDevicePropertyBufferFrameSize).map(Int.init)
    }

    /// Makes `id` the Mac's sound output, like choosing it in Control Center.
    @discardableResult
    static func setDefaultOutputDevice(_ id: AudioObjectID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectSetPropertyData(systemObject, &addr, 0, nil, size, &deviceID) == noErr
    }

    static func streamCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func outputDevice(_ id: AudioObjectID) -> OutputDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = string(id, kAudioObjectPropertyName) ?? "Unknown Device"
        let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
        return OutputDevice(id: id, uid: uid, name: name, transportType: transport)
    }

    static func defaultOutputDevice() -> OutputDevice? {
        defaultOutputDeviceID().flatMap(outputDevice)
    }

    /// Every real playback device. Aggregates, our own private devices, and virtual
    /// devices (Zoom, Teams, loopback drivers) are left out unless they are the current output.
    static func outputDevices() -> [OutputDevice] {
        let current = defaultOutputDeviceID()
        return allDeviceIDs().compactMap { id in
            guard streamCount(id, scope: kAudioObjectPropertyScopeOutput) > 0,
                  let device = outputDevice(id),
                  device.transportType != kAudioDeviceTransportTypeAggregate,
                  !device.uid.hasPrefix(SystemEQEngine.aggregateUIDPrefix),
                  !device.isVirtual || id == current
            else { return nil }
            return device
        }
    }

    /// The HAL "process object" for this app, so the tap can leave our own output alone.
    static func ownProcessObjectID() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &objectID
        )
        guard err == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    /// Calls `handler` on the main queue whenever a system-level property changes.
    @discardableResult
    static func observeSystem(
        _ selector: AudioObjectPropertySelector,
        handler: @escaping () -> Void
    ) -> Bool {
        var addr = address(selector)
        let err = AudioObjectAddPropertyListenerBlock(systemObject, &addr, DispatchQueue.main) { _, _ in
            handler()
        }
        return err == noErr
    }
}
