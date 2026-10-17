import AppKit
import SwiftUI

// MARK: - Animatable EQ values

/// The ten band gains plus Bass Boost, as something SwiftUI can interpolate. Animating
/// this vector (instead of the drawn points) lets the curve morph between presets at
/// the display's full refresh rate, 120 Hz on ProMotion screens.
struct EQVector: VectorArithmetic {
    var values: [Double]

    init(_ values: [Double]) { self.values = values }

    init(_ profile: DeviceProfile) {
        values = profile.gains + [profile.bassBoost]
    }

    var gains: [Double] { Array(values.prefix(EQBands.frequencies.count)) }
    var bassBoost: Double { values.count > EQBands.frequencies.count ? values[EQBands.frequencies.count] : 0 }

    static var zero: EQVector { EQVector([]) }

    static func + (lhs: EQVector, rhs: EQVector) -> EQVector { combine(lhs, rhs, +) }
    static func - (lhs: EQVector, rhs: EQVector) -> EQVector { combine(lhs, rhs, -) }

    mutating func scale(by rhs: Double) {
        for i in values.indices { values[i] *= rhs }
    }

    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    private static func combine(_ lhs: EQVector, _ rhs: EQVector, _ op: (Double, Double) -> Double) -> EQVector {
        let count = max(lhs.values.count, rhs.values.count)
        var result = [Double](repeating: 0, count: count)
        for i in 0..<count {
            result[i] = op(i < lhs.values.count ? lhs.values[i] : 0, i < rhs.values.count ? rhs.values[i] : 0)
        }
        return EQVector(result)
    }
}

// MARK: - Response curve

enum CurveGeometry {
    static let sampleRate = 48_000.0
    static let dbRange = 18.0
    static let minFrequency = 20.0
    static let maxFrequency = 20_000.0

    static func x(_ frequency: Double, in rect: CGRect) -> CGFloat {
        let t = log(frequency / minFrequency) / log(maxFrequency / minFrequency)
        return rect.minX + CGFloat(t) * rect.width
    }

    static func y(_ db: Double, in rect: CGRect) -> CGFloat {
        let clamped = min(max(db, -dbRange), dbRange)
        return rect.midY - CGFloat(clamped / dbRange) * rect.height / 2
    }
}

/// The combined EQ response as a line, a filled area, or band markers.
struct ResponseShape: Shape {
    enum Style { case line, area, markers }

    var vector: EQVector
    var style: Style

    var animatableData: EQVector {
        get { vector }
        set { vector = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let filters = DeviceProfile.filters(gains: vector.gains, bassBoost: vector.bassBoost, sampleRate: CurveGeometry.sampleRate)
        func response(_ frequency: Double) -> Double {
            DeviceProfile.response(at: frequency, filters: filters, sampleRate: CurveGeometry.sampleRate)
        }

        var path = Path()
        switch style {
        case .markers:
            let gains = vector.gains
            for (index, frequency) in EQBands.frequencies.enumerated() where index < gains.count && abs(gains[index]) >= 0.05 {
                let center = CGPoint(x: CurveGeometry.x(frequency, in: rect), y: CurveGeometry.y(response(frequency), in: rect))
                path.addEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
            }
        case .line, .area:
            let steps = max(Int(rect.width / 3), 48)
            let zeroY = CurveGeometry.y(0, in: rect)
            if style == .area { path.move(to: CGPoint(x: rect.minX, y: zeroY)) }
            for i in 0...steps {
                let frequency = CurveGeometry.minFrequency
                    * pow(CurveGeometry.maxFrequency / CurveGeometry.minFrequency, Double(i) / Double(steps))
                let point = CGPoint(x: CurveGeometry.x(frequency, in: rect), y: CurveGeometry.y(response(frequency), in: rect))
                if i == 0 && style == .line { path.move(to: point) } else { path.addLine(to: point) }
            }
            if style == .area {
                path.addLine(to: CGPoint(x: rect.maxX, y: zeroY))
                path.closeSubpath()
            }
        }
        return path
    }
}

/// Grid and labels behind the curve. Drawn once per size change, never per frame.
private struct CurveGrid: View {
    let compact: Bool
    let insets: EdgeInsets

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(
                x: insets.leading, y: insets.top,
                width: size.width - insets.leading - insets.trailing,
                height: size.height - insets.top - insets.bottom
            )
            let grid = Color.primary.opacity(compact ? 0.06 : 0.08)
            for db in stride(from: -12.0, through: 12.0, by: 6.0) {
                let y = CurveGeometry.y(db, in: plot)
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y))
                line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(db == 0 ? Color.primary.opacity(0.18) : grid), lineWidth: db == 0 ? 1 : 0.5)
                if !compact {
                    let label = Text(db > 0 ? "+\(Int(db))" : "\(Int(db))")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                    context.draw(label, at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
                }
            }
            for (index, frequency) in EQBands.frequencies.enumerated() {
                let x = CurveGeometry.x(frequency, in: plot)
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: .color(grid), lineWidth: 0.5)
                if !compact {
                    let label = Text(EQBands.labels[index]).font(.caption2).foregroundColor(.secondary)
                    context.draw(label, at: CGPoint(x: x, y: plot.maxY + 12), anchor: .center)
                }
            }
        }
    }
}

