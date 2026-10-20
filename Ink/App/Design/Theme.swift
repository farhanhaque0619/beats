import SwiftUI
import InkCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Ink's whole look lives here: black and white, type does the work, one accent for the hint of
// colour. Views use these tokens instead of literal colours, sizes or animations.

// MARK: - Colour

extension Color {
    /// A colour that switches between light and dark appearance.
    init(light: Color, dark: Color) {
        self.init(light: light, dark: dark, lightHighContrast: light, darkHighContrast: dark)
    }

    /// Same, with stronger variants for Settings › Accessibility › Increase Contrast.
    /// The platform colours are made once here, not on every resolve while drawing.
    init(light: Color, dark: Color, lightHighContrast: Color, darkHighContrast: Color) {
        #if canImport(UIKit)
        let lightColor = UIColor(light)
        let darkColor = UIColor(dark)
        let lightHigh = UIColor(lightHighContrast)
        let darkHigh = UIColor(darkHighContrast)
        self.init(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .dark { return high ? darkHigh : darkColor }
            return high ? lightHigh : lightColor
        })
        #else
        let lightColor = NSColor(light)
        let darkColor = NSColor(dark)
        let lightHigh = NSColor(lightHighContrast)
        let darkHigh = NSColor(darkHighContrast)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            if match == .darkAqua { return darkColor }
            if match == .accessibilityHighContrastDarkAqua { return darkHigh }
            if match == .accessibilityHighContrastAqua { return lightHigh }
            return lightColor
        })
        #endif
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Ink {
    // Surfaces. Dark mode is true black so OLED pixels switch off.
    static let background = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x000000))
    /// Cards, grouped rows, the compose sheet.
    static let surface = Color(light: Color(hex: 0xF5F5F6), dark: Color(hex: 0x0F0F11))
    /// Toasts, popovers, menus: one step above surface.
    static let elevated = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1B1B1E))
    /// Selected row background on Mac / pressed row on iPhone.
    static let selection = Color(light: Color(hex: 0x000000, opacity: 0.06), dark: Color(hex: 0xFFFFFF, opacity: 0.09))

    // Text: one ink at three strengths. Secondary and tertiary darken under Increase Contrast.
    static let primary = Color(light: Color(hex: 0x0B0B0C), dark: Color(hex: 0xF4F4F5))
    /// Snippets, metadata: about 5:1 on white, 7.7:1 on black.
    static let secondary = Color(light: Color(hex: 0x6C6C72), dark: Color(hex: 0x9C9CA3),
                                 lightHighContrast: Color(hex: 0x4A4A50), darkHighContrast: Color(hex: 0xB8B8BF))
    /// Section labels, counts, small glyphs. Kept above 3:1 so 11 pt labels stay legible.
    static let tertiary = Color(light: Color(hex: 0x8E8E93), dark: Color(hex: 0x6A6A71),
                                lightHighContrast: Color(hex: 0x6C6C72), darkHighContrast: Color(hex: 0x8E8E95))

    /// 1px separators.
    static let hairline = Color(light: Color(hex: 0x000000, opacity: 0.08), dark: Color(hex: 0xFFFFFF, opacity: 0.10),
                                lightHighContrast: Color(hex: 0x000000, opacity: 0.22), darkHighContrast: Color(hex: 0xFFFFFF, opacity: 0.26))
    /// Pills, chips, text field backgrounds. Dark needs a touch more than light to read on true black.
    static let fill = Color(light: Color(hex: 0x000000, opacity: 0.05), dark: Color(hex: 0xFFFFFF, opacity: 0.10),
                            lightHighContrast: Color(hex: 0x000000, opacity: 0.10), darkHighContrast: Color(hex: 0xFFFFFF, opacity: 0.18))
    /// Primary button: inverted ink.
    static let inverse = Color(light: Color(hex: 0x0B0B0C), dark: Color(hex: 0xF4F4F5))
    static let onInverse = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x000000))

    // Semantic colours, used only on swipe backgrounds and status.
    static let archive = Color(hex: 0x22C55E)
    static let trash = Color(hex: 0xFF3B30)
    static let snooze = Color(hex: 0xFFB020)
    static let star = Color(hex: 0xF5B800)
    static let spam = Color(hex: 0x8E8E93)
    static let danger = Color(hex: 0xFF453A)
    static let success = Color(hex: 0x30D158)
}

