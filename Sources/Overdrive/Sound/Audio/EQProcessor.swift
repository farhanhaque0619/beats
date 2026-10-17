import CoreAudio
import Darwin
import Foundation
import os

/// Realtime-safe mixer and EQ for one or more output devices.
///
/// Input arrives as one or more *sources* (process taps): everything else on the Mac, plus
/// one tap per app with its own volume or EQ setting. Sources are mixed into two stereo
/// buses: one that gets equalised and one that plays unchanged. Every output device in the
/// aggregate is a *route* with its own speaker role, filter chain, gain and sync delay.
///
/// Settings are written from the main thread into a "pending" slot guarded by an unfair lock.
/// The audio thread only ever *tries* the lock, so it never blocks; if the lock is busy it
/// keeps rendering with the previous settings and picks the new ones up next cycle.
final class EQProcessor {
    enum MixMode: Int {
        /// Left and right as they are.
        case stereo = 0
        /// Both channels play the centre (L+R)/2: where vocals and bass sit.
        case mono = 1
        /// The centred mid-band (mostly vocals) is turned down; instruments and bass stay.
        case centerReduced = 2
    }

    struct Route {
        var firstBuffer: Int
        var bufferCount: Int
        var filters: [Biquad]
        var gain: Double
        var delayFrames: Int
        var mixMode: MixMode = .stereo
        var centerReduction: Double = 0
        var centerFilters: [Biquad] = []
    }

    struct Source {
        var gain: Double
        var useEQ: Bool
    }

    static let maxFilters = 16
    static let maxRoutes = 4
    static let maxSources = 10
    static let maxChannelsPerRoute = 8
    /// Sync delay is applied to the first two (stereo) channels of each route.
    static let delayedChannels = 2
    static let maxDelayFrames = 48_000
    static let maxFrames = 8_192
    static let scopeSize = 4_096
    private static let centerFilterSlots = 2
    private static let coefficientsPerFilter = 5

    // Global: [routeCount, limiter, sampleRate, sourceCount, sourceGains…, sourceUsesEQ…]
    private static var globalLength: Int { 4 + 2 * maxSources }
    // Route: [firstBuffer, bufferCount, filterCount, gain, delayFrames, mixMode,
    //         centerReduction, centerFilterCount, centre coefficients…, coefficients…]
    private static let routeHeader = 8
    private static var coefficientOffset: Int { routeHeader + centerFilterSlots * coefficientsPerFilter }
    private static var routeLength: Int { coefficientOffset + maxFilters * coefficientsPerFilter }
    private static var settingsLength: Int { globalLength + maxRoutes * routeLength }
    private static var stateLength: Int { maxRoutes * maxChannelsPerRoute * maxFilters * 2 }
    private static var centerStateLength: Int { maxRoutes * centerFilterSlots * 2 }
    private static var delayLength: Int { maxRoutes * delayedChannels * maxDelayFrames }

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// pending[0] is the "dirty" flag; the settings follow from pending[1].
    private let pending: UnsafeMutablePointer<Double>
    private let active: UnsafeMutablePointer<Double>
    private let state: UnsafeMutablePointer<Double>
    private let centerState: UnsafeMutablePointer<Double>
    private let delayLines: UnsafeMutablePointer<Float>
    private let delayPositions: UnsafeMutablePointer<Int>
    // Per-cycle mix buses: EQ left/right, unchanged left/right, and the centre band.
    private let eqLeft: UnsafeMutablePointer<Float>
    private let eqRight: UnsafeMutablePointer<Float>
    private let dryLeft: UnsafeMutablePointer<Float>
    private let dryRight: UnsafeMutablePointer<Float>
    private let center: UnsafeMutablePointer<Float>

    // Written by the audio thread, read by the UI. Single aligned scalars, so a torn read
    // is impossible and a slightly stale one is harmless.
    private let meters: UnsafeMutablePointer<Float>
    private let load: UnsafeMutablePointer<Double>
    private let scope: UnsafeMutablePointer<Float>
    private let scopePosition: UnsafeMutablePointer<Int>
    private let ticksToSeconds: Double

