#if os(iOS)
import SwiftUI
import UIKit
import InkCore

/// A list row with Ink's own swipe actions (not `.swipeActions`).
///
/// A UIKit pan recognizer that only accepts mostly-horizontal pans drives the row, so vertical
/// scrolling never notices it. Each side has a short and a long threshold (from
/// `SwipeConfiguration`); crossing one changes the colour behind the row, pops the icon and
/// ticks a haptic. Letting go past a threshold commits: actions that take the conversation out of
/// the list fly the row off-screen first and then call `onCommit`, everything else springs back
/// and commits right away.
struct SwipeRow<Content: View>: View {
    private let configuration: SwipeConfiguration
    private let isUnread: Bool
    private let isFlagged: Bool
    private let debugFraction: CGFloat?
    private let onTap: () -> Void
    private let onWillRemove: (SwipeAction) -> Void
    private let onCommit: (SwipeAction) -> Void
    private let content: Content

    @Environment(\.inkAccent) private var accent
    @Environment(AppSettings.self) private var settings

    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var isDragging = false
    @State private var isRemoving = false
    @State private var lastArm: SwipeRowArm?
    @State private var quietUntil = Date.distantPast

    /// - Parameters:
    ///   - configuration: Which action each swipe direction and length triggers.
    ///   - isUnread: Picks "Mark as read" or "Mark as unread" for the read toggle.
    ///   - isFlagged: Picks "Star" or "Unstar" for the star toggle.
    ///   - debugFraction: Renders the row frozen mid-swipe at this fraction of its width
    ///     (positive = swiping right). Used by the screenshot scene.
    ///   - onTap: A plain tap. Ignored while the row is open or still moving.
    ///   - onWillRemove: Called as a removing action starts flying the row off-screen.
    ///   - onCommit: Called once the action should happen.
    init(
        configuration: SwipeConfiguration,
        isUnread: Bool = false,
        isFlagged: Bool = false,
        debugFraction: CGFloat? = nil,
        onTap: @escaping () -> Void,
        onWillRemove: @escaping (SwipeAction) -> Void = { _ in },
        onCommit: @escaping (SwipeAction) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.configuration = configuration
        self.isUnread = isUnread
        self.isFlagged = isFlagged
        self.debugFraction = debugFraction
        self.onTap = onTap
        self.onWillRemove = onWillRemove
        self.onCommit = onCommit
        self.content = content()
    }

