import Foundation

/// Normalised biquad coefficients (a0 == 1), from the RBJ Audio EQ Cookbook.
struct Biquad: Equatable {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    enum Shape { case peaking, lowShelf, highShelf }

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    init(shape: Shape, frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        guard abs(gainDB) > 0.001, frequency < sampleRate * 0.49 else {
            self.init(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
            return
        }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0)
        let sinW = sin(w0)
        let alpha = sinW / (2 * q)

        let b0, b1, b2, a0, a1, a2: Double
        switch shape {
        case .peaking:
            b0 = 1 + alpha * a
            b1 = -2 * cosW
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW
            a2 = 1 - alpha / a
        case .lowShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW + s)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
            b2 = a * ((a + 1) - (a - 1) * cosW - s)
            a0 = (a + 1) + (a - 1) * cosW + s
            a1 = -2 * ((a - 1) + (a + 1) * cosW)
            a2 = (a + 1) + (a - 1) * cosW - s
        case .highShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW + s)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
            b2 = a * ((a + 1) + (a - 1) * cosW - s)
            a0 = (a + 1) - (a - 1) * cosW + s
            a1 = 2 * ((a - 1) - (a + 1) * cosW)
            a2 = (a + 1) - (a - 1) * cosW - s
        }
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Gain in dB of this filter at `frequency`.
    func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w), cos2 = cos(2 * w)
        let num = b0 * b0 + b1 * b1 + b2 * b2 + 2 * (b0 * b1 + b1 * b2) * cos1 + 2 * b0 * b2 * cos2
        let den = 1 + a1 * a1 + a2 * a2 + 2 * (a1 + a1 * a2) * cos1 + 2 * a2 * cos2
        guard num > 0, den > 0 else { return 0 }
        return 10 * log10(num / den)
    }
}
