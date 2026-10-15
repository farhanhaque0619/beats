import AppKit
import SwiftUI

// MARK: - Device colours

extension DeviceKind {
    var tint: Color {
        switch self {
        case .beatsStudioPro: Color(red: 0.93, green: 0.17, blue: 0.27)
        case .airPodsPro2: Color(red: 0.16, green: 0.53, blue: 1.0)
        case .marshallActon3: Color(red: 0.85, green: 0.60, blue: 0.22)
        case .other: Color(red: 0.45, green: 0.40, blue: 0.96)
        }
    }
}

extension DeviceProfile {
    var tint: Color { kind.tint }
}

// MARK: - Liquid Glass

/// Liquid Glass on macOS 26 and later; a frosted material with a specular edge before that.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    var interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.18)) }
        if interactive { glass = glass.interactive() }
        return glass
    }
    #endif

    private func fallback(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint.opacity(0.10)) }
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.45), Color.white.opacity(0.08), Color.white.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
            }
            .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// A content card: glass surface with comfortable inner padding.
    func glassCard(tint: Color? = nil) -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 22, tint: tint)
    }
}

/// Groups neighbouring glass shapes so they blend like one material on macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Backdrop

/// A soft wash of the device's colour that gives the glass something to refract.
struct AmbientBackground: View {
    let tint: Color

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [tint.opacity(0.30), .clear], center: UnitPoint(x: 0.08, y: 0.0), startRadius: 0, endRadius: 560)
            RadialGradient(colors: [tint.opacity(0.16), .clear], center: UnitPoint(x: 1.0, y: 0.55), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [tint.opacity(0.10), .clear], center: UnitPoint(x: 0.3, y: 1.05), startRadius: 0, endRadius: 480)
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.6), value: tint)
    }
}

// MARK: - Small shared pieces

/// Device icon on a glossy coloured tile.
struct DeviceBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28
    var dimmed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(tint.gradient)
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
        }
        .frame(width: size, height: size)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.55 : 1)
    }
}

/// Coloured dot plus text that reports what a device is doing.
struct StatusPill: View {
    let status: DeviceStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(status.color)
                .symbolEffect(.pulse, options: .repeating, isActive: status == .equalizing)
            Text(status.title)
                .font(.callout.weight(.medium))
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .glassSurface(cornerRadius: 100)
        .animation(.smooth(duration: 0.3), value: status)
    }
}

/// A capsule button for choosing a preset.
struct PresetChip: View {
    let title: String
    let isSelected: Bool
    let tint: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(tint.gradient)
                            .shadow(color: tint.opacity(0.45), radius: 8, y: 3)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassSurface(cornerRadius: 100, interactive: true)
        .scaleEffect(isHovering ? 1.04 : 1)
        .animation(.snappy(duration: 0.18), value: isHovering)
        .animation(.smooth(duration: 0.3), value: isSelected)
        .onHover { isHovering = $0 }
    }
}
