import AudioToolbox
import CoreAudio
import Foundation
import os

/// Applies the EQ to everything the Mac plays.
///
/// It uses a Core Audio process tap (macOS 14.2+) that captures and mutes the system mix,
/// then plays the equalised result to the real output device through a private aggregate
/// device. Nothing is installed in the system: when the engine stops or the app quits,
/// macOS removes the tap and audio goes straight to the device again.
final class SystemEQEngine {
    static let aggregateUIDPrefix = "com.bassline.eq."

    let processor = EQProcessor()
    private let logger = Logger(subsystem: "com.bassline.app", category: "engine")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    private(set) var runningDeviceUID: String?
    private(set) var sampleRate: Double = 48_000
    private(set) var bufferFrames = 512

    /// Extra delay the EQ adds: one buffer in from the tap, one buffer out.
    var addedLatency: TimeInterval { 2 * Double(bufferFrames) / sampleRate }

    var isRunning: Bool { runningDeviceUID != nil }

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    func start(on device: OutputDevice) throws {
        stop()
        guard #available(macOS 14.2, *) else {
            throw CoreAudioError("System-wide EQ needs macOS Sonoma 14.2 or later.")
        }
        do {
            try createTap()
            try createAggregate(outputUID: device.uid)
            try startIO(outputDeviceID: device.id)
            runningDeviceUID = device.uid
            logger.info("EQ running on \(device.name, privacy: .public) at \(self.sampleRate) Hz")
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

        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        runningDeviceUID = nil
        processor.reset()
    }

    // MARK: - Setup

    private var tapUUID = UUID()

    @available(macOS 14.2, *)
    private func createTap() throws {
        // Leave our own output out of the tap, otherwise we would hear ourselves in a loop.
        let excluded = HAL.ownProcessObjectID().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        tapUUID = UUID()
        description.uuid = tapUUID
        description.name = "Bassline EQ"
        description.muteBehavior = .muted
        description.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr else { throw CoreAudioError("Couldn’t start listening to system audio", err) }
        tapID = newTapID
    }

    private func createAggregate(outputUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Bassline EQ",
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard err == noErr else { throw CoreAudioError("Couldn’t connect to the output device", err) }
        aggregateID = newAggregateID
        sampleRate = HAL.nominalSampleRate(newAggregateID) ?? 48_000
        bufferFrames = HAL.bufferFrameSize(newAggregateID) ?? 512
    }

    private func startIO(outputDeviceID: AudioObjectID) throws {
        // The aggregate's input streams are the output device's own inputs (for example
        // the AirPods microphone) followed by the tap. We only read the tap, and switch
        // the microphone streams off so Bluetooth headphones stay in high-quality mode.
        let deviceInputStreams = HAL.streamCount(outputDeviceID, scope: kAudioObjectPropertyScopeInput)
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
