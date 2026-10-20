#if os(iOS)
import SwiftUI
import UIKit
import InkCore

/// A list row with Ink's own swipe actions (not `.swipeActions`).
///
/// A UIKit pan recognizer that only accepts mostly-horizontal pans drives the row, so vertical
/// scrolling never notices it. Each side has a short and a long threshold (from
/// `SwipeConfiguration`); crossing one changes the colour behind the row, pops the icon and
/// ticks a haptic (light at the short threshold, medium at the long one, a selection tick when
/// backing off). Letting go past a threshold commits: actions that take the conversation out of
/// the list fly the row off-screen first (carrying the finger's speed) and then call `onCommit`,
/// everything else springs back and commits right away. While a released row is still moving,
/// the backdrop keeps the colour of what was chosen and taps are ignored.
struct SwipeRow<Content: View>: View {
    private let configuration: SwipeConfiguration
    private let width: CGFloat
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
    @State private var isDragging = false
    @State private var isRemoving = false
    @State private var lastArm: SwipeRowArm?
    /// What the backdrop shows while a released row travels home or off-screen.
    @State private var release: SwipeRowRelease?
    /// Bumped by every drag, settle and fly-off, so a stale animation completion can't clear
    /// newer state.
    @State private var motionGeneration = 0
    @State private var quietUntil = Date.distantPast

