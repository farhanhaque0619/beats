import SwiftUI

// MARK: - Page structure

/// The header card at the top of every page.
struct PageHeader<Accessory: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            DeviceBadge(symbol: symbol, size: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(20)
        .glassSurface(cornerRadius: 26)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(symbol: String, title: String, subtitle: String) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A titled glass card.
struct Card<Content: View, Trailing: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .glassCard()
    }
}

extension Card where Trailing == EmptyView {
    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, trailing: { EmptyView() }, content: content)
    }
}

/// Standard scrolling page layout.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            GlassGroup(spacing: 18) {
                VStack(alignment: .leading, spacing: 16) { content }
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Charts

/// A small line-and-area chart of recent values, newest on the right.
struct Sparkline: View {
    let values: [Double]
    var maximum: Double? = nil
    var capacity = 90

    var body: some View {
        let tint = Theme.accent
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(maximum ?? (values.max() ?? 1), 0.0001)
            let step = size.width / CGFloat(max(capacity - 1, 1))
            let start = size.width - CGFloat(values.count - 1) * step
            func point(_ index: Int) -> CGPoint {
                let fraction = min(max(values[index] / top, 0), 1)
                return CGPoint(x: start + CGFloat(index) * step, y: size.height - CGFloat(fraction) * (size.height - 2) - 1)
            }
            var line = Path()
            line.move(to: point(0))
            for index in 1..<values.count { line.addLine(to: point(index)) }
            var area = line
            area.addLine(to: CGPoint(x: point(values.count - 1).x, y: size.height))
            area.addLine(to: CGPoint(x: start, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.22), tint.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let last = point(values.count - 1)
            context.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(tint))
        }
        .accessibilityHidden(true)
    }
}

/// A circular gauge for a 0…1 value.
struct RingGauge: View {
    let value: Double
    let label: String
    let detail: String
    var size: CGFloat = 92

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 8))
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0), 1)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.6), value: value)
            VStack(spacing: 0) {
                Text(detail)
                    .font(.system(size: size * 0.2, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: value))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(detail)
    }
}

/// A thin horizontal bar for a 0…1 value.
struct MeterBar: View {
    let value: Double
    var height: CGFloat = 6
    var warning = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(warning ? Color.orange : Theme.accent)
                    .frame(width: max(geo.size.width * CGFloat(min(max(value, 0), 1)), value > 0 ? height : 0))
                    .animation(.smooth(duration: 0.5), value: value)
            }
        }
        .frame(height: height)
    }
}

/// A label and a big number, for dashboards.
struct StatValue: View {
    let title: String
    let value: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Formatting

enum Format {
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func diskBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        return "\(Int(celsius.rounded()))°"
    }

    static func minutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        return hours > 0 ? "\(hours) h \(remainder) min" : "\(remainder) min"
    }
}
