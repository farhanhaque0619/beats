import SwiftUI
import InkCore

/// A rounded card of form rows separated by hairlines.
struct OnboardingFieldGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
    }
}

/// One labelled row inside an `OnboardingFieldGroup`.
struct OnboardingFieldRow<Field: View>: View {
    let label: String
    var showsDivider = true
    @ViewBuilder var field: Field

    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 92

    var body: some View {
        HStack(spacing: InkSpace.m) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: labelWidth, alignment: .leading)
            field
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, InkSpace.l)
        .padding(.vertical, InkSpace.s)
        .frame(minHeight: 50)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(Ink.hairline)
                    .frame(height: 0.5)
                    .padding(.leading, InkSpace.l)
            }
        }
    }
}

/// What went wrong, in words, with a hint about what to do next. Shakes when it changes.
struct OnboardingFailureCard: View {
    let failure: OnboardingFailure
    /// Changes on each new failure, which replays the shake.
    let attempt: Int

    var body: some View {
        HStack(alignment: .top, spacing: InkSpace.m) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Ink.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: InkSpace.xs) {
                Text(failure.message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = failure.hint {
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(InkSpace.l)
        .background(Ink.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous)
                .stroke(Ink.danger.opacity(0.25), lineWidth: 0.5)
        )
        .modifier(OnboardingShake(animatableData: CGFloat(attempt)))
        .animation(InkMotion.smooth, value: attempt)
        .accessibilityElement(children: .combine)
    }
}

/// Side-to-side wobble, driven by a counter.
private struct OnboardingShake: GeometryEffect {
    var animatableData: CGFloat
    var travel: CGFloat = 7

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 4), y: 0))
    }
}

/// Small print under the form: gotchas for this provider.
struct OnboardingNotes: View {
    let notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpace.s) {
            ForEach(notes, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: InkSpace.s) {
                    Image(systemName: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Ink.tertiary)
                        .accessibilityHidden(true)
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A divider with words in the middle ("or use an app password").
struct OnboardingDividerLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: InkSpace.m) {
            Rectangle().fill(Ink.hairline).frame(height: 0.5)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Ink.tertiary)
                .fixedSize()
            Rectangle().fill(Ink.hairline).frame(height: 0.5)
        }
    }
}

// MARK: - Input traits

extension View {
    /// Email address entry: no capitals, no autocorrect, the @ keyboard on iPhone.
    func onboardingEmailInput() -> some View {
        #if os(iOS)
        return self
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        return self.autocorrectionDisabled()
        #endif
    }

    /// Host names: no capitals, no autocorrect, the URL keyboard on iPhone.
    func onboardingHostInput() -> some View {
        #if os(iOS)
        return self
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        return self.autocorrectionDisabled()
        #endif
    }

    /// Port numbers: the number pad on iPhone.
    func onboardingNumberInput() -> some View {
        #if os(iOS)
        return self.keyboardType(.numberPad)
        #else
        return self
        #endif
    }

    /// Usernames and passwords: typed exactly as given.
    func onboardingLiteralInput() -> some View {
        #if os(iOS)
        return self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        return self.autocorrectionDisabled()
        #endif
    }
}
