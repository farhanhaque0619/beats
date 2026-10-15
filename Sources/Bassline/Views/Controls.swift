import SwiftUI

/// A Music-app style vertical fader for one EQ band.
struct VerticalGainSlider: View {
    static let knobInset: CGFloat = 10

    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let y = position(for: value, height: height)
            let zeroY = position(for: 0, height: height)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 5)
                    .padding(.vertical, Self.knobInset)

                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 16, height: 1)
                    .offset(y: zeroY)

                Capsule()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 5, height: max(abs(y - zeroY), 0))
                    .offset(y: min(y, zeroY))

                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(isDragging ? 0.35 : 0.22), radius: isDragging ? 4 : 2, y: 1)
                    .frame(width: 2 * Self.knobInset, height: 2 * Self.knobInset)
                    .scaleEffect(isDragging ? 1.12 : 1)
                    .offset(y: y - Self.knobInset)
            }
            .frame(width: geo.size.width, height: height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging { withAnimation(.snappy(duration: 0.15)) { isDragging = true } }
                        value = self.value(for: drag.location.y, height: height)
                    }
                    .onEnded { _ in
                        withAnimation(.snappy(duration: 0.2)) { isDragging = false }
                    }
            )
        }
        .contextMenu {
            Button("Reset to 0 dB") { value = 0 }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.1f decibels", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + 0.5)
            case .decrement: value = max(range.lowerBound, value - 0.5)
            @unknown default: break
            }
        }
    }

    private func position(for value: Double, height: CGFloat) -> CGFloat {
        let track = height - 2 * Self.knobInset
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return Self.knobInset + (1 - fraction) * track
    }

    private func value(for y: CGFloat, height: CGFloat) -> Double {
        let track = max(height - 2 * Self.knobInset, 1)
        let fraction = 1 - (y - Self.knobInset) / track
        let raw = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
        return min(max(raw, range.lowerBound), range.upperBound)
    }
}

/// The combined EQ curve, drawn on a log-frequency grid.
struct EQCurveView: View {
    let profile: DeviceProfile
    var compact = false

    private static let sampleRate = 48_000.0
    private static let dbRange = 18.0
    private static let gridFrequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    private static let minFrequency = 20.0
    private static let maxFrequency = 20_000.0

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = compact ? 0 : 34
            let bottom: CGFloat = compact ? 0 : 18
            let plot = CGRect(x: left, y: 4, width: size.width - left, height: size.height - bottom - 8)
            let filters = profile.filters(sampleRate: Self.sampleRate)

            func x(_ frequency: Double) -> CGFloat {
                let t = log(frequency / Self.minFrequency) / log(Self.maxFrequency / Self.minFrequency)
                return plot.minX + CGFloat(t) * plot.width
            }
            func y(_ db: Double) -> CGFloat {
                let clamped = min(max(db, -Self.dbRange), Self.dbRange)
                return plot.midY - CGFloat(clamped / Self.dbRange) * plot.height / 2
            }

            // Grid
            let gridColor = Color.secondary.opacity(compact ? 0.12 : 0.18)
            for db in stride(from: -12.0, through: 12.0, by: 6.0) {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(db)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(db)))
                context.stroke(line, with: .color(db == 0 ? Color.secondary.opacity(0.35) : gridColor), lineWidth: db == 0 ? 1 : 0.5)
                if !compact {
                    let text = Text(db > 0 ? "+\(Int(db))" : "\(Int(db))")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                    context.draw(text, at: CGPoint(x: left - 8, y: y(db)), anchor: .trailing)
                }
            }
            for (index, frequency) in Self.gridFrequencies.enumerated() {
                var line = Path()
                line.move(to: CGPoint(x: x(frequency), y: plot.minY))
                line.addLine(to: CGPoint(x: x(frequency), y: plot.maxY))
                context.stroke(line, with: .color(gridColor), lineWidth: 0.5)
                if !compact {
                    let text = Text(EQBands.labels[index])
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    context.draw(text, at: CGPoint(x: x(frequency), y: plot.maxY + 11), anchor: .center)
                }
            }

            // Curve
            let steps = compact ? 90 : 220
            var curve = Path()
            var fill = Path()
            fill.move(to: CGPoint(x: plot.minX, y: y(0)))
            for i in 0...steps {
                let frequency = Self.minFrequency * pow(Self.maxFrequency / Self.minFrequency, Double(i) / Double(steps))
                let point = CGPoint(x: x(frequency), y: y(profile.response(at: frequency, filters: filters, sampleRate: Self.sampleRate)))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                fill.addLine(to: point)
            }
            fill.addLine(to: CGPoint(x: plot.maxX, y: y(0)))
            fill.closeSubpath()

            let tint = profile.isEnabled ? Color.accentColor : Color.secondary
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.32), tint.opacity(0.04)]),
                    startPoint: CGPoint(x: 0, y: plot.minY),
                    endPoint: CGPoint(x: 0, y: y(0))
                )
            )
            context.stroke(curve, with: .color(tint), style: StrokeStyle(lineWidth: compact ? 1.75 : 2.25, lineCap: .round, lineJoin: .round))

            if !compact {
                for (index, frequency) in EQBands.frequencies.enumerated() where profile.gains[index] != 0 {
                    let center = CGPoint(x: x(frequency), y: y(profile.response(at: frequency, filters: filters, sampleRate: Self.sampleRate)))
                    let dot = Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
                    context.fill(dot, with: .color(.white))
                    context.stroke(dot, with: .color(tint), lineWidth: 1.5)
                }
            }
        }
        .accessibilityLabel("Frequency response")
        .accessibilityValue(String(format: "Peak boost %.1f decibels", profile.peakBoostDB()))
    }
}
