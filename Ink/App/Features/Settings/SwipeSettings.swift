import SwiftUI
import InkCore

/// The four swipe pickers, with a live row that acts out what each swipe will do.
struct SettingsSwipesSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            SettingsSwipePreview(configuration: settings.swipes)
                #if os(iOS)
                .listRowInsets(EdgeInsets(top: InkSpace.m, leading: InkSpace.l, bottom: InkSpace.m, trailing: InkSpace.l))
                #endif
            swipePicker("Short swipe right", systemImage: "arrow.right", selection: $settings.swipes.rightShort)
            swipePicker("Long swipe right", systemImage: "arrow.right.to.line", selection: $settings.swipes.rightLong)
            swipePicker("Short swipe left", systemImage: "arrow.left", selection: $settings.swipes.leftShort)
            swipePicker("Long swipe left", systemImage: "arrow.left.to.line", selection: $settings.swipes.leftLong)
            Button("Restore defaults") {
                Haptics.tick()
                withAnimation(InkMotion.smooth) { settings.swipes = .standard }
            }
            .disabled(settings.swipes == .standard)
        } header: {
            Text("Swipes")
        } footer: {
            Text("A short swipe acts at the first tick. Keep going past the second for the long action.")
        }
        .settingsSectionStyle()
    }

    private func swipePicker(_ title: String, systemImage: String, selection: Binding<SwipeAction>) -> some View {
        Picker(selection: selection) {
            ForEach(SwipeAction.allCases) { action in
                Label(action.title, systemImage: action.systemImage).tag(action)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

/// A sample row that swipes itself: right short, right long, back, left short, left long, back,
/// showing each configured action's colour and icon. Starts with whichever side just changed.
struct SettingsSwipePreview: View {
    let configuration: SwipeConfiguration

    @Environment(\.inkAccent) private var accent
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage: Stage = .rest
    @State private var lastConfiguration: SwipeConfiguration?

    enum Stage: Equatable {
        case rest, rightShort, rightLong, leftShort, leftLong

        var isRight: Bool { self == .rightShort || self == .rightLong }
        var isLong: Bool { self == .rightLong || self == .leftLong }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                actionLayer
                sampleRow
                    .offset(x: offset(width: width))
            }
        }
        .frame(height: 72)
        .clipShape(RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous)
                .stroke(Ink.hairline, lineWidth: 0.5)
        )
        .task(id: configuration) { await play() }
        .accessibilityHidden(true)
    }

    private var actionLayer: some View {
        let action = self.action(for: stage)
        return ZStack(alignment: stage.isRight ? .leading : .trailing) {
            Rectangle()
                .fill(action == .none ? Ink.fill : action.tint(accent: accent))
            HStack(spacing: InkSpace.s) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                if stage.isLong {
                    Text(action.title)
                        .font(InkFont.button)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .foregroundStyle(iconColor(for: action))
            .padding(.horizontal, InkSpace.xl)
            .scaleEffect(stage == .rest ? 0.6 : (stage.isLong ? 1.15 : 1))
            .opacity(stage == .rest ? 0 : 1)
        }
    }

    private var sampleRow: some View {
        HStack(spacing: InkSpace.m) {
            AvatarView(address: EmailAddress(name: "Maya Chen", address: "maya@example.com"), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Maya Chen")
                        .font(InkFont.sender)
                        .foregroundStyle(Ink.primary)
                    Spacer(minLength: InkSpace.s)
                    Text("9:41")
                        .font(InkFont.meta)
                        .foregroundStyle(Ink.primary)
                }
                Text("Thursday dinner?")
                    .font(InkFont.subject)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, InkSpace.l + 4)
        .padding(.trailing, InkSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .overlay(alignment: .leading) {
            UnreadDot(size: 7)
                .padding(.leading, 7)
        }
    }

    private func offset(width: CGFloat) -> CGFloat {
        switch stage {
        case .rest: return 0
        case .rightShort: return width * 0.32
        case .rightLong: return width * 0.66
        case .leftShort: return -width * 0.32
        case .leftLong: return -width * 0.66
        }
    }

    private func action(for stage: Stage) -> SwipeAction {
        switch stage {
        case .rest: return .none
        case .rightShort: return configuration.rightShort
        case .rightLong: return configuration.rightLong
        case .leftShort: return configuration.leftShort
        case .leftLong: return configuration.leftLong
        }
    }

    private func iconColor(for action: SwipeAction) -> Color {
        switch action {
        case .none: return Ink.secondary
        case .toggleRead: return settings.accent.onColor
        default: return .white
        }
    }

    /// The stages for one side, skipping swipes set to Nothing.
    private func stages(right: Bool) -> [Stage] {
        let pairs: [(Stage, SwipeAction)] = right
            ? [(.rightShort, configuration.rightShort), (.rightLong, configuration.rightLong)]
            : [(.leftShort, configuration.leftShort), (.leftLong, configuration.leftLong)]
        return pairs.filter { $0.1 != .none }.map { $0.0 }
    }

    private func play() async {
        let previous = lastConfiguration
        lastConfiguration = configuration
        var startsLeft = false
        if let previous {
            startsLeft = previous.leftShort != configuration.leftShort || previous.leftLong != configuration.leftLong
        }
        var sides = [stages(right: true), stages(right: false)].filter { !$0.isEmpty }
        if startsLeft, sides.count == 2 { sides.reverse() }

        guard !reduceMotion, !sides.isEmpty else {
            withAnimation(InkMotion.swipeSettle) { stage = .rest }
            return
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        while !Task.isCancelled {
            for side in sides {
                for next in side {
                    withAnimation(InkMotion.swipeSettle) { stage = next }
                    try? await Task.sleep(nanoseconds: 850_000_000)
                    if Task.isCancelled { return }
                }
                withAnimation(InkMotion.swipeSettle) { stage = .rest }
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return }
            }
        }
    }
}