    init() {
        func buffer<T>(_ count: Int, _ value: T) -> UnsafeMutablePointer<T> {
            let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
            pointer.initialize(repeating: value, count: count)
            return pointer
        }
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        pending = buffer(Self.settingsLength + 1, 0.0)
        active = buffer(Self.settingsLength, 0.0)
        state = buffer(Self.stateLength, 0.0)
        centerState = buffer(Self.centerStateLength, 0.0)
        delayLines = buffer(Self.delayLength, Float(0))
        delayPositions = buffer(Self.maxRoutes * Self.delayedChannels, 0)
        eqLeft = buffer(Self.maxFrames, Float(0))
        eqRight = buffer(Self.maxFrames, Float(0))
        dryLeft = buffer(Self.maxFrames, Float(0))
        dryRight = buffer(Self.maxFrames, Float(0))
        center = buffer(Self.maxFrames, Float(0))
        meters = buffer(Self.maxRoutes * 2, Float(0))
        load = buffer(1, 0.0)
        scope = buffer(Self.scopeSize, Float(0))
        scopePosition = buffer(1, 0)

        // Until the first update: one source, one pass-through route over every buffer.
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
        for pointer in [pending, active, state, centerState, load] { pointer.deallocate() }
        for pointer in [delayLines, eqLeft, eqRight, dryLeft, dryRight, center, meters, scope] { pointer.deallocate() }
        delayPositions.deallocate()
        scopePosition.deallocate()
    }

    // MARK: - Main thread

    func update(routes: [Route], sources: [Source], limiter: Bool, sampleRate: Double) {
        let routes = routes.prefix(Self.maxRoutes)
        let sources = sources.prefix(Self.maxSources)
        os_unfair_lock_lock(lock)
        let settings = pending + 1
        settings[0] = Double(routes.count)
        settings[1] = limiter ? 1 : 0
        settings[2] = sampleRate
        settings[3] = Double(sources.count)
        for (i, source) in sources.enumerated() {
            settings[4 + i] = source.gain
            settings[4 + Self.maxSources + i] = source.useEQ ? 1 : 0
        }
        for (r, route) in routes.enumerated() {
            let base = settings + Self.globalLength + r * Self.routeLength
            let filters = route.filters.prefix(Self.maxFilters)
            let centerFilters = route.centerFilters.prefix(Self.centerFilterSlots)
            base[0] = Double(route.firstBuffer)
            base[1] = Double(route.bufferCount)
            base[2] = Double(filters.count)
            base[3] = route.gain
            base[4] = Double(min(max(route.delayFrames, 0), Self.maxDelayFrames - 1))
            base[5] = Double(route.mixMode.rawValue)
            base[6] = route.centerReduction
            base[7] = Double(centerFilters.count)
            for (i, f) in centerFilters.enumerated() {
                Self.store(f, at: base + Self.routeHeader + i * Self.coefficientsPerFilter)
            }
            for (i, f) in filters.enumerated() {
                Self.store(f, at: base + Self.coefficientOffset + i * Self.coefficientsPerFilter)
            }
        }
        pending[0] = 1
        os_unfair_lock_unlock(lock)
    }

    private static func store(_ f: Biquad, at co: UnsafeMutablePointer<Double>) {
        co[0] = f.b0
        co[1] = f.b1
        co[2] = f.b2
        co[3] = f.a1
        co[4] = f.a2
    }

