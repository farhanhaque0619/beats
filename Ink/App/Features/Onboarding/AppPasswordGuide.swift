import SwiftUI
import InkCore

/// "How to get an app password": the provider's requirement, numbered steps and a button that
/// opens the right page. Collapses once you've read it.
struct OnboardingGuideCard: View {
    let title: String
    let requirement: String?
    let steps: [String]
    let pageURL: URL?
    let pageButtonTitle: String

    @Environment(\.openURL) private var openURL
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpace.m) {
            Button {
                Haptics.tick()
                withAnimation(InkMotion.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: InkSpace.s) {
                    Image(systemName: "key")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ink.primary)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(InkFont.headline)
                        .foregroundStyle(Ink.primary)
                    Spacer(minLength: InkSpace.s)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Ink.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: InkSpace.m) {
                    if let requirement {
                        HStack(alignment: .firstTextBaseline, spacing: InkSpace.s) {
                            Image(systemName: "checkmark.shield")
                                .font(.subheadline)
                                .foregroundStyle(Ink.primary)
                                .accessibilityHidden(true)
                            Text(requirement)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Ink.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(InkSpace.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Ink.fill, in: RoundedRectangle(cornerRadius: InkRadius.small, style: .continuous))
                    }

                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: InkSpace.m) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Ink.onInverse)
                                .frame(width: 20, height: 20)
                                .background(Ink.inverse, in: Circle())
                                .accessibilityHidden(true)
                            Text(step)
                                .font(.subheadline)
                                .foregroundStyle(Ink.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Step \(index + 1): \(step)")
                    }

                    if let pageURL {
                        Button {
                            Haptics.tick()
                            openURL(pageURL)
                        } label: {
                            Label(pageButtonTitle, systemImage: "arrow.up.right")
                        }
                        .buttonStyle(.inkAccent)
                        .padding(.top, InkSpace.xs)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(InkSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
    }
}

/// "Sign in with Google / Microsoft" in the provider's own sheet.
struct OnboardingOAuthButton: View {
    let provider: OAuthProviderID
    var prominent = true
    var isWorking = false
    let action: () -> Void

    var body: some View {
        if prominent {
            button.buttonStyle(.inkPrimary)
        } else {
            button.buttonStyle(.inkSecondary)
        }
    }

    private var button: some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            HStack(spacing: InkSpace.s) {
                ZStack {
                    Image(systemName: glyph)
                        .opacity(isWorking ? 0 : 1)
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(prominent ? Ink.onInverse : Ink.primary)
                    }
                }
                .frame(width: 22, height: 22)
                Text(title)
            }
        }
        .disabled(isWorking)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch provider {
        case .google: return "Sign in with Google"
        case .microsoft: return "Sign in with Microsoft"
        }
    }

    private var glyph: String {
        switch provider {
        case .google: return "g.circle.fill"
        case .microsoft: return "squareshape.split.2x2"
        }
    }
}

/// Outlook without a Microsoft app registration in this build: say why, and where the fix is.
struct OnboardingOAuthUnavailableCard: View {
    let provider: OAuthProviderID
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpace.m) {
            HStack(spacing: InkSpace.s) {
                Image(systemName: "lock.circle")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHidden(true)
                Text(provider == .microsoft ? "Sign in with Microsoft isn't set up yet" : "Sign in with Google isn't set up yet")
                    .font(InkFont.headline)
            }
            .foregroundStyle(Ink.primary)

            Text(provider == .microsoft
                 ? "Microsoft only lets mail apps in through Sign in with Microsoft, and that needs a one-time app registration added to this build. The setup guide walks through it."
                 : "Sign in with Google needs a client ID added to this build. An app password works without it.")
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = guideURL {
                Button {
                    Haptics.tick()
                    openURL(url)
                } label: {
                    Label("Read the setup guide", systemImage: "book")
                }
                .buttonStyle(.inkSecondary)
            }
        }
        .padding(InkSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
    }

    private var guideURL: URL? {
        provider == .microsoft ? OnboardingLinks.outlookGuide : OnboardingLinks.accountsGuide
    }
}