    /// - Parameters:
    ///   - configuration: Which action each swipe direction and length triggers.
    ///   - width: The row's width, measured once by the list rather than by every row. Swipes
    ///     stay off while it is zero.
    ///   - isUnread: Picks "Mark as read" or "Mark as unread" for the read toggle.
    ///   - isFlagged: Picks "Star" or "Unstar" for the star toggle.
    ///   - debugFraction: Renders the row frozen mid-swipe at this fraction of its width
    ///     (positive = swiping right). Used by the screenshot scene.
    ///   - onTap: A plain tap. Ignored while the row is open or still moving.
    ///   - onWillRemove: Called as a removing action starts flying the row off-screen.
    ///   - onCommit: Called once the action should happen.
    init(
        configuration: SwipeConfiguration,
        width: CGFloat,
        isUnread: Bool = false,
        isFlagged: Bool = false,
        debugFraction: CGFloat? = nil,
        onTap: @escaping () -> Void,
        onWillRemove: @escaping (SwipeAction) -> Void = { _ in },
        onCommit: @escaping (SwipeAction) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.configuration = configuration
        self.width = width
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
        Button {
            handleTap()
        } label: {
            content
                .background(Ink.background, ignoresSafeAreaEdges: [])
        }
        .buttonStyle(SwipeRowPressStyle())
        .accessibilityActions {
            ForEach(accessibleActions) { action in
                Button(SwipeRowLabels.title(for: action, isUnread: isUnread, isFlagged: isFlagged)) { onCommit(action) }
            }
        }
        .offset(x: shown)
        .background {
            if let layer = backdrop(offset: shown) {
                layer
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

    /// The finger's translation turned into the row's offset: 1:1 up to the row's width, then
    /// rubber-banding, and only a short, stiff give towards a side with no actions.
    private func resisted(_ translation: CGFloat) -> CGFloat {
        guard let side = SwipeRowSide(offset: translation) else { return 0 }
        let distance = abs(translation)
        guard hasActions(on: side) else {
            return side.sign * SwipeRowMetrics.rubberBand(distance, dimension: SwipeRowMetrics.deadSideGive)
        }
        let limit = max(width, 1)
        guard distance > limit else { return translation }
        let overflow = SwipeRowMetrics.rubberBand(distance - limit, dimension: limit * SwipeRowMetrics.overflowGiveFraction)
        return side.sign * (limit + overflow)
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
        if distance >= longThreshold, pair.long != .none {
            return SwipeRowArm(action: pair.long, isLong: true)
        }
        if distance >= shortThreshold, pair.short != .none {
            return SwipeRowArm(action: pair.short, isLong: false)
        }
        return nil
    }

    /// Custom actions for VoiceOver, Switch Control and Voice Control: the short actions first
    /// (archive by default), then the long ones.
    private var accessibleActions: [SwipeAction] {
        var actions: [SwipeAction] = []
        let configured = [configuration.leftShort, configuration.rightShort, configuration.leftLong, configuration.rightLong]
        for action in configured where action != .none && !actions.contains(action) {
            actions.append(action)
        }
        return actions
    }

    // MARK: Backdrop

    /// The layer behind the row: live while dragging (or frozen for screenshots), and the
    /// released choice while the row animates home or away.
    private func backdrop(offset: CGFloat) -> SwipeRowBackdrop? {
        let side: SwipeRowSide
        let arm: SwipeRowArm?
        let showsTitle: Bool
        let unread: Bool
        let flagged: Bool
        if let release {
            side = release.side
            arm = release.arm
            showsTitle = release.showsTitle
            unread = release.isUnread
            flagged = release.isFlagged
        } else if let liveSide = SwipeRowSide(offset: offset) {
            side = liveSide
            arm = armedAction(at: offset)
            showsTitle = arm != nil && abs(offset) >= longThreshold
            unread = isUnread
            flagged = isFlagged
        } else {
            return nil
        }
        let shownAction = arm?.action ?? hintAction(on: side)
        return SwipeRowBackdrop(
            side: side,
            reveal: abs(offset),
            rowWidth: width,
            tint: arm.map { $0.action.tint(accent: accent) } ?? Ink.fill,
            glyphColor: shownAction == .toggleRead ? settings.accent.onColor : .white,
            symbol: shownAction == .none ? nil : SwipeRowLabels.symbol(for: shownAction, isUnread: unread, isFlagged: flagged),
            title: SwipeRowLabels.title(for: shownAction, isUnread: unread, isFlagged: flagged),
            showsTitle: showsTitle,
            tier: arm?.tier ?? 0
        )
    }

    // MARK: Gesture

    private func handleTap() {
        guard !isDragging, !isRemoving, offset == 0, Date() >= quietUntil else { return }
        onTap()
    }

    private func dragBegan() {
        isDragging = true
        motionGeneration &+= 1
        release = nil
        lastArm = armedAction(at: offset)
        Haptics.prepare()
    }

    private func dragChanged(_ translation: CGFloat) {
        let next = resisted(translation)
        offset = next
        let arm = armedAction(at: next)
        if arm != lastArm {
            SwipeRowFeedback.crossed(from: lastArm, to: arm)
            lastArm = arm
        }
    }

    private func dragEnded(translation: CGFloat, velocity: CGFloat) {
        isDragging = false
        lastArm = nil
        let released = resisted(translation)
        guard let side = SwipeRowSide(offset: released) else {
            settle(from: released, velocity: velocity)
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
        release = SwipeRowRelease(
            side: side,
            arm: chosen,
            showsTitle: chosen != nil && abs(released) >= longThreshold,
            isUnread: isUnread,
            isFlagged: isFlagged
        )
        if let chosen {
            commit(chosen.action, towards: side, from: released, velocity: velocity)
        } else {
            settle(from: released, velocity: velocity)
        }
    }

    private func dragCancelled() {
        isDragging = false
        lastArm = nil
        if let side = SwipeRowSide(offset: offset) {
            release = SwipeRowRelease(side: side, arm: nil, showsTitle: false, isUnread: isUnread, isFlagged: isFlagged)
        }
        settle(from: offset, velocity: 0)
    }

    /// Springs the row home, picking up the finger's speed when it was already heading there.
    private func settle(from start: CGFloat, velocity: CGFloat) {
        quietUntil = Date().addingTimeInterval(SwipeRowMetrics.settleQuietTime)
        motionGeneration &+= 1
        let generation = motionGeneration
        let animation = Animation.interpolatingSpring(
            duration: SwipeRowMetrics.settleDuration,
            bounce: SwipeRowMetrics.settleBounce,
            initialVelocity: SwipeRowMetrics.springVelocity(velocity, from: start, to: 0, limit: SwipeRowMetrics.settleVelocityLimit)
        )
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            offset = 0
        } completion: {
            guard generation == motionGeneration else { return }
            release = nil
        }
    }

    private func commit(_ action: SwipeAction, towards side: SwipeRowSide, from start: CGFloat, velocity: CGFloat) {
        Haptics.soft()
        guard action.removesFromList, action != .snooze else {
            // Read, star and snooze keep the row: spring home, then act (snooze opens the picker).
            settle(from: start, velocity: velocity)
            onCommit(action)
            return
        }
        isRemoving = true
        motionGeneration &+= 1
        onWillRemove(action)
        let target = side.sign * (width + SwipeRowMetrics.flyOffOvershoot)
        let flyOff = Animation.interpolatingSpring(
            duration: SwipeRowMetrics.flyOffDuration,
            bounce: 0,
            initialVelocity: SwipeRowMetrics.springVelocity(velocity, from: start, to: target, limit: SwipeRowMetrics.flyOffVelocityLimit)
        )
        withAnimation(flyOff) {
            offset = target
        }
        Task {
            try? await Task.sleep(for: SwipeRowMetrics.commitDelay)
            onCommit(action)
            // If the conversation is still listed (e.g. archiving from Starred), bring it back.
            try? await Task.sleep(for: SwipeRowMetrics.recoveryDelay)
            guard isRemoving else { return }
            isRemoving = false
            settle(from: offset, velocity: 0)
        }
    }
}

// MARK: - Support

private enum SwipeRowMetrics {
    static let shortMinimum: CGFloat = 72
    static let shortFraction: CGFloat = 0.22
    static let longFraction: CGFloat = 0.60
    static let minimumThresholdGap: CGFloat = 40
    /// How far a row gives towards a side with no actions, at most.
    static let deadSideGive: CGFloat = 44
    /// Past the row's width the rubber band tops out at this fraction of the width.
    static let overflowGiveFraction: CGFloat = 0.3
    static let flingVelocity: CGFloat = 900
    static let flingMinimumDistance: CGFloat = 40
    static let flyOffOvershoot: CGFloat = 48
    static let flyOffDuration: TimeInterval = 0.24
    static let flyOffVelocityLimit: Double = 12
    /// When `onCommit` runs after a row starts flying off (the row is off-screen by then).
    static let commitDelay = Duration.milliseconds(220)
    static let recoveryDelay = Duration.milliseconds(650)
    static let settleDuration: TimeInterval = 0.35
    static let settleBounce: Double = 0.12
    static let settleVelocityLimit: Double = 8
    static let settleQuietTime: TimeInterval = 0.3
    static let glyphInset: CGFloat = 22
    static let glyphMinimumLane: CGFloat = 64

    /// UIScrollView-style resistance: grows with `x` but never reaches `dimension`.
    static func rubberBand(_ x: CGFloat, dimension: CGFloat) -> CGFloat {
        guard x > 0, dimension > 0 else { return 0 }
        return (1 - 1 / ((x * 0.55 / dimension) + 1)) * dimension
    }

    /// The finger's speed as a spring's initial velocity (fractions of the remaining distance
    /// per second). Only speed towards the target carries over, so a row never lurches the
    /// wrong way before heading home.
    static func springVelocity(_ velocity: CGFloat, from start: CGFloat, to end: CGFloat, limit: Double) -> Double {
        let distance = end - start
        guard abs(distance) > 1 else { return 0 }
        return min(max(Double(velocity / distance), 0), limit)
    }
}

private enum SwipeRowSide: Equatable {
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

/// The action that would run on release, and whether it's the side's long action.
private struct SwipeRowArm: Equatable {
    var action: SwipeAction
    var isLong: Bool

    /// 1 for the short action, 2 for the long one (0 is "nothing armed").
    var tier: Int { isLong ? 2 : 1 }
}

/// A row that has been let go: the side and choice to keep showing behind it, and its read and
/// star state at that moment, so labels don't flip while it animates.
private struct SwipeRowRelease: Equatable {
    var side: SwipeRowSide
    /// Nil when the swipe was cancelled.
    var arm: SwipeRowArm?
    var showsTitle: Bool
    var isUnread: Bool
    var isFlagged: Bool
}

/// Titles and glyphs for actions whose wording depends on the conversation's state.
private enum SwipeRowLabels {
    static func title(for action: SwipeAction, isUnread: Bool, isFlagged: Bool) -> String {
        switch action {
        case .toggleRead: return isUnread ? "Mark as read" : "Mark as unread"
        case .flag: return isFlagged ? "Unstar" : "Star"
        default: return action.title
        }
    }

    static func symbol(for action: SwipeAction, isUnread: Bool, isFlagged: Bool) -> String {
        switch action {
        case .toggleRead: return isUnread ? "envelope.open.fill" : "envelope.badge.fill"
        case .flag: return isFlagged ? "star.slash.fill" : "star.fill"
        default: return action.systemImage
        }
    }
}

/// Swipe haptics (§5.2): a light impact arming the short action, a medium one for the long
/// action, and a selection tick when backing off. `Haptics.prepare()` runs as a drag begins.
@MainActor
private enum SwipeRowFeedback {
    static func crossed(from old: SwipeRowArm?, to new: SwipeRowArm?) {
        let before = old?.tier ?? 0
        let after = new?.tier ?? 0
        if after < before || after == 0 {
            Haptics.tick()
        } else {
            Haptics.threshold(isLong: after == 2)
        }
    }
}

/// The layer revealed behind a swiping row: grey with a grey icon until the first threshold,
/// then the action's colour with a white icon that tracks the row's edge (and stays on screen
/// once the row has flown off).
private struct SwipeRowBackdrop: View {
    let side: SwipeRowSide
    let reveal: CGFloat
    let rowWidth: CGFloat
    let tint: Color
    let glyphColor: Color
    let symbol: String?
    let title: String
    let showsTitle: Bool
    /// 0 before the first threshold, 1 short, 2 long. The glyph pops each time it changes.
    let tier: Int

    var body: some View {
        let isRight = side == .right
        let minimumLane = SwipeRowMetrics.glyphMinimumLane
        let lane = min(max(reveal, minimumLane), max(rowWidth, minimumLane))
        Rectangle()
            .fill(tint)
            .animation(InkMotion.snappy, value: tint)
            .overlay(alignment: isRight ? .leading : .trailing) {
                HStack(spacing: InkSpace.s) {
                    if isRight { caption }
                    glyph
                    if !isRight { caption }
                }
                .animation(InkMotion.snappy, value: showsTitle)
                .padding(.horizontal, SwipeRowMetrics.glyphInset)
                .frame(width: lane, alignment: isRight ? .trailing : .leading)
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
                .foregroundStyle(tier == 0 ? Ink.secondary : glyphColor)
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(tier == 0 ? 1 : 1.15)
                .animation(InkMotion.bouncy, value: tier)
                .symbolEffect(.bounce, value: tier)
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
/// runs alongside another recognizer, so the scroll view (and pull to refresh) keeps every
/// vertical drag.
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

    /// iOS 26's full-width "swipe back" (`interactiveContentPopGestureRecognizer`) would race a
    /// leading-to-trailing row swipe on a pushed screen. Make it wait for the row's pan to fail,
    /// the way native swipe actions do; the edge-only back swipe keeps its own priority.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            guard let navigation = Self.navigationController(containing: gestureRecognizer.view) else { return false }
            return otherGestureRecognizer === navigation.interactiveContentPopGestureRecognizer
        }
        #endif
        return false
    }

    private static func navigationController(containing view: UIView?) -> UINavigationController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let navigation = current as? UINavigationController { return navigation }
            responder = current.next
        }
        return nil
    }
}
#endif
