import Accelerate
import SwiftUI

/// Turns the processor's most recent output into smoothed, log-spaced band levels.
/// Runs on the main thread once per display frame; a 2048-point FFT takes microseconds.
final class SpectrumAnalyzer: ObservableObject {
    static let barCount = 64
    private static let log2n: vDSP_Length = 11
    private static let size = 1 << 11
    private static let half = size / 2

    private let setup: FFTSetup
    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: size)
    private let window = UnsafeMutablePointer<Float>.allocate(capacity: size)
    private let real = UnsafeMutablePointer<Float>.allocate(capacity: half)
    private let imag = UnsafeMutablePointer<Float>.allocate(capacity: half)
    private let magnitudes = UnsafeMutablePointer<Float>.allocate(capacity: half)
    private(set) var levels = [Float](repeating: 0, count: barCount)

    init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        samples.deallocate()
        window.deallocate()
        real.deallocate()
        imag.deallocate()
        magnitudes.deallocate()
    }

    /// Reads fresh audio and returns bar levels from 0 to 1.
    func update(from processor: EQProcessor, sampleRate: Double) -> [Float] {
        processor.copyScope(into: samples, count: Self.size)
        vDSP_vmul(samples, 1, window, 1, samples, 1, vDSP_Length(Self.size))

        var split = DSPSplitComplex(realp: real, imagp: imag)
        samples.withMemoryRebound(to: DSPComplex.self, capacity: Self.half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.half))
        }
        vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, magnitudes, 1, vDSP_Length(Self.half))

        // A full-scale sine reads about 0 dB after the window and FFT scaling.
        let reference = Float(Self.size) * Float(Self.size) / 4
        let binWidth = sampleRate / Double(Self.size)
        for bar in 0..<Self.barCount {
            let lowFrequency = 20 * pow(1_000, Double(bar) / Double(Self.barCount))
            let highFrequency = 20 * pow(1_000, Double(bar + 1) / Double(Self.barCount))
            let low = max(Int(lowFrequency / binWidth), 1)
            let high = min(max(Int(highFrequency / binWidth), low), Self.half - 1)
            var peak: Float = 0
            for bin in low...high { peak = max(peak, magnitudes[bin]) }
            let db = 10 * log10(max(peak / reference, 1e-12))
            let target = min(max((db + 72) / 72, 0), 1)
            // Fast attack, slow release, like a real analyser's ballistics.
            let current = levels[bar]
            levels[bar] = target > current ? current + (target - current) * 0.6 : current + (target - current) * 0.12
        }
        return levels
    }

    func decay() -> [Float] {
        for i in levels.indices { levels[i] *= 0.85 }
        return levels
    }
}

/// A soft, filled spectrum drawn every display frame behind the EQ curve.
struct SpectrumView: View {
    let processor: EQProcessor
    let sampleRate: Double
    let tint: Color
    let isActive: Bool

    // StateObject builds the FFT setup once, not on every parent redraw.
    @StateObject private var analyzer = SpectrumAnalyzer()

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isActive)) { _ in
            let levels = isActive ? analyzer.update(from: processor, sampleRate: sampleRate) : analyzer.decay()
            Canvas { context, size in
                guard levels.contains(where: { $0 > 0.01 }) else { return }
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                let step = size.width / CGFloat(levels.count - 1)
                var previous = CGPoint(x: 0, y: size.height * CGFloat(1 - levels[0]))
                path.addLine(to: previous)
                for i in 1..<levels.count {
                    let point = CGPoint(x: CGFloat(i) * step, y: size.height * CGFloat(1 - levels[i]))
                    let mid = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
                    path.addQuadCurve(to: mid, control: previous)
                    previous = point
                }
                path.addLine(to: previous)
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.28), tint.opacity(0.06)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                ))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