/// The hint of colour. One accent, picked in Settings; used for unread dots, the compose
/// button, links, focus rings and the read/unread swipe.
enum AccentTint: String, CaseIterable, Identifiable, Codable {
    case electric, ember, mint, iris, rose, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .electric: return "Electric"
        case .ember: return "Ember"
        case .mint: return "Mint"
        case .iris: return "Iris"
        case .rose: return "Rose"
        case .mono: return "Mono"
        }
    }

    /// Stable instances, so the `\.inkAccent` environment value compares equal between renders
    /// and doesn't invalidate every view that reads it.
    private static let electricColor = Color(light: Color(hex: 0x2F6BFF), dark: Color(hex: 0x4D84FF))
    private static let emberColor = Color(light: Color(hex: 0xFF5A1F), dark: Color(hex: 0xFF5E2B))
    private static let mintColor = Color(light: Color(hex: 0x00B383), dark: Color(hex: 0x1ED69F))
    private static let irisColor = Color(light: Color(hex: 0x6E56F8), dark: Color(hex: 0x8B78FF))
    private static let roseColor = Color(light: Color(hex: 0xF0386B), dark: Color(hex: 0xFF4F7E))
    /// Near-black ink for labels on the bright accents (mint is under 3:1 with white).
    private static let darkInk = Color(hex: 0x0B0B0C)

    var color: Color {
        switch self {
        case .electric: return Self.electricColor
        case .ember: return Self.emberColor
        case .mint: return Self.mintColor
        case .iris: return Self.irisColor
        case .rose: return Self.roseColor
        case .mono: return Ink.primary
        }
    }

    /// Text/icon colour that reads on top of `color` (at least 3:1 for bold labels and glyphs).
    var onColor: Color {
        switch self {
        case .mono: return Ink.onInverse
        case .mint: return Self.darkInk
        default: return .white
        }
    }
}

/// Per-account dot colours (stable by `AccountConfig.colorIndex`).
enum AccountPalette {
    static let colors: [Color] = [
        Color(hex: 0x4D84FF), Color(hex: 0xFF6A33), Color(hex: 0x1ED69F),
        Color(hex: 0x8B78FF), Color(hex: 0xFF4F7E), Color(hex: 0xF5B800),
    ]
    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

extension SwipeAction {
    /// Background colour behind a row while swiping.
    func tint(accent: Color) -> Color {
        switch self {
        case .archive: return Ink.archive
        case .trash: return Ink.trash
        case .snooze: return Ink.snooze
        case .toggleRead: return accent
        case .flag: return Ink.star
        case .markSpam: return Ink.spam
        case .none: return Ink.fill
        }
    }
}

// MARK: - Accent environment

private struct AccentKey: EnvironmentKey {
    static let defaultValue: Color = AccentTint.electric.color
}

extension EnvironmentValues {
    /// The user's accent colour. Set once at the root from `AppSettings.accent`.
    var inkAccent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

// MARK: - Type

/// Text styles scale with Dynamic Type; weights and tracking are fixed here.
enum InkFont {
    /// "Inbox": big, tight, confident.
    static let largeTitle = Font.system(.largeTitle, design: .default, weight: .bold)
    static let title = Font.system(.title2, design: .default, weight: .bold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)

    // List rows
    static let sender = Font.system(.body, design: .default, weight: .semibold)
    static let senderRead = Font.system(.body, design: .default, weight: .regular)
    static let subject = Font.system(.subheadline, design: .default, weight: .medium)
    static let subjectRead = Font.system(.subheadline, design: .default, weight: .regular)
    static let snippet = Font.system(.subheadline, design: .default, weight: .regular)
    static let meta = Font.system(.footnote, design: .default, weight: .regular).monospacedDigit()

    // Reader
    static let readerSubject = Font.system(.title, design: .default, weight: .bold)
    static let readerSubjectSerif = Font.system(.title, design: .serif, weight: .semibold)
    static let readerBody = Font.system(.body, design: .default, weight: .regular)
    static let readerBodySerif = Font.system(.body, design: .serif, weight: .regular)

