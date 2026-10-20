import SwiftUI
import InkCore

/// The checklist shown while Ink connects: each step spins, then springs into a check.
struct OnboardingConnectionView: View {
    let connector: OnboardingConnector
    let providerName: String
    let email: String

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpace.xxl) {
            VStack(alignment: .leading, spacing: InkSpace.xs) {
                Text("Connecting \(providerName)")
                    .font(InkFont.title)
                    .tracking(InkTracking.title)
                    .foregroundStyle(Ink.primary)
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(connector.rowTitles.enumerated()), id: \.offset) { index, title in
                    OnboardingProgressRow(title: title, state: connector.state(at: index))
                }
            }

            Spacer(minLength: 0)

            Button("Cancel") { connector.cancel() }
                .buttonStyle(.inkSecondary)
                .opacity(connector.canCancel ? 1 : 0)
                .disabled(!connector.canCancel)
                .animation(InkMotion.snappy, value: connector.canCancel)
                #if os(macOS)
                .keyboardShortcut(.cancelAction)
                #endif
        }
        .padding(.horizontal, InkSpace.xxl)
        .padding(.top, InkSpace.xl)
        .padding(.bottom, InkSpace.xl)
        .frame(maxWidth: 520, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingProgressRow: View {
    let title: String
    let state: OnboardingConnector.RowState
    @Environment(\.inkAccent) private var accent

    var body: some View {
        HStack(spacing: InkSpace.m) {
            ZStack {
                switch state {
                case .pending:
                    Circle()
                        .stroke(Ink.hairline, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                        .transition(.opacity)
                case .active:
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(accent)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .frame(width: 24, height: 24)

            Text(title)
                .font(.body)
                .foregroundStyle(state == .pending ? Ink.tertiary : Ink.primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, InkSpace.s + 2)
        .animation(InkMotion.bouncy, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityState)
    }

    private var accessibilityState: String {
        switch state {
        case .pending: return "Waiting"
        case .active: return "In progress"
        case .done: return "Done"
        }
    }
}

/// "You're in." A check pops and draws itself, a ring pulses out, then the sheet closes.
struct OnboardingSuccessView: View {
    let email: String
    var onDone: () -> Void

    @Environment(\.inkAccent) private var accent
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false
    @State private var drawn = false
    @State private var pulsed = false
    /// Done and the automatic close can both fire; only the first one counts.
    @State private var finished = false

    var body: some View {
        VStack(spacing: InkSpace.xl) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .stroke(accent.opacity(0.35), lineWidth: 2)
                    .frame(width: 104, height: 104)
                    .scaleEffect(pulsed ? 1.7 : 1)
                    .opacity(pulsed ? 0 : 1)
                Circle()
                    .fill(accent)
                    .frame(width: 104, height: 104)
                    .scaleEffect(popped ? 1 : 0.3)
                OnboardingCheckShape()
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(settings.accent.onColor, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .frame(width: 44, height: 34)
            }
            .opacity(popped ? 1 : 0)
            .accessibilityHidden(true)

            VStack(spacing: InkSpace.s) {
                Text("You're in.")
                    .inkLargeTitle()
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .opacity(popped ? 1 : 0)
            .offset(y: popped ? 0 : 10)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            Button("Done", action: finish)
                .buttonStyle(.inkPrimary)
                .keyboardShortcut(.defaultAction)
                .opacity(drawn ? 1 : 0)
        }
        .padding(.horizontal, InkSpace.xxl)
        .padding(.bottom, InkSpace.xl)
        .frame(maxWidth: 520, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .task { await celebrate() }
    }

    private func celebrate() async {
        if reduceMotion {
            popped = true
            drawn = true
            pulsed = true
        } else {
            withAnimation(InkMotion.bouncy) { popped = true }
            withAnimation(.easeOut(duration: 0.9).delay(0.1)) { pulsed = true }
            withAnimation(.easeOut(duration: 0.38).delay(0.18)) { drawn = true }
        }
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        guard !Task.isCancelled else { return }
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onDone()
    }
}

/// A checkmark drawn as one stroke, so it can draw itself with `trim`.
private struct OnboardingCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