struct ResponseCurveView: View {
    let profile: DeviceProfile
    var compact = false
    /// Live spectrum source, drawn behind the curve when set.
    var processor: EQProcessor? = nil
    var sampleRate: Double = 48_000
    var spectrumActive = false
    /// When set, every band gets a handle on the curve that can be dragged up and down.
    var onBandChange: ((Int, Double) -> Void)? = nil

    var body: some View {
        let insets = compact
            ? EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
            : EdgeInsets(top: 8, leading: 34, bottom: 24, trailing: 8)
        let tint = profile.isEnabled ? profile.tint : Color.secondary
        let vector = EQVector(profile)

        ZStack {
            CurveGrid(compact: compact, insets: insets)

            if let processor {
                SpectrumView(processor: processor, sampleRate: sampleRate, tint: tint, isActive: spectrumActive)
                    .padding(insets)
                    .transition(.opacity)
            }

            ZStack {
                ResponseShape(vector: vector, style: .area)
                    .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                ResponseShape(vector: vector, style: .line)
                    .stroke(tint.opacity(0.18), style: StrokeStyle(lineWidth: compact ? 5 : 8, lineCap: .round, lineJoin: .round))
                    .blur(radius: compact ? 3 : 6)
                ResponseShape(vector: vector, style: .line)
                    .stroke(tint, style: StrokeStyle(lineWidth: compact ? 1.75 : 2.5, lineCap: .round, lineJoin: .round))
                if !compact && onBandChange == nil {
                    ResponseShape(vector: vector, style: .markers).fill(.white)
                    ResponseShape(vector: vector, style: .markers).stroke(tint, lineWidth: 1.5)
                }
            }
            .padding(insets)
            .drawingGroup()
            .allowsHitTesting(false)

            if let onBandChange, !compact {
                CurveHandles(profile: profile, tint: tint, onChange: onBandChange)
                    .padding(insets)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frequency response")
        .accessibilityValue(String(format: "Peak boost %.1f decibels", profile.peakBoostDB()))
    }
}

/// One grab point per band, sitting on the curve. Dragging moves that band's gain.
private struct CurveHandles: View {
    let profile: DeviceProfile
    let tint: Color
    let onChange: (Int, Double) -> Void

    @State private var dragging: (band: Int, startGain: Double)?
    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let filters = profile.filters(sampleRate: CurveGeometry.sampleRate)
            ForEach(EQBands.frequencies.indices, id: \.self) { band in
                let frequency = EQBands.frequencies[band]
                let response = DeviceProfile.response(at: frequency, filters: filters, sampleRate: CurveGeometry.sampleRate)
                let isActive = dragging?.band == band
                let isSet = abs(profile.gains[band]) >= 0.05
                ZStack {
                    Circle()
                        .fill(isActive || isSet ? Color.white : Color.white.opacity(0.75))
                        .overlay(Circle().strokeBorder(tint, lineWidth: isActive ? 2.5 : 1.5))
                        .shadow(color: tint.opacity(isActive ? 0.6 : 0.25), radius: isActive ? 8 : 3)
                        .frame(width: 13, height: 13)
                        .scaleEffect(isActive ? 1.35 : (hovered == band ? 1.2 : 1))
                        .opacity(isSet || isActive || hovered == band ? 1 : 0.55)
                    if isActive || hovered == band {
                        Text(String(format: "%@  %+.1f dB", EQBands.labels[band], profile.gains[band]))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .glassSurface(cornerRadius: 100)
                            .fixedSize()
                            .offset(y: -22)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .position(x: CurveGeometry.x(frequency, in: rect), y: CurveGeometry.y(response, in: rect))
                .animation(.snappy(duration: 0.18), value: isActive)
                .animation(.snappy(duration: 0.18), value: hovered == band)
                .onHover { inside in hovered = inside ? band : (hovered == band ? nil : hovered) }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if dragging?.band != band { dragging = (band, profile.gains[band]) }
                            let start = dragging?.startGain ?? profile.gains[band]
                            let perPoint = 2 * CurveGeometry.dbRange / Double(max(rect.height, 1))
                            var gain = start - Double(drag.translation.height) * perPoint
                            gain = min(max(gain, EQBands.range.lowerBound), EQBands.range.upperBound)
                            if abs(gain) < 0.35 { gain = 0 }
                            if gain == 0, profile.gains[band] != 0 { Haptics.tick() }
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { onChange(band, gain) }
                        }
                        .onEnded { _ in dragging = nil }
                )
                .help("\(EQBands.labels[band]) Hz. Drag up or down.")
            }
        }
    }
}