    /// While the device is stopped: forget filter history, delay lines and meters.
    func reset() {
        state.update(repeating: 0, count: Self.stateLength)
        centerState.update(repeating: 0, count: Self.centerStateLength)
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

        let routeCount = min(Int(active[0]), Self.maxRoutes)
        let limiter = active[1] != 0
        let sampleRate = active[2]
        let configuredSources = Int(active[3])

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

        // Each tap is one stereo stream after the devices' own (disabled) inputs.
        let firstSource = firstInputBuffer < inList.count ? firstInputBuffer : 0
        let sourceCount = min(max(configuredSources, 1), inList.count - firstSource, Self.maxSources)
        guard sourceCount > 0 else { return }
        var frames = Self.maxFrames
        for s in 0..<sourceCount {
            let buffer = inList[firstSource + s]
            guard buffer.mData != nil, buffer.mNumberChannels > 0 else { continue }
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels)))
        }

        // Mix the sources into the EQ bus and the unchanged bus.
        let busBytes = frames * MemoryLayout<Float>.size
        memset(eqLeft, 0, busBytes)
        memset(eqRight, 0, busBytes)
        memset(dryLeft, 0, busBytes)
        memset(dryRight, 0, busBytes)
        for s in 0..<sourceCount {
            let buffer = inList[firstSource + s]
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let samples = data.assumingMemoryBound(to: Float.self)
            let gain = Float(configuredSources > 0 ? active[4 + s] : 1)
            let useEQ = configuredSources > 0 ? active[4 + Self.maxSources + s] != 0 : true
            guard gain > 0 else { continue }
            let left = useEQ ? eqLeft : dryLeft
            let right = useEQ ? eqRight : dryRight
            let rightOffset = channels > 1 ? 1 : 0
            for f in 0..<frames {
                left[f] += samples[f * channels] * gain
                right[f] += samples[f * channels + rightOffset] * gain
            }
        }

        let mask = Self.scopeSize - 1
        for r in 0..<routeCount {
            let route = active + Self.globalLength + r * Self.routeLength
            let firstBuffer = Int(route[0])
            let endBuffer = min(outList.count, firstBuffer + Int(route[1]))
            let filterCount = Int(route[2])
            let gain = route[3]
            let delay = Int(route[4])
            let mixMode = Int(route[5])
            let reduction = Float(route[6])
            let centerCount = Int(route[7])
            let coefficients = route + Self.coefficientOffset
            guard firstBuffer < endBuffer else { continue }

            if mixMode == MixMode.centerReduced.rawValue {
                // Band-limit the centre once per cycle; both channels subtract it.
                let cz = centerState + r * Self.centerFilterSlots * 2
                let centerCo = route + Self.routeHeader
                for f in 0..<frames {
                    var m = 0.5 * Double(eqLeft[f] + eqRight[f])
                    for k in 0..<centerCount {
                        let co = centerCo + k * Self.coefficientsPerFilter
                        let y = co[0] * m + cz[2 * k]
                        cz[2 * k] = co[1] * m - co[3] * y + cz[2 * k + 1]
                        cz[2 * k + 1] = co[2] * m - co[4] * y
                        m = y
                    }
                    center[f] = Float(m)
                }
                for k in 0..<(centerCount * 2) where abs(cz[k]) < 1e-20 { cz[k] = 0 }
            }

            var peaks: (Float, Float) = (0, 0)
            var routeChannel = 0
            for i in firstBuffer..<endBuffer {
                let buffer = outList[i]
                guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
                let channels = Int(buffer.mNumberChannels)
                let out = data.assumingMemoryBound(to: Float.self)
                let bufferFrames = min(Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels), frames)

                for c in 0..<channels {
                    let channel = routeChannel + c
                    let isLeft = channel % 2 == 0
                    let eqBus = isLeft ? eqLeft : eqRight
                    let dryBus = isLeft ? dryLeft : dryRight
                    let useEQ = channel < Self.maxChannelsPerRoute
                    let z = state + (r * Self.maxChannelsPerRoute + (useEQ ? channel : 0)) * Self.maxFilters * 2
                    let delayed = delay > 0 && channel < Self.delayedChannels
                    let slot = r * Self.delayedChannels + min(channel, Self.delayedChannels - 1)
                    let line = delayLines + slot * Self.maxDelayFrames
                    var position = delayPositions[slot]
                    let writesScope = r == 0 && channel == 0
                    let scopeStart = scopePosition.pointee
                    var peak: Float = 0

                    for f in 0..<bufferFrames {
                        var x: Double
                        switch mixMode {
                        case MixMode.mono.rawValue: x = 0.5 * Double(eqLeft[f] + eqRight[f])
                        case MixMode.centerReduced.rawValue: x = Double(eqBus[f] - reduction * center[f])
                        default: x = Double(eqBus[f])
                        }
                        if useEQ {
                            for k in 0..<filterCount {
                                let co = coefficients + k * Self.coefficientsPerFilter
                                let y = co[0] * x + z[2 * k]
                                z[2 * k] = co[1] * x - co[3] * y + z[2 * k + 1]
                                z[2 * k + 1] = co[2] * x - co[4] * y
                                x = y
                            }
                        }
                        x = x * gain + Double(dryBus[f])
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

                    if delayed { delayPositions[slot] = position }
                    if writesScope { scopePosition.pointee = (scopeStart + bufferFrames) & mask }
                    if channel == 0 { peaks.0 = peak } else if channel == 1 { peaks.1 = peak }

                    // Flush denormals so silence stays cheap.
                    if useEQ {
                        for k in 0..<(filterCount * 2) where abs(z[k]) < 1e-20 { z[k] = 0 }
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
