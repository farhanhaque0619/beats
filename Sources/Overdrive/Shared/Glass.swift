import AppKit
import SwiftUI

// MARK: - Theme

enum AccentStyle: String, CaseIterable, Identifiable {
    case system
    case graphite

    var id: String { rawValue }
    var title: String { self == .system ? "System Accent" : "Graphite" }
}

/// One restrained accent for the whole app: the Mac's own accent colour, or graphite.
/// Everything else is neutral, so the screen stays calm.
enum Theme {
    static var accentStyle: AccentStyle {
        AccentStyle(rawValue: UserDefaults.standard.string(forKey: SettingsKey.accentStyle) ?? "") ?? .system
    }

    static var accent: Color {
        accentStyle == .graphite ? Color(nsColor: .systemGray) : Color.accentColor
    }
}

extension DeviceKind {
    var tint: Color { Theme.accent }
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
        if let tint { glass = glass.tint(tint.opacity(0.06)) }
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
                    if let tint { shape.fill(tint.opacity(0.04)) }
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
            RadialGradient(colors: [tint.opacity(0.07), .clear], center: UnitPoint(x: 0.08, y: 0.0), startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Color.primary.opacity(0.035), .clear], center: UnitPoint(x: 1.0, y: 0.7), startRadius: 0, endRadius: 560)
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.6), value: tint)
    }
}

// MARK: - Small shared pieces

/// Device or section icon on a quiet, neutral tile.
struct DeviceBadge: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 28
    var dimmed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            shape.fill(Color.primary.opacity(dimmed ? 0.04 : 0.07))
            shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
        .frame(width: size, height: size)
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
    var compact = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font((compact ? Font.caption : Font.callout).weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 5 : 7)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(tint.gradient)
                            .shadow(color: tint.opacity(0.18), radius: 6, y: 2)
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
