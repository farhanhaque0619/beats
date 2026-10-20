import SwiftUI
import InkCore

/// Monochrome initials avatar. The grey shade is derived from the address so each person keeps
/// a consistent tone without adding colour.
struct AvatarView: View {
    var address: EmailAddress?
    var size: CGFloat = InkSize.avatar

    /// `.increased` on a selected row in a focused Mac list: the avatar turns white-on-accent
    /// with the rest of the row instead of a dark smudge on the highlight.
    @Environment(\.backgroundProminence) private var prominence

    /// Four quiet greys, made once. Dark mode sits a little higher so the circles still read on
    /// true black.
    private static let shades: [Color] = {
        let steps: [(light: Double, dark: Double)] = [(0.07, 0.10), (0.10, 0.13), (0.13, 0.16), (0.16, 0.19)]
        return steps.map { step in
            Color(light: Color(hex: 0x0B0B0C, opacity: step.light), dark: Color(hex: 0xF4F4F5, opacity: step.dark))
        }
    }()

    var body: some View {
        let initials = address?.initials ?? "?"
        let onHighlight = prominence == .increased
        Circle()
            .fill(onHighlight ? Color.white.opacity(0.24) : shade)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(onHighlight ? Color.white : Ink.primary.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var shade: Color {
        let seed = (address?.normalized ?? "").unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Self.shades[Int(seed % UInt32(Self.shades.count))]
    }
}

/// The hint of colour: unread indicator in the accent.
struct UnreadDot: View {
    @Environment(\.inkAccent) private var accent
    var size: CGFloat = InkSize.unreadDot

    var body: some View {
        Circle().fill(accent).frame(width: size, height: size).accessibilityLabel("Unread")
    }
}

/// Small coloured dot identifying an account in unified views.
struct AccountDot: View {
    var colorIndex: Int
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(AccountPalette.color(colorIndex)).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Small uppercase-ish section label ("TODAY").
struct SectionHeaderView: View {
    var title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(.caption2, design: .default, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Ink.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, InkSpace.gutter)
            .padding(.top, InkSpace.l)
            .padding(.bottom, InkSpace.xs)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Keyboard shortcut hint shown in menus/palettes on Mac ("⌘K", "E").
struct KeyCap: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Ink.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Capsule filter chip ("Unread", "Has attachment").
struct Chip: View {
    var title: String
    var systemImage: String?
    var isSelected: Bool = false
    var action: () -> Void

    @Environment(\.inkAccent) private var accent

    var body: some View {
        Button(action: {
            Haptics.tick()
            action()
        }) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.caption.weight(.semibold)) }
                Text(title).font(InkFont.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Ink.onInverse : Ink.primary)
            .background(isSelected ? AnyShapeStyle(Ink.inverse) : AnyShapeStyle(Ink.fill), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(InkMotion.snappy, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Round icon button with a 44pt hit area.
struct IconButton: View {
    var systemImage: String
    var label: String
    var size: CGFloat = 17
    var action: () -> Void

    init(_ systemImage: String, label: String, size: CGFloat = 17, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Ink.primary)
                .frame(width: InkSize.hit, height: InkSize.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        #if os(macOS)
        .help(label)
        #endif
    }
}

/// Generic empty state.
struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String?

    var body: some View {
        VStack(spacing: InkSpace.m) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Ink.tertiary)
                .padding(.bottom, InkSpace.xs)
                .accessibilityHidden(true)
            Text(title)
                .font(InkFont.headline)
                .foregroundStyle(Ink.primary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .padding(InkSpace.xxxl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The reward for an empty inbox: the accent ring draws itself, then the check pops in and the
/// words rise. Reduce Motion gets a plain fade.
struct InboxZeroView: View {
    @Environment(\.inkAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringDrawn = false
    @State private var checkShown = false
    @State private var textShown = false
    private let title: String
    private let message: String

    /// Pass other words for a split inbox (e.g. "Focus is clear" / "3 waiting in Other") so an
    /// empty filter isn't celebrated as a truly empty inbox.
    init(title: String = "Inbox zero", message: String = "Nothing needs you right now.") {
        self.title = title
        self.message = message
    }

    var body: some View {
        VStack(spacing: InkSpace.l) {
            ZStack {
                Circle()
                    .stroke(Ink.hairline, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: ringDrawn ? 1 : 0)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .scaleEffect(checkShown ? 1 : 0.4)
                    .opacity(checkShown ? 1 : 0)
            }
            .frame(width: 84, height: 84)
            .accessibilityHidden(true)
            VStack(spacing: InkSpace.xs) {
                Text(title).font(InkFont.title).tracking(InkTracking.title).foregroundStyle(Ink.primary)
                Text(message).font(.subheadline).foregroundStyle(Ink.secondary)
            }
            .multilineTextAlignment(.center)
            .opacity(textShown ? 1 : 0)
            .offset(y: textShown ? 0 : 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
        .onAppear(perform: play)
        .onDisappear {
            ringDrawn = false
            checkShown = false
            textShown = false
        }
        .accessibilityElement(children: .combine)
    }

    private func play() {
        if reduceMotion {
            ringDrawn = true
            checkShown = true
            withAnimation(InkMotion.fade) { textShown = true }
            return
        }
        withAnimation(.easeOut(duration: 0.6)) { ringDrawn = true }
        withAnimation(InkMotion.bouncy.delay(0.32)) { checkShown = true }
        withAnimation(InkMotion.smooth.delay(0.42)) { textShown = true }
    }
}

/// Three pulsing dots for "working on it". The pulse is scoped to opacity, so the dots never
/// inherit the repeating animation for their position when they appear inside a moving container.
struct LoadingDots: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Ink.secondary)
                    .frame(width: 6, height: 6)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.18)) { dot in
                        dot.opacity(phase ? 1 : 0.25)
                    }
            }
        }
        .onAppear { phase = true }
        .onDisappear { phase = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

// MARK: - Button styles

/// Inverted ink capsule: the main call to action ("Connect", "Add account").
struct InkPrimaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .default, weight: .semibold))
            .foregroundStyle(Ink.onInverse)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, InkSpace.xl)
            .padding(.vertical, 15)
            .background(Ink.inverse, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(InkMotion.snappy, value: configuration.isPressed)
    }
}

/// Quiet filled capsule for secondary actions.
struct InkSecondaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .default, weight: .medium))
            .foregroundStyle(Ink.primary)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, InkSpace.xl)
            .padding(.vertical, 15)
            .background(Ink.fill, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(InkMotion.snappy, value: configuration.isPressed)
    }
}

