import CoreAudio
import Darwin
import Foundation
import os

/// Realtime-safe EQ for one or more output devices.
///
/// Every output device in the aggregate is a *route*: a run of output buffers with its own
/// filter chain, output gain and sync delay. Settings are written from the main thread into
/// a "pending" slot guarded by an unfair lock. The audio thread only ever *tries* the lock,
/// so it never blocks; if the lock is busy it keeps rendering with the previous settings and
/// picks the new ones up next cycle.
final class EQProcessor {
    struct Route {
        var firstBuffer: Int
        var bufferCount: Int
        var filters: [Biquad]
        var gain: Double
        var delayFrames: Int
    }

    static let maxFilters = 16
    static let maxRoutes = 4
    static let maxChannelsPerRoute = 8
    /// Sync delay is applied to the first two (stereo) channels of each route.
    static let delayedChannels = 2
    static let maxDelayFrames = 48_000
    static let scopeSize = 4_096

    private static let coefficientsPerFilter = 5
    // Global header: [routeCount, limiter, sampleRate]
    private static let globalLength = 3
    // Route: [firstBuffer, bufferCount, filterCount, gain, delayFrames, coefficients...]
    private static let routeHeader = 5
    private static var routeLength: Int { routeHeader + maxFilters * coefficientsPerFilter }
    private static var settingsLength: Int { globalLength + maxRoutes * routeLength }
    private static var stateLength: Int { maxRoutes * maxChannelsPerRoute * maxFilters * 2 }
    private static var delayLength: Int { maxRoutes * delayedChannels * maxDelayFrames }

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// pending[0] is the "dirty" flag; the settings follow from pending[1].
    private let pending: UnsafeMutablePointer<Double>
    private let active: UnsafeMutablePointer<Double>
    private let state: UnsafeMutablePointer<Double>
    private let delayLines: UnsafeMutablePointer<Float>
    private let delayPositions: UnsafeMutablePointer<Int>
    private let inputPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let inputStrides: UnsafeMutablePointer<Int>
    private static let maxInputChannels = 16

    // Written by the audio thread, read by the UI. Single aligned scalars, so a torn read
    // is impossible and a slightly stale one is harmless.
    private let meters: UnsafeMutablePointer<Float>
    private let load: UnsafeMutablePointer<Double>
    private let scope: UnsafeMutablePointer<Float>
    private let scopePosition: UnsafeMutablePointer<Int>
    private let ticksToSeconds: Double

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        pending = .allocate(capacity: Self.settingsLength + 1)
        pending.initialize(repeating: 0, count: Self.settingsLength + 1)
        active = .allocate(capacity: Self.settingsLength)
        active.initialize(repeating: 0, count: Self.settingsLength)
        state = .allocate(capacity: Self.stateLength)
        state.initialize(repeating: 0, count: Self.stateLength)
        delayLines = .allocate(capacity: Self.delayLength)
        delayLines.initialize(repeating: 0, count: Self.delayLength)
        delayPositions = .allocate(capacity: Self.maxRoutes * Self.delayedChannels)
        delayPositions.initialize(repeating: 0, count: Self.maxRoutes * Self.delayedChannels)
        inputPointers = .allocate(capacity: Self.maxInputChannels)
        inputPointers.initialize(repeating: nil, count: Self.maxInputChannels)
        inputStrides = .allocate(capacity: Self.maxInputChannels)
        inputStrides.initialize(repeating: 1, count: Self.maxInputChannels)
        meters = .allocate(capacity: Self.maxRoutes * 2)
        meters.initialize(repeating: 0, count: Self.maxRoutes * 2)
        load = .allocate(capacity: 1)
        load.initialize(to: 0)
        scope = .allocate(capacity: Self.scopeSize)
        scope.initialize(repeating: 0, count: Self.scopeSize)
        scopePosition = .allocate(capacity: 1)
        scopePosition.initialize(to: 0)

        // Until the first update: one pass-through route over every buffer, limiter on.
        active[0] = 1
        active[1] = 1
        active[2] = 48_000
        active[Self.globalLength + 1] = 64
        active[Self.globalLength + 3] = 1

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    deinit {
        lock.deallocate()
        pending.deallocate()
        active.deallocate()
        state.deallocate()
        delayLines.deallocate()
        delayPositions.deallocate()
        inputPointers.deallocate()
        inputStrides.deallocate()
        meters.deallocate()
        load.deallocate()
        scope.deallocate()
        scopePosition.deallocate()
    }

    // MARK: - Main thread

    func update(routes: [Route], limiter: Bool, sampleRate: Double) {
        let routes = routes.prefix(Self.maxRoutes)
        os_unfair_lock_lock(lock)
        let settings = pending + 1
        settings[0] = Double(routes.count)
        settings[1] = limiter ? 1 : 0
        settings[2] = sampleRate
        for (r, route) in routes.enumerated() {
            let base = settings + Self.globalLength + r * Self.routeLength
            let filters = route.filters.prefix(Self.maxFilters)
            base[0] = Double(route.firstBuffer)
            base[1] = Double(route.bufferCount)
            base[2] = Double(filters.count)
            base[3] = route.gain
            base[4] = Double(min(max(route.delayFrames, 0), Self.maxDelayFrames - 1))
            for (i, f) in filters.enumerated() {
                let co = base + Self.routeHeader + i * Self.coefficientsPerFilter
                co[0] = f.b0
                co[1] = f.b1
                co[2] = f.b2
                co[3] = f.a1
                co[4] = f.a2
            }
        }
        pending[0] = 1
        os_unfair_lock_unlock(lock)
    }

