import CoreAudio
import Foundation

/// The ten bands of a classic octave graphic EQ.
enum EQBands {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    static let range: ClosedRange<Double> = -12...12
    static let q = 1.41

    /// Corner frequency of the one-knob "Bass Boost" shelf.
    static let bassShelfFrequency = 110.0
    static let bassBoostRange: ClosedRange<Double> = 0...12

    static var flat: [Double] { Array(repeating: 0, count: frequencies.count) }
}

struct EQPreset: Identifiable, Hashable, Codable {
    var name: String
    var gains: [Double]
    /// Saved presets remember Bass Boost too; built-in ones leave it as it is.
    var bassBoost: Double?
    var isCustom = false
    var id: String { name }

    static let flat = EQPreset(name: "Flat", gains: EQBands.flat)

    static let library: [EQPreset] = [
        .flat,
        EQPreset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Deep Bass", gains: [8, 7, 4.5, 1, -0.5, 0, 0, 0, 0, 0]),
        EQPreset(name: "Warm", gains: [3, 3, 2.5, 1.5, 0.5, 0, -0.5, -1, -1, -1]),
        EQPreset(name: "V-Shape", gains: [5, 4.5, 2.5, 0, -1.5, -2, -1, 1.5, 3, 3.5]),
        EQPreset(name: "Loudness", gains: [4.5, 3.5, 1.5, 0, 0, 0, 0, 1, 2.5, 3]),
        EQPreset(name: "Vocal", gains: [-2, -1.5, -0.5, 0.5, 2, 3, 3, 2, 1, 0]),
    ]
}

/// The products Overdrive has a tuned starting point for.
enum DeviceKind: String, Codable, CaseIterable {
    case beatsStudioPro
    case airPodsPro2
    case marshallActon3
    case other

    var productName: String {
        switch self {
        case .beatsStudioPro: "Beats Studio Pro"
        case .airPodsPro2: "AirPods Pro 2"
        case .marshallActon3: "Marshall Acton III"
        case .other: "Output Device"
        }
    }

    var symbolName: String {
        switch self {
        case .beatsStudioPro: "beats.headphones"
        case .airPodsPro2: "airpods.pro"
        case .marshallActon3: "hifispeaker.fill"
        case .other: "speaker.wave.2.fill"
        }
    }

    var category: String {
        switch self {
        case .beatsStudioPro: "Over-ear headphones"
        case .airPodsPro2: "In-ear headphones"
        case .marshallActon3: "Bluetooth speaker"
        case .other: "Speaker or headphones"
        }
    }

    /// Bass-forward tuning written for each product's own sound.
    var signature: EQPreset? {
        switch self {
        case .beatsStudioPro:
            // Studio Pro is tuned much flatter than older Beats; this restores a full low end.
            EQPreset(name: "Signature Bass", gains: [6, 5.5, 4, 1.5, 0, -0.5, 0, 1, 1, 0.5])
        case .airPodsPro2:
            // Adaptive EQ already lifts the lows; a smaller sub lift keeps it clean.
            EQPreset(name: "Signature Bass", gains: [3.5, 3, 2, 0.5, 0, 0, 0, 0, 0.5, 0.5])
        case .marshallActon3:
            // The woofer can't reproduce 32 Hz, so the lift sits in the upper bass instead.
            EQPreset(name: "Signature Bass", gains: [0, 2.5, 4, 2, 0, 0, 0, 0, 0.5, 1])
        case .other:
            nil
        }
    }

    var tip: String {
        switch self {
        case .beatsStudioPro:
            "Studio Pro has no bass control of its own, so this EQ is the way to add it. A good seal matters too: low end drops off quickly if the ear cushions sit loose."
        case .airPodsPro2:
            "Run the Ear Tip Fit Test in Bluetooth settings. The wrong tip size loses more bass than any EQ can add back."
        case .marshallActon3:
            "Acton III also has a Bass knob on top. Turn it up first, then fine-tune here. Placing it near a wall adds more low end."
        case .other:
            "Changes apply to everything your Mac plays through this device. While the EQ is flat, Overdrive doesn’t process audio at all."
        }
    }