enum Haptics {
    /// A light tick on Force Touch trackpads, used when a control snaps to 0 dB.
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - Band fader

/// A vertical fader for one EQ band. While dragging, the knob follows the pointer
/// exactly (no rounding, no implicit animation) so it tracks at the display's refresh rate.
struct VerticalGainSlider: View {
    static let knobSize: CGFloat = 22

    @Binding var value: Double
    let range: ClosedRange<Double>
    let tint: Color
    let label: String

    @State private var dragValue: Double?
    @State private var isHovering = false

    private var shownValue: Double { dragValue ?? value }
    private var isDragging: Bool { dragValue != nil }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let y = position(for: shownValue, height: height)
            let zeroY = position(for: 0, height: height)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: 6)
                    .padding(.vertical, Self.knobSize / 2)

                Capsule()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 14, height: 1.5)
                    .offset(y: zeroY - 0.75)

                Capsule()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 6, height: max(abs(y - zeroY), 0))
                    .shadow(color: tint.opacity(isDragging ? 0.7 : 0.4), radius: isDragging ? 7 : 4)
                    .offset(y: min(y, zeroY))

                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
                    .overlay(Circle().fill(tint).frame(width: 6, height: 6).opacity(isDragging ? 1 : 0))
                    .shadow(color: .black.opacity(isDragging ? 0.30 : 0.18), radius: isDragging ? 6 : 3, y: isDragging ? 3 : 1.5)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .scaleEffect(isDragging ? 1.15 : (isHovering ? 1.06 : 1))
                    .animation(.snappy(duration: 0.2), value: isDragging)
                    .animation(.snappy(duration: 0.2), value: isHovering)
                    .offset(y: y - Self.knobSize / 2)
            }
            .frame(width: geo.size.width, height: height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let newValue = self.value(for: drag.location.y, height: height)
                        if newValue == 0, shownValue != 0 { Haptics.tick() }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            dragValue = newValue
                            value = newValue
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.snappy(duration: 0.2)) { dragValue = nil }
                    }
            )
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Reset to 0 dB") {
                withAnimation(.smooth(duration: 0.35)) { value = 0 }
            }
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
        let track = height - Self.knobSize
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return Self.knobSize / 2 + (1 - fraction) * track
    }

    private func value(for y: CGFloat, height: CGFloat) -> Double {
        let track = max(height - Self.knobSize, 1)
        let fraction = 1 - (y - Self.knobSize / 2) / track
        let raw = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
        // Gentle detent at 0 dB so flattening a band is easy.
        let snapped = abs(raw) < 0.35 ? 0 : raw
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

// MARK: - Live output meter

/// Left/right output level, redrawn every display frame while audio is being processed.
struct LevelMeter: View {
    let processor: EQProcessor
    var route = 0
    let tint: Color
    let isActive: Bool
    var height: CGFloat = 36

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isActive)) { _ in
            HStack(spacing: 3) {
                bar(isActive ? processor.meterLevel(route: route, channel: 0) : 0)
                bar(isActive ? processor.meterLevel(route: route, channel: 1) : 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func bar(_ level: Float) -> some View {
        // Map -48…0 dBFS onto the bar height.
        let db = 20 * log10(max(Double(level), 0.000_01))
        let fraction = CGFloat(min(max((db + 48) / 48, 0), 1))
        return Capsule()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 5)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    .frame(height: max(fraction * height, fraction > 0 ? 5 : 0))
            }
    }
}
