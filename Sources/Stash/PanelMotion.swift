import AppKit
import HUDKit

/// How the panel appears or goes away for one `panel show` / `panel hide` (MacHUD's
/// `from=` / `to=` / `anchor=` / `reason=` options, see `HUDPanelTransition`).
struct PanelMotionPlan: Equatable {
    /// Edge to slide out of (show) or back toward (hide); nil fades in place.
    var edge: HUDEdge?
    var duration: TimeInterval
    /// Whether the window becomes key. Hover shows never take focus from the app under the
    /// pointer; clicks, summons and plain shows (hotkey, menu, CLI) do.
    var takesKey: Bool

    /// Hover shows are near-instant so moving between dock buttons cross-fades.
    static let hoverShowDuration: TimeInterval = 0.08
    /// Any show without `reason=hover`.
    static let showDuration: TimeInterval = 0.1
    /// Slides out of the dock on a click or summon.
    static let slideShowDuration: TimeInterval = HUDAnimation.revealDuration
    /// `hide to=<edge>`: MacHUD hides when the pointer leaves, so it goes almost at once.
    static let slideHideDuration: TimeInterval = 0.1
    /// Plain hide (Escape, ⌘W, dismiss, `panel hide` without `to=`).
    static let hideDuration: TimeInterval = 0.08

    static func show(_ t: HUDPanelTransition) -> PanelMotionPlan {
        let hover = t.reason == .hover
        let duration = hover ? hoverShowDuration : (t.from != nil ? slideShowDuration : showDuration)
        return PanelMotionPlan(edge: t.from, duration: duration, takesKey: !hover)
    }

    static func hide(_ t: HUDPanelTransition) -> PanelMotionPlan {
        PanelMotionPlan(edge: t.to, duration: t.to != nil ? slideHideDuration : hideDuration, takesKey: false)
    }

    /// Where the panel rests once shown: the frame MacHUD assigned with `panel frame`, else
    /// next to the dock button (`anchor` + `from`), else where it already is.
    @MainActor
    static func restFrame(assigned: CGRect?, transition t: HUDPanelTransition, current: CGRect) -> CGRect {
        if let assigned { return assigned }
        return t.panelFrame(size: current.size) ?? current
    }
}

/// Slides/fades one window with per-call durations. Every show or hide bumps a generation so
/// a show that arrives while a hide is still fading (the hover cross-fade) wins: the stale
/// hide's completion does not order the window out.
@MainActor
final class PanelMotion {
    let window: NSWindow
    private(set) var generation: UInt = 0
    /// The frame the window is shown at (so a hide interrupting a slide-in restores the
    /// destination, not the half-way frame).
    private(set) var restFrame: CGRect?
    /// True while a motion animation owns the frame (so frame saving can ignore it).
    private(set) var isAnimating = false

    init(window: NSWindow) { self.window = window }

    func show(at rest: CGRect, plan: PanelMotionPlan, completion: (@MainActor () -> Void)? = nil) {
        generation &+= 1
        let current = generation
        restFrame = rest
        isAnimating = true
        if !window.isVisible {
            window.alphaValue = 0
            window.setFrame(plan.edge.map { HUDAnimation.offset(rest, toward: $0) } ?? rest, display: false)
        }
        if plan.takesKey, window.canBecomeKey { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        // Always animate the frame too: it replaces a hide's slide still in flight (whose
        // frame may not have moved yet, so comparing the live frame would miss it).
        HUDAnimation.animate(window, to: rest, alpha: 1, duration: plan.duration,
                             timing: HUDAnimation.revealTiming) { [weak self] in
            guard let self, self.generation == current else { return }
            self.isAnimating = false
            completion?()
        }
    }

    func hide(plan: PanelMotionPlan, completion: (@MainActor () -> Void)? = nil) {
        generation &+= 1
        let current = generation
        let rest = restFrame ?? window.frame
        restFrame = nil
        isAnimating = true
        let destination = plan.edge.map { HUDAnimation.offset(rest, toward: $0) }
        HUDAnimation.animate(window, to: destination, alpha: 0, duration: plan.duration,
                             timing: HUDAnimation.concealTiming) { [weak self] in
            guard let self, self.generation == current else { return }
            self.window.orderOut(nil)
            if destination != nil { self.window.setFrame(rest, display: false) }
            self.window.alphaValue = 1
            self.isAnimating = false
            completion?()
        }
    }

    /// MacHUD moved the shown panel (`panel frame`): a later hide slides from there.
    func setRestFrame(_ frame: CGRect) { restFrame = frame }

    /// The user moved or resized the window: its current frame is the one to come back to.
    func userMovedWindow() {
        if !isAnimating, window.isVisible { restFrame = window.frame }
    }

    /// Stops tracking motion (e.g. parking takes the frame over).
    func cancel() {
        generation &+= 1
        restFrame = nil
        isAnimating = false
    }
}