    /// While the device is stopped: forget filter history, delay lines and meters.
    func reset() {
        state.update(repeating: 0, count: Self.stateLength)
        delayLines.update(repeating: 0, count: Self.delayLength)
        delayPositions.update(repeating: 0, count: Self.maxRoutes * Self.delayedChannels)
        meters.update(repeating: 0, count: Self.maxRoutes * 2)
        scope.update(repeating: 0, count: Self.scopeSize)
        load.pointee = 0
    }

    /// Peak level (0…1, short release) of channel 0 or 1 of a route.
    func meterLevel(route: Int, channel: Int) -> Float {
        guard route >= 0, route < Self.maxRoutes else { return 0 }
        return meters[route * 2 + min(max(channel, 0), 1)]
    }

    /// Fraction of the audio deadline spent processing (0.01 = 1% of one core).
    var processingLoad: Double { load.pointee }

    /// Copies the most recent `count` output samples of the first device (left channel).
    func copyScope(into destination: UnsafeMutablePointer<Float>, count: Int) {
        let count = min(count, Self.scopeSize)
        let end = scopePosition.pointee
        let mask = Self.scopeSize - 1
        for i in 0..<count {
            destination[i] = scope[(end - count + i) & mask]
        }
    }

    // MARK: - Audio thread

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

        let routeCount = Int(active[0])
        let limiter = active[1] != 0
        let sampleRate = active[2]

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // Start from silence so any buffer no route covers stays quiet.
        var framesThisCycle = 0
        for i in 0..<outList.count {
            guard let data = outList[i].mData else { continue }
            memset(data, 0, Int(outList[i].mDataByteSize))
            let channels = max(Int(outList[i].mNumberChannels), 1)
            framesThisCycle = max(framesThisCycle, Int(outList[i].mDataByteSize) / (MemoryLayout<Float>.size * channels))
        }

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
        guard inChannels > 0 else { return }

        let mask = Self.scopeSize - 1
        for r in 0..<min(routeCount, Self.maxRoutes) {
            let route = active + Self.globalLength + r * Self.routeLength
            let firstBuffer = Int(route[0])
            let endBuffer = min(outList.count, firstBuffer + Int(route[1]))
            let filterCount = Int(route[2])
            let gain = route[3]
            let delay = Int(route[4])
            let coefficients = route + Self.routeHeader
            guard firstBuffer < endBuffer else { continue }

            var peaks: (Float, Float) = (0, 0)
            var routeChannel = 0
            for i in firstBuffer..<endBuffer {
                let buffer = outList[i]
                guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
                let channels = Int(buffer.mNumberChannels)
                let out = data.assumingMemoryBound(to: Float.self)
                let frames = min(Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels), inFrames)

                for c in 0..<channels {
                    let channel = routeChannel + c
                    guard frames > 0, let src = inputPointers[channel % inChannels] else { continue }
                    let srcStride = inputStrides[channel % inChannels]
                    let useEQ = channel < Self.maxChannelsPerRoute
                    let z = state + (r * Self.maxChannelsPerRoute + (useEQ ? channel : 0)) * Self.maxFilters * 2
                    let delayed = delay > 0 && channel < Self.delayedChannels
                    let line = delayLines + (r * Self.delayedChannels + min(channel, Self.delayedChannels - 1)) * Self.maxDelayFrames
                    let positionSlot = delayPositions + r * Self.delayedChannels + min(channel, Self.delayedChannels - 1)
                    var position = positionSlot.pointee
                    let writesScope = r == 0 && channel == 0
                    let scopeStart = scopePosition.pointee
                    var peak: Float = 0

                    for f in 0..<frames {
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
                        if delayed {
                            line[position] = Float(x)
                            var readIndex = position - delay
                            if readIndex < 0 { readIndex += Self.maxDelayFrames }
                            x = Double(line[readIndex])
                            position += 1
                            if position == Self.maxDelayFrames { position = 0 }
                        }
                        let sample = Float(limiter ? Self.softClip(x) : min(max(x, -1), 1))
                        out[f * channels + c] = sample
                        peak = max(peak, abs(sample))
                        if writesScope { scope[(scopeStart + f) & mask] = sample }
                    }

                    if delayed { positionSlot.pointee = position }
                    if writesScope { scopePosition.pointee = (scopeStart + frames) & mask }
                    if channel == 0 { peaks.0 = peak } else if channel == 1 { peaks.1 = peak }

                    // Flush denormals so silence stays cheap.
                    if useEQ {
                        for k in 0..<(filterCount * 2) where abs(z[k]) < 1e-20 {
                            z[k] = 0
                        }
                    }
                }
                routeChannel += channels
            }
            if routeChannel == 1 { peaks.1 = peaks.0 }
            meters[r * 2] = max(peaks.0, meters[r * 2] * 0.82)
            meters[r * 2 + 1] = max(peaks.1, meters[r * 2 + 1] * 0.82)
        }

        if framesThisCycle > 0, sampleRate > 0 {
            let elapsed = Double(mach_absolute_time() - startTicks) * ticksToSeconds
            let budget = Double(framesThisCycle) / sampleRate
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