/// Accent capsule, for Send and the few places colour should pull the eye.
struct InkAccentButtonStyle: ButtonStyle {
    @Environment(\.inkAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled
    // Optional reads: the label colour follows the picked accent (dark ink on Mint, black on
    // Mono in dark mode) wherever the settings are in the environment, white otherwise.
    @Environment(AppSettings.self) private var settings: AppSettings?
    @Environment(AppModel.self) private var app: AppModel?

    private var labelColor: Color {
        (settings ?? app?.settings)?.accent.onColor ?? .white
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(InkFont.button)
            .foregroundStyle(labelColor)
            .padding(.horizontal, InkSpace.l)
            .padding(.vertical, 9)
            .background(accent, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(InkMotion.snappy, value: configuration.isPressed)
    }
}

/// Subtle press feedback for rows, cards and icon buttons.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(InkMotion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == InkPrimaryButtonStyle {
    static var inkPrimary: InkPrimaryButtonStyle { InkPrimaryButtonStyle() }
}

extension ButtonStyle where Self == InkSecondaryButtonStyle {
    static var inkSecondary: InkSecondaryButtonStyle { InkSecondaryButtonStyle() }
}

extension ButtonStyle where Self == InkAccentButtonStyle {
    static var inkAccent: InkAccentButtonStyle { InkAccentButtonStyle() }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Text field

/// Rounded search field used on iPhone and in the Mac command palette.
struct InkSearchField: View {
    @Binding var text: String
    var prompt: String = "Search"
    var onSubmit: () -> Void = {}
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: InkSpace.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Ink.tertiary)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, InkSpace.m)
        .padding(.vertical, 10)
        .background(Ink.fill, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
    }

    @ViewBuilder private var field: some View {
        let base = TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit(onSubmit)
        if let focus {
            base.focused(focus)
        } else {
            base
        }
    }
}

#if os(iOS)
extension View {
    /// No-op on iPhone; Mac uses it to hide keyboard focus rings on custom controls.
    func inkFocusEffectDisabled() -> some View { self }
}
#else
extension View {
    func inkFocusEffectDisabled() -> some View { self.focusEffectDisabled() }
}
#endif
