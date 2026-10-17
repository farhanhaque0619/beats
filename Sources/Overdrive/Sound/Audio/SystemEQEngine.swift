import AudioToolbox
import CoreAudio
import Foundation
import os

/// Applies the EQ to everything the Mac plays, on one output device or several at once.
///
/// It uses a Core Audio process tap (macOS 14.2+) that captures and mutes the system mix,
/// then plays the equalised result to the real output devices through a private aggregate
/// device. With more than one device, every extra device is clock-corrected against the
/// first so they stay in step. Nothing is installed in the system: when the engine stops
/// or the app quits, macOS removes the tap and audio goes straight to the device again.
final class SystemEQEngine {
    static let aggregateUIDPrefix = "com.overdrive.sound."

    /// One app that gets its own tap, so it can have its own volume or skip the EQ.
    struct AppTap: Equatable {
        let key: String
        let processes: [AudioObjectID]
    }

    /// The output buffers that belong to one device inside the aggregate.
    struct Route: Equatable {
        let deviceUID: String
        let firstBuffer: Int
        let bufferCount: Int
    }

    let processor = EQProcessor()
    private let logger = Logger(subsystem: "com.farhanhaque.overdrive", category: "engine")

    private var tapIDs: [AudioObjectID] = []
    private var tapUUIDs: [UUID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    private(set) var runningDeviceUIDs: [String] = []
    private(set) var routes: [Route] = []
    private(set) var runningAppTaps: [AppTap] = []
    /// What each input source is, in order: nil for "everything else", or an app key.
    private(set) var sourceKeys: [String?] = []
    private(set) var sampleRate: Double = 48_000
    private(set) var bufferFrames = 512

    /// Extra delay the EQ adds: one buffer in from the tap, one buffer out.
    var addedLatency: TimeInterval { 2 * Double(bufferFrames) / sampleRate }

    var isRunning: Bool { !runningDeviceUIDs.isEmpty }

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// Starts playing through `devices`. The first one is the clock everything follows.
    func start(on devices: [OutputDevice], appTaps: [AppTap] = []) throws {
        stop()
        guard #available(macOS 14.2, *) else {
            throw CoreAudioError("System-wide EQ needs macOS Sonoma 14.2 or later.")
        }
        guard let main = devices.first else { return }
        do {
            matchSampleRates(devices)
            try createTaps(appTaps)
            try createAggregate(outputs: devices)
            routes = Self.makeRoutes(devices, aggregateID: aggregateID)
            try startIO(outputs: devices)
            runningDeviceUIDs = devices.map(\.uid)
            runningAppTaps = appTaps
            logger.info("Playing on \(devices.count) device(s), clock \(main.name, privacy: .public), \(self.sampleRate) Hz")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)

        if #available(macOS 14.2, *) {
            for tapID in tapIDs { AudioHardwareDestroyProcessTap(tapID) }
        }
        tapIDs = []
        tapUUIDs = []
        sourceKeys = []
        runningAppTaps = []
        runningDeviceUIDs = []
        routes = []
        processor.reset()
    }

    // MARK: - Setup

    /// One muted tap for everything except our own output and the per-app taps, then one
    /// muted tap per app. Their streams reach the IO proc in this same order.
    @available(macOS 14.2, *)
    private func createTaps(_ appTaps: [AppTap]) throws {
        // Leave our own output out, otherwise we would hear ourselves in a loop.
        let own = HAL.ownProcessObjectID().map { [$0] } ?? []
        let appProcesses = appTaps.flatMap(\.processes)
        try addTap(CATapDescription(stereoGlobalTapButExcludeProcesses: own + appProcesses), key: nil)
        for app in appTaps where !app.processes.isEmpty {
            try addTap(CATapDescription(stereoMixdownOfProcesses: app.processes), key: app.key)
        }
    }

    @available(macOS 14.2, *)
    private func addTap(_ description: CATapDescription, key: String?) throws {
        let uuid = UUID()
        description.uuid = uuid
        description.name = "Overdrive EQ"
        description.muteBehavior = .muted
        description.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr else { throw CoreAudioError("Couldn’t start listening to system audio", err) }
        tapIDs.append(newTapID)
        tapUUIDs.append(uuid)
        sourceKeys.append(key)
    }

    /// Extra devices run at the main device's rate when they can, which avoids resampling.
    private func matchSampleRates(_ devices: [OutputDevice]) {
        guard devices.count > 1, let rate = HAL.nominalSampleRate(devices[0].id) else { return }
        for device in devices.dropFirst() where HAL.nominalSampleRate(device.id) != rate {
            HAL.setNominalSampleRate(device.id, rate)
        }
    }

    private func createAggregate(outputs: [OutputDevice]) throws {
        // Not stacked: each device keeps its own channels, so each can get its own EQ.
        let subDevices: [[String: Any]] = outputs.enumerated().map { index, device in
            [
                kAudioSubDeviceUIDKey: device.uid,
                kAudioSubDeviceDriftCompensationKey: index > 0,
            ]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Overdrive EQ",
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputs[0].uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: tapUUIDs.map { uuid in
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: uuid.uuidString,
                ] as [String: Any]
            },
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard err == noErr else { throw CoreAudioError("Couldn’t connect to the output device", err) }
        aggregateID = newAggregateID
        sampleRate = HAL.nominalSampleRate(newAggregateID) ?? 48_000
        bufferFrames = HAL.bufferFrameSize(newAggregateID) ?? 512
    }

    /// The aggregate lists each device's output streams in order, so device N owns the
    /// buffers after those of devices 0..<N.
    private static func makeRoutes(_ devices: [OutputDevice], aggregateID: AudioObjectID) -> [Route] {
        var routes: [Route] = []
        var cursor = 0
        for device in devices {
            let count = HAL.streamCount(device.id, scope: kAudioObjectPropertyScopeOutput)
            routes.append(Route(deviceUID: device.uid, firstBuffer: cursor, bufferCount: count))
            cursor += count
        }
        let total = HAL.streamCount(aggregateID, scope: kAudioObjectPropertyScopeOutput)
        if total != cursor, let first = devices.first {
            // Unexpected layout: treat everything as the first device rather than mis-route.
            return [Route(deviceUID: first.uid, firstBuffer: 0, bufferCount: max(total, 1))]
        }
        return routes
    }

    private func startIO(outputs: [OutputDevice]) throws {
        // The aggregate's input streams are the devices' own inputs (for example the
        // AirPods microphones) followed by the tap. We only read the tap, and switch the
        // microphone streams off so Bluetooth headphones stay in high-quality mode.
        let deviceInputStreams = outputs.reduce(0) { $0 + HAL.streamCount($1.id, scope: kAudioObjectPropertyScopeInput) }
        let processor = self.processor

        var newProcID: AudioDeviceIOProcID?
        var err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil) { _, inputData, _, outputData, _ in
            processor.render(input: inputData, output: outputData, firstInputBuffer: deviceInputStreams)
        }
        guard err == noErr, let newProcID else { throw CoreAudioError("Couldn’t create the audio stream", err) }
        procID = newProcID

        if deviceInputStreams > 0 {
            disableInputStreams(before: deviceInputStreams, procID: newProcID)
        }

        err = AudioDeviceStart(aggregateID, newProcID)
        guard err == noErr else { throw CoreAudioError("Couldn’t start the audio stream", err) }
    }

    /// Turns off the first `count` input streams of the aggregate for our IO proc.
    private func disableInputStreams(before count: Int, procID: AudioDeviceIOProcID) {
        let total = HAL.streamCount(aggregateID, scope: kAudioObjectPropertyScopeInput)
        guard total > count else { return }

        // AudioHardwareIOProcStreamUsage is variable length:
        // { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[mNumberStreams]; }
        let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let size = headerSize + total * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }

        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(total), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for i in 0..<total {
            let isOn: UInt32 = i < count ? 0 : 1
            raw.storeBytes(of: isOn, toByteOffset: headerSize + i * MemoryLayout<UInt32>.size, as: UInt32.self)
        }

        var addr = HAL.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        let err = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(size), raw)
        if err != noErr {
            logger.warning("Couldn’t switch off device inputs: \(err)")
        }
    }

    deinit { stop() }
}
