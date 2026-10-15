import CoreAudio
import Foundation
import os

/// Realtime-safe EQ: a cascade of biquads per channel plus output gain and a soft limiter.
///
/// Settings are written from the main thread into a "pending" slot guarded by an unfair lock.
/// The audio thread only ever *tries* the lock, so it never blocks; if the lock is busy it
/// keeps rendering with the previous coefficients and picks the new ones up next cycle.
final class EQProcessor {
    static let maxFilters = 16
    static let maxChannels = 8
    private static let maxInputChannels = 16
    private static let coefficientsPerFilter = 5

    private let lock: UnsafeMutablePointer<os_unfair_lock>

    // Pending (main thread, under lock): [dirty, filterCount, gain, coefficients...]
    private let pending: UnsafeMutablePointer<Double>
    // Active (audio thread only): [filterCount, gain, coefficients...]
    private let active: UnsafeMutablePointer<Double>
    // Filter memory: channel * maxFilters * 2
    private let state: UnsafeMutablePointer<Double>

    private let inputPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let inputStrides: UnsafeMutablePointer<Int>

    private static var settingsLength: Int { 2 + maxFilters * coefficientsPerFilter }
    private static var stateLength: Int { maxChannels * maxFilters * 2 }

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        pending = .allocate(capacity: Self.settingsLength + 1)
        pending.initialize(repeating: 0, count: Self.settingsLength + 1)
        active = .allocate(capacity: Self.settingsLength)
        active.initialize(repeating: 0, count: Self.settingsLength)
        active[1] = 1 // unity gain
        state = .allocate(capacity: Self.stateLength)
        state.initialize(repeating: 0, count: Self.stateLength)
        inputPointers = .allocate(capacity: Self.maxInputChannels)
        inputPointers.initialize(repeating: nil, count: Self.maxInputChannels)
        inputStrides = .allocate(capacity: Self.maxInputChannels)
        inputStrides.initialize(repeating: 1, count: Self.maxInputChannels)
    }

    deinit {
        lock.deallocate()
        pending.deallocate()
        active.deallocate()
        state.deallocate()
        inputPointers.deallocate()
        inputStrides.deallocate()
    }

    /// Main thread: publish new filters and linear output gain.
    func update(filters: [Biquad], outputGain: Double) {
        let count = min(filters.count, Self.maxFilters)
        os_unfair_lock_lock(lock)
        pending[0] = 1
        pending[1] = Double(count)
        pending[2] = outputGain
        for (i, f) in filters.prefix(count).enumerated() {
            let base = 3 + i * Self.coefficientsPerFilter
            pending[base] = f.b0
            pending[base + 1] = f.b1
            pending[base + 2] = f.b2
            pending[base + 3] = f.a1
            pending[base + 4] = f.a2
        }
        os_unfair_lock_unlock(lock)
    }

    /// Main thread, while the device is stopped: forget filter history.
    func reset() {
        state.update(repeating: 0, count: Self.stateLength)
    }

    /// Audio thread. Reads tap audio from `input` (starting at `firstInputBuffer`),
    /// equalises it and writes it to every buffer in `output`.
    func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        firstInputBuffer: Int
    ) {
        if os_unfair_lock_trylock(lock) {
            if pending[0] != 0 {
                (active).update(from: pending + 1, count: Self.settingsLength)
                pending[0] = 0
            }
            os_unfair_lock_unlock(lock)
        }

        let filterCount = Int(active[0])
        let gain = active[1]
        let coefficients = active + 2

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // Collect input channels (tap audio) without allocating.
        var inChannels = 0
        var inFrames = Int.max
        let start = firstInputBuffer < inList.count ? firstInputBuffer : 0
        for i in start..<inList.count {
            let buffer = inList[i]
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let samples = data.assumingMemoryBound(to: Float.self)
            inFrames = min(inFrames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            for c in 0..<channels where inChannels < Self.maxInputChannels {
                inputPointers[inChannels] = samples + c
                inputStrides[inChannels] = channels
                inChannels += 1
            }
        }
        if inChannels == 0 { inFrames = 0 }

        var outChannel = 0
        for i in 0..<outList.count {
            let buffer = outList[i]
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let out = data.assumingMemoryBound(to: Float.self)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let rendered = min(frames, inFrames)

            for c in 0..<channels {
                let channel = outChannel + c
                if rendered < frames {
                    for f in rendered..<frames { out[f * channels + c] = 0 }
                }
                guard rendered > 0, let src = inputPointers[channel % inChannels] else { continue }
                let srcStride = inputStrides[channel % inChannels]
                let useEQ = channel < Self.maxChannels
                let z = state + (useEQ ? channel : 0) * Self.maxFilters * 2

                for f in 0..<rendered {
                    var x = Double(src[f * srcStride])
                    if useEQ {
                        for k in 0..<filterCount {
                            let co = coefficients + k * Self.coefficientsPerFilter
                            let y = co[0] * x + z[2 * k]
                            z[2 * k] = co[1] * x - co[3] * y + z[2 * k + 1]
                            z[2 * k + 1] = co[2] * x - co[4] * y
                            x = y
                        }
                    }
                    out[f * channels + c] = Float(Self.softClip(x * gain))
                }

                // Flush denormals so silence stays cheap.
                for k in 0..<(filterCount * 2) where abs(z[k]) < 1e-20 {
                    z[k] = 0
                }
            }
            outChannel += channels
        }
    }

    /// Transparent below -2 dBFS, then rounds peaks off smoothly instead of hard clipping.
    @inline(__always)
    private static func softClip(_ x: Double) -> Double {
        let threshold = 0.8
        let magnitude = abs(x)
        guard magnitude > threshold else { return x }
        let over = (magnitude - threshold) / (1 - threshold)
        let shaped = threshold + (1 - threshold) * tanh(over)
        return x < 0 ? -shaped : shaped
    }
}
