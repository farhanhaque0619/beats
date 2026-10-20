#if os(iOS)
import SwiftUI

/// Placeholder rows for the very first load, with a soft highlight sweeping across them.
/// Shapes follow `ConversationRow`'s layout so the real rows land in the same places.
struct InboxSkeletonList: View {
    var showsAvatar: Bool
    var compact: Bool
    var rowCount = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        rows
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        TimelineView(.animation) { timeline in
                            let width = proxy.size.width
                            let band = width * 0.6
                            LinearGradient(
                                colors: [Ink.background.opacity(0), Ink.background.opacity(0.75), Ink.background.opacity(0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: band)
                            .offset(x: -band + (width + band) * Self.sweepProgress(at: timeline.date))
                        }
                    }
                    .mask { rows }
                    .allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading mail")
    }

    /// Where the highlight is in its cycle, eased in and out, with a short rest between sweeps.
    private static func sweepProgress(at date: Date) -> CGFloat {
        let cycle = 1.6
        let travel = 1.2
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        let t = min(elapsed / travel, 1)
        return CGFloat(t * t * (3 - 2 * t))
    }

    private var rows: some View {
        VStack(spacing: 0) {
            SectionHeaderView("Today")
                .redacted(reason: .placeholder)
            ForEach(0..<rowCount, id: \.self) { index in
                InboxSkeletonRow(index: index, showsAvatar: showsAvatar, compact: compact)
                    .opacity(1 - Double(index) * 0.09)
            }
        }
    }
}

/// One placeholder row: avatar, sender, time, subject and snippet lines of varied length.
private struct InboxSkeletonRow: View {
    let index: Int
    let showsAvatar: Bool
    let compact: Bool

    private static let senderInsets: [CGFloat] = [150, 104, 176, 128, 160, 112, 140]
    private static let subjectInsets: [CGFloat] = [56, 112, 36, 92, 70, 124, 48]
    private static let snippetInsets: [CGFloat] = [90, 40, 120, 64, 100, 30, 84]

    var body: some View {
        HStack(alignment: .top, spacing: InkSpace.m) {
            if showsAvatar {
                Circle()
                    .fill(Ink.fill)
                    .frame(width: avatarSize, height: avatarSize)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                HStack(spacing: InkSpace.l) {
                    bar(height: 12)
                        .padding(.trailing, inset(Self.senderInsets))
                    bar(height: 9)
                        .frame(width: 34)
                }
                bar(height: 10)
                    .padding(.trailing, inset(Self.subjectInsets))
                if !compact {
                    bar(height: 9)
                    bar(height: 9)
                        .padding(.trailing, inset(Self.snippetInsets))
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, InkSpace.gutter)
        .padding(.vertical, compact ? InkSpace.rowVerticalCompact : InkSpace.rowVertical)
    }

    private var avatarSize: CGFloat { compact ? InkSize.avatarSmall : InkSize.avatar }

    private func inset(_ values: [CGFloat]) -> CGFloat { values[index % values.count] }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Ink.fill)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}
#endif