    /// A fitting SF Symbol for an output we have no tuned profile for.
    static func symbol(forName name: String, transportType: UInt32) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpods.max" }
        if n.contains("airpods pro") { return "airpods.pro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("homepod") { return "homepod.fill" }
        if n.contains("headphone") || n.contains("headset") || n.contains("buds") || n.contains("wh-") { return "headphones" }
        if n.contains("macbook") { return "laptopcomputer" }
        if n.contains("imac") { return "desktopcomputer" }
        if n.contains("mac mini") { return "macmini.fill" }
        if n.contains("mac studio") { return "macstudio.fill" }
        if n.contains("tv") { return "tv" }
        switch transportType {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB:
            return "cable.connector"
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeVirtual:
            return "waveform"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "hifispeaker.fill"
        default:
            return "speaker.wave.2.fill"
        }
    }

    static func detect(deviceName: String) -> DeviceKind {
        let name = deviceName.lowercased()
        if name.contains("beats studio pro") || name.contains("studio pro") { return .beatsStudioPro }
        if name.contains("airpods pro") { return .airPodsPro2 }
        if name.contains("acton") { return .marshallActon3 }
        return .other
    }
}

struct DeviceProfile: Codable, Identifiable, Equatable {
    var id: String
    var kind: DeviceKind
    var displayName: String
    var isEnabled: Bool
    var gains: [Double]
    var bassBoost: Double
    var preampDB: Double
    var preventsClipping: Bool
    var presetName: String
    /// SF Symbol picked when the device was first seen. Optional so older saves still load.
    var iconName: String?
    /// Whether this device has ever connected to this Mac. Tuned profiles stay hidden until
    /// then, so a Mac without those headphones doesn't list them. Older saves read as seen.
    var seen: Bool?

    var hasBeenSeen: Bool { seen ?? true }
    var symbolName: String { iconName ?? kind.symbolName }

    /// True when the settings wouldn't change the sound, so no processing is needed.
    var isFlat: Bool {
        gains.allSatisfy { abs($0) < 0.05 } && abs(bassBoost) < 0.05 && (preventsClipping || abs(preampDB) < 0.05)
    }

    static func standard(for kind: DeviceKind) -> DeviceProfile {
        let preset = kind.signature ?? .flat
        return DeviceProfile(
            id: kind.rawValue,
            kind: kind,
            displayName: kind.productName,
            isEnabled: true,
            gains: preset.gains,
            bassBoost: 0,
            preampDB: 0,
            preventsClipping: true,
            presetName: preset.name,
            seen: false
        )
    }

    /// Any other output. It starts flat, which costs nothing: processing only runs once
    /// something is actually changed.
    static func other(uid: String, name: String, transportType: UInt32 = 0) -> DeviceProfile {
        DeviceProfile(
            id: "device:" + uid,
            kind: .other,
            displayName: name,
            isEnabled: true,
            gains: EQBands.flat,
            bassBoost: 0,
            preampDB: 0,
            preventsClipping: true,
            presetName: EQPreset.flat.name,
            iconName: DeviceKind.symbol(forName: name, transportType: transportType)
        )
    }

    var presets: [EQPreset] {
        (kind.signature.map { [$0] } ?? []) + EQPreset.library
    }

    mutating func apply(_ preset: EQPreset) {
        gains = preset.gains
        if let bassBoost = preset.bassBoost { self.bassBoost = bassBoost }
        presetName = preset.name
    }

    // MARK: - Filter design

    func filters(sampleRate: Double) -> [Biquad] {
        Self.filters(gains: gains, bassBoost: bassBoost, sampleRate: sampleRate)
    }

