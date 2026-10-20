import SwiftUI
import InkCore

/// Step one of adding an account: big, quiet rows, one per provider.
struct OnboardingProviderPicker: View {
    var onPick: (ProviderID) -> Void
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 32, height: 32)
                        .background(Ink.fill, in: Circle())
                        .frame(width: InkSize.hit, height: InkSize.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, InkSpace.m)
            .padding(.top, InkSpace.xs)

            ScrollView {
                VStack(alignment: .leading, spacing: InkSpace.xl) {
                    VStack(alignment: .leading, spacing: InkSpace.s) {
                        Text("Add an account")
                            .inkLargeTitle()
                            .accessibilityAddTraits(.isHeader)
                        Text("Ink talks straight to your provider. Your password stays in the Keychain on this device.")
                            .font(.subheadline)
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: InkSpace.s) {
                        ForEach(Array(OnboardingProvider.pickerOrder.enumerated()), id: \.element) { index, id in
                            OnboardingProviderRow(provider: OnboardingProvider.info(for: id)) {
                                Haptics.tick()
                                onPick(id)
                            }
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 14)
                            .animation(reduceMotion ? nil : InkMotion.smooth.delay(Double(index) * 0.04), value: appeared)
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: InkSpace.s) {
                        Image(systemName: "info.circle")
                            .accessibilityHidden(true)
                        Text(Self.protonNote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.footnote)
                    .foregroundStyle(Ink.tertiary)
                }
                .padding(.horizontal, InkSpace.xl)
                .padding(.top, InkSpace.s)
                .padding(.bottom, InkSpace.xxl)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { appeared = true }
    }

    private static var protonNote: String {
        #if os(iOS)
        return "Proton Mail can't connect on iPhone: Proton has no IMAP, and Proton Mail Bridge only runs on computers."
        #else
        return "Proton Mail has no IMAP of its own. Proton Mail Bridge adds it on a Mac: run Bridge, then choose Other and enter the details it shows."
        #endif
    }
}

private struct OnboardingProviderRow: View {
    let provider: OnboardingProvider
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: InkSpace.l) {
                Image(systemName: provider.glyph)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Ink.primary)
                    .frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: InkSpace.xxs) {
                    Text(provider.name)
                        .font(InkFont.headline)
                        .foregroundStyle(Ink.primary)
                    Text(signInLine)
                        .font(.subheadline)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: InkSpace.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Ink.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(InkSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// The provider's reach, plus how you sign in where that's notable.
    private var signInLine: String {
        switch provider.id {
        case .outlook: return "\(provider.detail) · Sign in with Microsoft"
        case .gmail where OAuthSettings.isConfigured(.google): return "\(provider.detail) · App password or Google sign-in"
        default: return provider.detail
        }
    }
}
