import SwiftUI
import InkCore

/// First launch: the wordmark, whose "i" dot drops in as the accent, the tagline, three quiet
/// promises, then "Add an account" or the demo inbox.
struct WelcomeFlow: View {
    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the intro has played: 1 wordmark, 2 dot, 3 tagline, 4–6 features, 7 buttons.
    @State private var stage = 0
    @State private var isOpeningDemo = false

    private static let finalStage = 7
    private static let features: [(symbol: String, title: String)] = [
        ("hand.draw", "Swipe to triage"),
        ("lock", "Private by default"),
        ("bolt", "Fast everywhere"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: InkSpace.xxxl)

            VStack(spacing: InkSpace.l) {
                WelcomeWordmark(dotDropped: stage >= 2)
                    .opacity(stage >= 1 ? 1 : 0)
                    .scaleEffect(stage >= 1 ? 1 : 0.96)

                Text("Email, quieter.")
                    .font(.system(.title3, design: .default, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .opacity(stage >= 3 ? 1 : 0)
                    .offset(y: stage >= 3 ? 0 : 8)
            }

            VStack(alignment: .leading, spacing: InkSpace.m) {
                ForEach(Array(Self.features.enumerated()), id: \.offset) { index, feature in
                    HStack(spacing: InkSpace.m) {
                        Image(systemName: feature.symbol)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Ink.primary)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        Text(feature.title)
                            .font(.subheadline)
                            .foregroundStyle(Ink.secondary)
                    }
                    .opacity(stage >= 4 + index ? 1 : 0)
                    .offset(y: stage >= 4 + index ? 0 : 10)
                }
            }
            .padding(.top, InkSpace.xxxl)

            Spacer(minLength: InkSpace.xxxl)

            VStack(spacing: InkSpace.m) {
                Button {
                    Haptics.tick()
                    app.isAddAccountPresented = true
                } label: {
                    Text("Add an account")
                }
                .buttonStyle(.inkPrimary)
                .keyboardShortcut(.defaultAction)

                Button(action: openDemo) {
                    ZStack {
                        Text("Explore the demo inbox")
                            .opacity(isOpeningDemo ? 0 : 1)
                        if isOpeningDemo {
                            LoadingDots()
                        }
                    }
                }
                .buttonStyle(.inkSecondary)
                .disabled(isOpeningDemo)
                .accessibilityLabel("Explore the demo inbox")

                Text("No Ink servers. Your mail goes straight from this device to your provider.")
                    .font(.footnote)
                    .foregroundStyle(Ink.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, InkSpace.xs)
            }
            .opacity(stage >= Self.finalStage ? 1 : 0)
            .offset(y: stage >= Self.finalStage ? 0 : 16)
            .allowsHitTesting(stage >= Self.finalStage)
        }
        .padding(.horizontal, InkSpace.xxl)
        .padding(.bottom, InkSpace.xl)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background.ignoresSafeArea())
        .task { await playIntro() }
    }

    private func openDemo() {
        guard !isOpeningDemo else { return }
        isOpeningDemo = true
        Task {
            await store.addDemoAccount()
            Haptics.success()
            isOpeningDemo = false
        }
    }

    /// Plays the intro once; screenshots and Reduce Motion get the finished screen straight away.
    private func playIntro() async {
        guard stage < Self.finalStage else { return }
        if reduceMotion || app.screenshot != nil {
            stage = Self.finalStage
            return
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        withAnimation(InkMotion.smooth) { stage = 1 }

        try? await Task.sleep(nanoseconds: 320_000_000)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.52)) { stage = 2 }
        try? await Task.sleep(nanoseconds: 230_000_000)
        Haptics.soft()

        try? await Task.sleep(nanoseconds: 260_000_000)
        withAnimation(InkMotion.smooth) { stage = 3 }

        for next in 4...6 {
            try? await Task.sleep(nanoseconds: 140_000_000)
            withAnimation(InkMotion.smooth) { stage = next }
        }

        try? await Task.sleep(nanoseconds: 220_000_000)
        withAnimation(InkMotion.smooth) { stage = Self.finalStage }
    }
}

/// "Ink" set in heavy type with a dotless ı; the dot is an accent circle that falls into place.
private struct WelcomeWordmark: View {
    var dotDropped: Bool

    @Environment(\.inkAccent) private var accent

    /// A logo, so a fixed size rather than a text style.
    private let size: CGFloat = 104

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ZStack(alignment: Alignment(horizontal: .center, vertical: .firstTextBaseline)) {
                Text("\u{0131}")
                Circle()
                    .fill(accent)
                    .frame(width: size * 0.19, height: size * 0.19)
                    // Sit the dot just above the x-height (about 0.53 of the size in SF Pro).
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[.bottom] + size * 0.6
                    }
                    .offset(y: dotDropped ? 0 : -size * 0.9)
                    .opacity(dotDropped ? 1 : 0)
            }
            Text("nk")
        }
        .font(.system(size: size, weight: .heavy))
        .tracking(-size * 0.03)
        .foregroundStyle(Ink.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ink")
        .accessibilityAddTraits(.isHeader)
    }
}
