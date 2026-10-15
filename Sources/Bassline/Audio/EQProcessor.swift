import CoreAudio
import Darwin
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

    // Settings layout: [filterCount, gain, limiter, sampleRate, coefficients...]
    private static let headerLength = 4
    private static var settingsLength: Int { headerLength + maxFilters * coefficientsPerFilter }
    private static var stateLength: Int { maxChannels * maxFilters * 2 }

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// pending[0] is the "dirty" flag; the settings follow from pending[1].
    private let pending: UnsafeMutablePointer<Double>
    private let active: UnsafeMutablePointer<Double>
    private let state: UnsafeMutablePointer<Double>
    private let inputPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let inputStrides: UnsafeMutablePointer<Int>

    /// Written by the audio thread, read by the UI. Single aligned scalars, so a torn read
    /// is impossible and a slightly stale one is harmless.
    private let meters: UnsafeMutablePointer<Float>
    private let load: UnsafeMutablePointer<Double>
    private let ticksToSeconds: Double

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        pending = .allocate(capacity: Self.settingsLength + 1)
        pending.initialize(repeating: 0, count: Self.settingsLength + 1)
        active = .allocate(capacity: Self.settingsLength)
        active.initialize(repeating: 0, count: Self.settingsLength)
        active[1] = 1 // unity gain
        active[2] = 1 // limiter on
        active[3] = 48_000
        state = .allocate(capacity: Self.stateLength)
        state.initialize(repeating: 0, count: Self.stateLength)
        inputPointers = .allocate(capacity: Self.maxInputChannels)
        inputPointers.initialize(repeating: nil, count: Self.maxInputChannels)
        inputStrides = .allocate(capacity: Self.maxInputChannels)
        inputStrides.initialize(repeating: 1, count: Self.maxInputChannels)
        meters = .allocate(capacity: 2)
        meters.initialize(repeating: 0, count: 2)
        load = .allocate(capacity: 1)
        load.initialize(to: 0)

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    deinit {
        lock.deallocate()
        pending.deallocate()
        active.deallocate()
        state.deallocate()
        inputPointers.deallocate()
        inputStrides.deallocate()
        meters.deallocate()
        load.deallocate()
    }

    /// Main thread: publish new filters, linear output gain and limiter setting.
    func update(filters: [Biquad], outputGain: Double, limiter: Bool, sampleRate: Double) {
        let count = min(filters.count, Self.maxFilters)
        os_unfair_lock_lock(lock)
        let settings = pending + 1
        settings[0] = Double(count)
        settings[1] = outputGain
        settings[2] = limiter ? 1 : 0
        settings[3] = sampleRate
        for (i, f) in filters.prefix(count).enumerated() {
            let base = Self.headerLength + i * Self.coefficientsPerFilter
            settings[base] = f.b0
            settings[base + 1] = f.b1
            settings[base + 2] = f.b2
            settings[base + 3] = f.a1
            settings[base + 4] = f.a2
        }
        pending[0] = 1
        os_unfair_lock_unlock(lock)
    }

    /// Main thread, while the device is stopped: forget filter history and meters.
    func reset() {
        state.update(repeating: 0, count: Self.stateLength)
        meters[0] = 0
        meters[1] = 0
        load.pointee = 0
    }

    /// Peak output level of channel 0 or 1, from 0 to 1, with a short release.
    func meterLevel(_ channel: Int) -> Float {
        meters[min(max(channel, 0), 1)]
    }

    /// Fraction of the audio deadline spent equalising (0.01 = 1% of one core).
    var processingLoad: Double { load.pointee }

    /// Audio thread. Reads tap audio from `input` (starting at `firstInputBuffer`),
    /// equalises it and writes it to every buffer in `output`.
    func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        firstInputBuffer: Int
    ) {
        let startTicks = mach_absolute_time()

        if os_unfair_lock_trylock(lock) {
            if pending[0] != 0 {
                active.update(from: pending + 1, count: Self.settingsLength)
                pending[0] = 0
            }
            os_unfair_lock_unlock(lock)
        }

        let filterCount = Int(active[0])
        let gain = active[1]
        let limiter = active[2] != 0
        let sampleRate = active[3]
        let coefficients = active + Self.headerLength

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

        var peaks: (Float, Float) = (0, 0)
        var renderedFrames = 0
        var outChannel = 0
        for i in 0..<outList.count {
            let buffer = outList[i]
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let out = data.assumingMemoryBound(to: Float.self)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let rendered = min(frames, inFrames)
            renderedFrames = max(renderedFrames, frames)

            for c in 0..<channels {
                let channel = outChannel + c
                if rendered < frames {
                    for f in rendered..<frames { out[f * channels + c] = 0 }
                }
                guard rendered > 0, let src = inputPointers[channel % inChannels] else { continue }
                let srcStride = inputStrides[channel % inChannels]
                let useEQ = channel < Self.maxChannels
                let z = state + (useEQ ? channel : 0) * Self.maxFilters * 2
                var peak: Float = 0

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
                    x *= gain
                    let sample = Float(limiter ? Self.softClip(x) : min(max(x, -1), 1))
                    out[f * channels + c] = sample
                    peak = max(peak, abs(sample))
                }

                if channel == 0 { peaks.0 = peak } else if channel == 1 { peaks.1 = peak }

                // Flush denormals so silence stays cheap.
                for k in 0..<(filterCount * 2) where abs(z[k]) < 1e-20 {
                    z[k] = 0
                }
            }
            outChannel += channels
        }

        if outChannel == 1 { peaks.1 = peaks.0 }
        meters[0] = max(peaks.0, meters[0] * 0.82)
        meters[1] = max(peaks.1, meters[1] * 0.82)

        if renderedFrames > 0, sampleRate > 0 {
            let elapsed = Double(mach_absolute_time() - startTicks) * ticksToSeconds
            let budget = Double(renderedFrames) / sampleRate
            load.pointee = load.pointee * 0.97 + (elapsed / budget) * 0.03
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
