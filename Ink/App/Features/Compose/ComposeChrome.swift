import SwiftUI
import InkCore

/// The compose fields that can hold keyboard focus.
enum ComposeField: Hashable {
    case to, cc, bcc, subject, body
}

/// Shared measurements so every compose row lines up.
enum ComposeMetrics {
    /// Height of one line of a compose row (label, token line, text field).
    static let line: CGFloat = 30
    /// Height of a recipient token capsule.
    static let token: CGFloat = 28
    /// Vertical padding around a compose row.
    static let rowPadding: CGFloat = 7
}

/// Quiet leading label of a compose row ("To", "Cc"). Scales with Dynamic Type so the
/// fields after it stay in one column.
struct ComposeFieldLabel: View {
    private let text: String
    @ScaledMetric(relativeTo: .subheadline) private var width: CGFloat = 46

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Ink.tertiary)
            .lineLimit(1)
            .frame(minWidth: width, minHeight: ComposeMetrics.line, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// One-pixel hairline between compose rows, inset to the content edge.
struct ComposeSeparator: View {
    private let inset: CGFloat
    @Environment(\.displayScale) private var displayScale

    init(inset: CGFloat = InkSpace.gutter) {
        self.inset = inset
    }

    var body: some View {
        Rectangle()
            .fill(Ink.hairline)
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

/// The quoted original under a reply: a quiet "Show quoted text" pill that expands into the
/// quote with a hairline rule beside it.
struct ComposeQuotedText: View {
    private let text: String
    @Binding private var isExpanded: Bool
    /// When set, the expanded quote scrolls inside this height (Mac, where the editor fills
    /// the window and must keep its room).
    private let maxExpandedHeight: CGFloat?

    init(text: String, isExpanded: Binding<Bool>, maxExpandedHeight: CGFloat? = nil) {
        self.text = text
        self._isExpanded = isExpanded
        self.maxExpandedHeight = maxExpandedHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpace.m) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.bold))
                    Text(isExpanded ? "Hide quoted text" : "Show quoted text")
                        .font(InkFont.caption)
                }
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, InkSpace.m)
                .padding(.vertical, 7)
                .background(Ink.fill, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(isExpanded ? "Hide quoted text" : "Show quoted text")

            if isExpanded {
                expanded
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var expanded: some View {
        if let maxExpandedHeight {
            ScrollView {
                quote
            }
            .frame(maxHeight: maxExpandedHeight)
            .scrollBounceBehavior(.basedOnSize)
        } else {
            quote
        }
    }

    private var quote: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Ink.secondary)
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, InkSpace.m)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Ink.hairline)
                    .frame(width: 2)
            }
    }

    private func toggle() {
        Haptics.tick()
        withAnimation(InkMotion.smooth) { isExpanded.toggle() }
    }
}