    static func filters(gains: [Double], bassBoost: Double, sampleRate: Double) -> [Biquad] {
        var filters = EQBands.frequencies.enumerated().map { index, frequency in
            let shape: Biquad.Shape = switch index {
            case 0: .lowShelf
            case EQBands.frequencies.count - 1: .highShelf
            default: .peaking
            }
            let q = shape == .peaking ? EQBands.q : 0.71
            let gain = index < gains.count ? gains[index] : 0
            return Biquad(shape: shape, frequency: frequency, gainDB: gain, q: q, sampleRate: sampleRate)
        }
        filters.append(Biquad(shape: .lowShelf, frequency: EQBands.bassShelfFrequency, gainDB: bassBoost, q: 0.71, sampleRate: sampleRate))
        return filters
    }

    /// Combined EQ response in dB, before output gain.
    static func response(at frequency: Double, filters: [Biquad], sampleRate: Double) -> Double {
        filters.reduce(0) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
    }

    func peakBoostDB(sampleRate: Double = 48_000) -> Double {
        let filters = filters(sampleRate: sampleRate)
        var peak = 0.0
        for i in 0..<160 {
            let frequency = 20 * pow(1_000, Double(i) / 159)
            peak = max(peak, Self.response(at: frequency, filters: filters, sampleRate: sampleRate))
        }
        return peak
    }

    /// Output gain in dB. With clipping protection on, the loudest boost is offset exactly.
    var effectivePreampDB: Double {
        preventsClipping ? -peakBoostDB() : preampDB
    }
}

/// What one device plays in Multi-Output, so speakers can split the music between them.
enum SpeakerRole: String, Codable, CaseIterable, Identifiable {
    case full
    case vocals
    case music
    case bass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Full Sound"
        case .vocals: "Vocals"
        case .music: "Music & Bass"
        case .bass: "Bass Only"
        }
    }

    var symbolName: String {
        switch self {
        case .full: "speaker.wave.3.fill"
        case .vocals: "music.mic"
        case .music: "guitars.fill"
        case .bass: "waveform.path"
        }
    }

    var detail: String {
        switch self {
        case .full:
            "Everything, as mixed."
        case .vocals:
            "The centre of the mix, where singers and dialogue sit, with the bass taken out and a little extra clarity. Ideal for laptop speakers."
        case .music:
            "Turns the vocals well down and keeps the instruments, stereo width and full bass, with a gentle bass lift."
        case .bass:
            "Only the low end below about 130 Hz, like a subwoofer."
        }
    }

    var mixMode: EQProcessor.MixMode {
        switch self {
        case .full: .stereo
        case .vocals, .bass: .mono
        case .music: .centerReduced
        }
    }

    /// How much of the centred mid-band the Music & Bass role removes.
    var centerReduction: Double { self == .music ? 0.75 : 0 }

    /// The band treated as "vocals" when turning them down: roughly 250 Hz to 6 kHz.
    func centerFilters(sampleRate: Double) -> [Biquad] {
        guard self == .music else { return [] }
        return [
            Biquad(shape: .highPass, frequency: 250, gainDB: 0, q: 0.71, sampleRate: sampleRate),
            Biquad(shape: .lowPass, frequency: 6_000, gainDB: 0, q: 0.71, sampleRate: sampleRate),
        ]
    }

    /// Tone shaping for the role, applied before the device's own EQ.
    func filters(sampleRate: Double) -> [Biquad] {
        switch self {
        case .full:
            return []
        case .vocals:
            return [
                Biquad(shape: .highPass, frequency: 170, gainDB: 0, q: 0.71, sampleRate: sampleRate),
                Biquad(shape: .highPass, frequency: 170, gainDB: 0, q: 0.71, sampleRate: sampleRate),
                Biquad(shape: .peaking, frequency: 2_800, gainDB: 3, q: 1.0, sampleRate: sampleRate),
            ]
        case .music:
            return [Biquad(shape: .lowShelf, frequency: 100, gainDB: 3, q: 0.71, sampleRate: sampleRate)]
        case .bass:
            return [
                Biquad(shape: .lowPass, frequency: 130, gainDB: 0, q: 0.71, sampleRate: sampleRate),
                Biquad(shape: .lowPass, frequency: 130, gainDB: 0, q: 0.71, sampleRate: sampleRate),
            ]
        }
    }
}