    var body: some View {
        let shown = displayedOffset
        let arm = armedAction(at: shown)
        Button {
            handleTap()
        } label: {
            content
                .background(Ink.background, ignoresSafeAreaEdges: [])
        }
        .buttonStyle(SwipeRowPressStyle())
        .accessibilityActions {
            ForEach(accessibleActions) { action in
                Button(title(for: action)) { onCommit(action) }
            }
        }
        .offset(x: shown)
        .background {
            if shown != 0 {
                backdrop(offset: shown, arm: arm)
            }
        }
        .clipped()
        .gesture(
            SwipeRowPan(
                isEnabled: !isRemoving && width > 0 && debugFraction == nil,
                allowsRight: hasActions(on: .right),
                allowsLeft: hasActions(on: .left),
                onBegan: { dragBegan() },
                onChanged: { translation in dragChanged(translation) },
                onEnded: { translation, velocity in dragEnded(translation: translation, velocity: velocity) },
                onCancelled: { dragCancelled() }
            )
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
    }

    // MARK: Geometry

    private var displayedOffset: CGFloat {
        if let debugFraction, width > 0 { return width * debugFraction }
        return offset
    }

    private var shortThreshold: CGFloat {
        max(SwipeRowMetrics.shortMinimum, width * SwipeRowMetrics.shortFraction)
    }

    private var longThreshold: CGFloat {
        max(shortThreshold + SwipeRowMetrics.minimumThresholdGap, width * SwipeRowMetrics.longFraction)
    }

    /// The finger's translation turned into the row's offset: 1:1 up to the row's width, a
    /// third of the rate past it, and barely at all towards a side with no actions.
    private func resisted(_ translation: CGFloat) -> CGFloat {
        guard let side = SwipeRowSide(offset: translation) else { return 0 }
        guard hasActions(on: side) else { return translation * SwipeRowMetrics.deadSideResistance }
        let distance = abs(translation)
        let limit = max(width, 1)
        let eased = distance <= limit ? distance : limit + (distance - limit) * SwipeRowMetrics.rubberBand
        return side.sign * eased
    }

    // MARK: Actions

    private func actionPair(on side: SwipeRowSide) -> (short: SwipeAction, long: SwipeAction) {
        switch side {
        case .right: return (configuration.rightShort, configuration.rightLong)
        case .left: return (configuration.leftShort, configuration.leftLong)
        }
    }

    private func hasActions(on side: SwipeRowSide) -> Bool {
        let pair = actionPair(on: side)
        return pair.short != .none || pair.long != .none
    }

    /// The action previewed (in grey) before the first threshold.
    private func hintAction(on side: SwipeRowSide) -> SwipeAction {
        let pair = actionPair(on: side)
        return pair.short != .none ? pair.short : pair.long
    }

    /// What letting go at `offset` would do, skipping `.none` slots.
    private func armedAction(at offset: CGFloat) -> SwipeRowArm? {
        guard width > 0, let side = SwipeRowSide(offset: offset) else { return nil }
        let distance = abs(offset)
        let pair = actionPair(on: side)
        let pastLong = distance >= longThreshold
        if pastLong, pair.long != .none {
            return SwipeRowArm(action: pair.long, isLong: true)
        }
        if distance >= shortThreshold, pair.short != .none {
            return SwipeRowArm(action: pair.short, isLong: pastLong)
        }
        return nil
    }

    private var accessibleActions: [SwipeAction] {
        var actions: [SwipeAction] = []
        let configured = [configuration.rightShort, configuration.rightLong, configuration.leftShort, configuration.leftLong]
        for action in configured where action != .none && !actions.contains(action) {
            actions.append(action)
        }
        return actions
    }

    private func title(for action: SwipeAction) -> String {
        switch action {
        case .toggleRead: return isUnread ? "Mark as read" : "Mark as unread"
        case .flag: return isFlagged ? "Unstar" : "Star"
        default: return action.title
        }
    }

    private func symbol(for action: SwipeAction) -> String {
        switch action {
        case .toggleRead: return isUnread ? "envelope.open.fill" : "envelope.badge.fill"
        case .flag: return isFlagged ? "star.slash.fill" : "star.fill"
        default: return action.systemImage
        }
    }

    // MARK: Backdrop

    private func backdrop(offset: CGFloat, arm: SwipeRowArm?) -> some View {
        let side: SwipeRowSide = offset > 0 ? .right : .left
        let shownAction = arm?.action ?? hintAction(on: side)
        return SwipeRowBackdrop(
            side: side,
            reveal: abs(offset),
            arm: arm,
            tint: arm.map { $0.action.tint(accent: accent) } ?? Ink.fill,
            glyphColor: shownAction == .toggleRead ? settings.accent.onColor : .white,
            symbol: shownAction == .none ? nil : symbol(for: shownAction),
            title: title(for: shownAction),
            showsTitle: arm?.isLong == true
        )
    }

    // MARK: Gesture

    private func handleTap() {
        guard !isDragging, !isRemoving, offset == 0, Date() >= quietUntil else { return }
        onTap()
    }

    private func dragBegan() {
        isDragging = true
        lastArm = armedAction(at: offset)
    }

    private func dragChanged(_ translation: CGFloat) {
        let next = resisted(translation)
        offset = next
        let arm = armedAction(at: next)
        if arm != lastArm {
            lastArm = arm
            Haptics.threshold()
        }
    }

    private func dragEnded(translation: CGFloat, velocity: CGFloat) {
        isDragging = false
        lastArm = nil
        let released = resisted(translation)
        guard let side = SwipeRowSide(offset: released) else {
            settle()
            return
        }
        var chosen = armedAction(at: released)
        let isFling = abs(velocity) > SwipeRowMetrics.flingVelocity
        let isTowardsSide = velocity * released > 0
        if isFling, !isTowardsSide {
            // A quick flick back cancels, wherever the row was.
            chosen = nil
        } else if chosen == nil, isFling, abs(released) > SwipeRowMetrics.flingMinimumDistance {
            let short = actionPair(on: side).short
            if short != .none { chosen = SwipeRowArm(action: short, isLong: false) }
        }
        if let chosen {
            commit(chosen.action, towards: side)
        } else {
            settle()
        }
    }

    private func dragCancelled() {
        isDragging = false
        lastArm = nil
        settle()
    }

    private func settle() {
        quietUntil = Date().addingTimeInterval(SwipeRowMetrics.settleQuietTime)
        withAnimation(InkMotion.swipeSettle) { offset = 0 }
    }

    private func commit(_ action: SwipeAction, towards side: SwipeRowSide) {
        Haptics.soft()
        guard action.removesFromList, action != .snooze else {
            // Read, star and snooze keep the row: spring home, then act (snooze opens the picker).
            settle()
            onCommit(action)
            return
        }
        isRemoving = true
        onWillRemove(action)
        withAnimation(SwipeRowMetrics.flyOff) {
            offset = side.sign * (width + SwipeRowMetrics.flyOffOvershoot)
        }
        Task {
            try? await Task.sleep(for: SwipeRowMetrics.flyOffDuration)
            onCommit(action)
            // If the conversation is still listed (e.g. archiving from Starred), bring it back.
            try? await Task.sleep(for: SwipeRowMetrics.recoveryDelay)
            guard isRemoving else { return }
            isRemoving = false
            settle()
        }
    }
}

// MARK: - Support

private enum SwipeRowMetrics {
    static let shortMinimum: CGFloat = 72
    static let shortFraction: CGFloat = 0.22
    static let longFraction: CGFloat = 0.58
    static let minimumThresholdGap: CGFloat = 40
    static let rubberBand: CGFloat = 1.0 / 3.0
    static let deadSideResistance: CGFloat = 0.12
    static let flingVelocity: CGFloat = 900
    static let flingMinimumDistance: CGFloat = 24
    static let flyOffOvershoot: CGFloat = 48
    static let flyOff = Animation.spring(response: 0.26, dampingFraction: 1)
    static let flyOffDuration = Duration.milliseconds(220)
    static let recoveryDelay = Duration.milliseconds(650)
    static let settleQuietTime: TimeInterval = 0.32
    static let glyphInset: CGFloat = 22
    static let glyphMinimumLane: CGFloat = 64
}

private enum SwipeRowSide {
    /// The finger moves right, revealing the leading edge.
    case right
    /// The finger moves left, revealing the trailing edge.
    case left