    static let caption = Font.system(.caption, design: .default, weight: .medium)
    static let button = Font.system(.subheadline, design: .default, weight: .semibold)
    static let mono = Font.system(.footnote, design: .monospaced, weight: .regular)
}

/// Tracking (letter spacing) for display sizes; body text keeps the system default.
enum InkTracking {
    static let largeTitle: CGFloat = -0.6
    static let title: CGFloat = -0.4
}

// MARK: - Layout

enum InkSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
    static let xxxl: CGFloat = 40

    /// Horizontal inset of list rows and reader content.
    static let gutter: CGFloat = 20
    /// Vertical padding inside a list row.
    static let rowVertical: CGFloat = 12
    static let rowVerticalCompact: CGFloat = 8
}

enum InkRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 14
    static let large: CGFloat = 22
    static let sheet: CGFloat = 28
}

enum InkSize {
    static let avatar: CGFloat = 40
    static let avatarSmall: CGFloat = 28
    static let unreadDot: CGFloat = 8
    /// Floating compose button on iPhone.
    static let fab: CGFloat = 58
    /// Minimum hit target.
    static let hit: CGFloat = 44
}

// MARK: - Motion

/// Springs everywhere, tuned to feel immediate at 120 Hz. No linear animations.
enum InkMotion {
    /// Taps, toggles, selection.
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
    /// Screen-level changes, list reflow after archive.
    static let smooth = Animation.spring(response: 0.42, dampingFraction: 0.9)
    /// Playful moments: inbox zero, send confirmation.
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.66)
    /// A swiped row snapping back or flying off.
    static let swipeSettle = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// Rows collapsing after removal.
    static let rowRemoval = Animation.spring(response: 0.36, dampingFraction: 0.88)
    /// Toast in/out.
    static let toast = Animation.spring(response: 0.38, dampingFraction: 0.8)
    static let fade = Animation.easeOut(duration: 0.18)

    /// `animation`, or a plain cross-fade when Reduce Motion is on (read
    /// `@Environment(\.accessibilityReduceMotion)` and pass it in).
    static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }
}

// MARK: - Haptics

/// Haptic feedback from gesture code. Views can also use `.sensoryFeedback`.
///
/// The generators are kept and re-armed after each use, so the next tap lands without the
/// Taptic Engine's wake-up delay (noticeable when a swipe crosses two thresholds quickly).
@MainActor
enum Haptics {
    #if os(iOS)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()
    #endif

    /// Wakes the Taptic Engine ahead of an expected haptic (e.g. when a swipe begins).
    static func prepare() {
        #if os(iOS)
        light.prepare()
        medium.prepare()
        softImpact.prepare()
        #endif
    }

    /// A swipe crossed a threshold.
    static func threshold() {
        #if os(iOS)
        medium.impactOccurred(intensity: 0.85)
        medium.prepare()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }

    /// Tiered swipe feedback: a light tap arming the short action, a firmer one for the long
    /// action. Use `tick()` when the finger backs off below the first threshold.
    static func threshold(isLong: Bool) {
        #if os(iOS)
        let generator = isLong ? medium : light
        generator.impactOccurred(intensity: isLong ? 1 : 0.8)
        generator.prepare()
        #else
        threshold()
        #endif
    }

    /// Light tick for small changes (toggle, selection).
    static func tick() {
        #if os(iOS)
        selection.selectionChanged()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
    }

    /// An action committed (archived, sent).
    static func success() {
        #if os(iOS)
        notification.notificationOccurred(.success)
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
    }

    /// Something destructive or failed.
    static func warning() {
        #if os(iOS)
        notification.notificationOccurred(.warning)
        #endif
    }

    /// Soft thump for a row landing after a swipe.
    static func soft() {
        #if os(iOS)
        softImpact.impactOccurred(intensity: 0.6)
        #endif
    }
}

// MARK: - Glass

extension View {
    /// Liquid Glass on iOS 26 / macOS 26, a thin material before that. For floating controls
    /// only (compose button, toasts, bottom bar), never for content.
    @ViewBuilder
    func inkGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Ink.hairline, lineWidth: 0.5))
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Ink.hairline, lineWidth: 0.5))
        #endif
    }

    /// Large title styling with tight tracking.
    func inkLargeTitle() -> some View {
        self.font(InkFont.largeTitle).tracking(InkTracking.largeTitle).foregroundStyle(Ink.primary)
    }
}