    init?(offset: CGFloat) {
        if offset > 0 {
            self = .right
        } else if offset < 0 {
            self = .left
        } else {
            return nil
        }
    }

    var sign: CGFloat { self == .right ? 1 : -1 }
}

/// The action that would run on release, and whether the row is past the long threshold.
private struct SwipeRowArm: Equatable {
    var action: SwipeAction
    var isLong: Bool
}

/// The layer revealed behind a swiping row: grey with a grey icon until the first threshold,
/// then the action's colour with a white icon that tracks the row's edge.
private struct SwipeRowBackdrop: View {
    let side: SwipeRowSide
    let reveal: CGFloat
    let arm: SwipeRowArm?
    let tint: Color
    let glyphColor: Color
    let symbol: String?
    let title: String
    let showsTitle: Bool

    var body: some View {
        let isRight = side == .right
        Rectangle()
            .fill(tint)
            .animation(InkMotion.snappy, value: arm)
            .overlay(alignment: isRight ? .leading : .trailing) {
                HStack(spacing: InkSpace.s) {
                    if isRight { caption }
                    glyph
                    if !isRight { caption }
                }
                .animation(InkMotion.snappy, value: showsTitle)
                .padding(.horizontal, SwipeRowMetrics.glyphInset)
                .frame(width: max(reveal, SwipeRowMetrics.glyphMinimumLane), alignment: isRight ? .trailing : .leading)
                .opacity(Double(min(1, max(0, (reveal - 12) / 44))))
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var caption: some View {
        if showsTitle {
            Text(title)
                .font(InkFont.button)
                .foregroundStyle(glyphColor)
                .lineLimit(1)
                .fixedSize()
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    @ViewBuilder private var glyph: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(arm == nil ? Ink.secondary : glyphColor)
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(arm == nil ? 1 : 1.15)
                .animation(InkMotion.bouncy, value: arm)
                .symbolEffect(.bounce, value: arm)
        }
    }
}

/// Dims the row while a finger rests on it.
private struct SwipeRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Rectangle()
                    .fill(Ink.selection)
                    .opacity(configuration.isPressed ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(InkMotion.fade, value: configuration.isPressed)
    }
}

/// A pan that only starts for mostly-horizontal movement towards a side with actions, and never
/// runs alongside another recognizer, so the scroll view keeps every vertical drag.
@MainActor
private struct SwipeRowPan: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var allowsRight: Bool
    var allowsLeft: Bool
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    var onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> SwipeRowPanDelegate {
        SwipeRowPanDelegate()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        apply(to: context.coordinator)
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        apply(to: context.coordinator)
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let view = recognizer.view
        switch recognizer.state {
        case .began:
            onBegan()
            onChanged(recognizer.translation(in: view).x)
        case .changed:
            onChanged(recognizer.translation(in: view).x)
        case .ended:
            onEnded(recognizer.translation(in: view).x, recognizer.velocity(in: view).x)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    private func apply(to delegate: SwipeRowPanDelegate) {
        delegate.isEnabled = isEnabled
        delegate.allowsRight = allowsRight
        delegate.allowsLeft = allowsLeft
    }
}

@MainActor
private final class SwipeRowPanDelegate: NSObject, UIGestureRecognizerDelegate {
    var isEnabled = true
    var allowsRight = true
    var allowsLeft = true

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: pan.view)
        let translation = pan.translation(in: pan.view)
        // Velocity says more about intent; slow drags fall back to the distance moved so far.
        let usesVelocity = abs(velocity.x) + abs(velocity.y) > 40
        let dx = usesVelocity ? velocity.x : translation.x
        let dy = usesVelocity ? velocity.y : translation.y
        guard abs(dx) > abs(dy) * 1.2 else { return false }
        return dx > 0 ? allowsRight : allowsLeft
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
#endif
