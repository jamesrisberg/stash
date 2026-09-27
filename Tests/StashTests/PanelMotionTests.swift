import AppKit
import HUDKit
@testable import Stash
import XCTest

/// MacHUD's show/hide options: which motion each gets, where the panel rests, and that a
/// show arriving mid-hide (the hover cross-fade) leaves the panel on screen.
@MainActor
final class PanelMotionTests: XCTestCase {
    private func transition(_ options: [String: String]) -> HUDPanelTransition { HUDPanelTransition(options) }

    func testHoverShowIsAQuickFadeThatNeverTakesKey() {
        let plan = PanelMotionPlan.show(transition(["from": "bottom", "anchor": "100,0,48,48", "reason": "hover"]))
        XCTAssertEqual(plan.edge, .bottom)
        XCTAssertEqual(plan.duration, 0.08)
        XCTAssertFalse(plan.takesKey)
    }

    func testClickAndSummonSlideAndTakeKey() {
        for reason in ["click", "summon"] {
            let plan = PanelMotionPlan.show(transition(["from": "left", "reason": reason]))
            XCTAssertEqual(plan.edge, .left, reason)
            XCTAssertEqual(plan.duration, HUDAnimation.revealDuration, reason)
            XCTAssertTrue(plan.takesKey, reason)
        }
    }

    func testPlainShowFadesInPlaceAndTakesKey() {
        let plan = PanelMotionPlan.show(transition([:]))
        XCTAssertNil(plan.edge)
        XCTAssertEqual(plan.duration, 0.1)
        XCTAssertTrue(plan.takesKey)
        // Unknown reasons are treated like a plain show.
        XCTAssertTrue(PanelMotionPlan.show(transition(["reason": "poke"])).takesKey)
    }

    func testHideToEdgeIsATenthOfASecond() {
        let slide = PanelMotionPlan.hide(transition(["to": "top", "reason": "hover"]))
        XCTAssertEqual(slide.edge, .top)
        XCTAssertEqual(slide.duration, 0.1)
        let plain = PanelMotionPlan.hide(transition([:]))
        XCTAssertNil(plain.edge)
        XCTAssertEqual(plain.duration, 0.08)
    }

    func testRestFramePrefersAssignedThenAnchorThenCurrent() throws {
        let current = CGRect(x: 10, y: 10, width: 460, height: 560)
        let assigned = CGRect(x: 300, y: 200, width: 400, height: 500)
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let anchor = CGRect(x: screen.midX - 24, y: screen.minY, width: 48, height: 48)
        let t = transition(["from": "bottom", "anchor": HUDPanelTransition.formatAnchor(anchor)])

        XCTAssertEqual(PanelMotionPlan.restFrame(assigned: assigned, transition: t, current: current), assigned)
        let byAnchor = PanelMotionPlan.restFrame(assigned: nil, transition: t, current: current)
        XCTAssertEqual(byAnchor.size, current.size)
        XCTAssertEqual(byAnchor.midX, anchor.midX, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(byAnchor.minY, anchor.maxY, "above the bottom dock button")
        // Anchor without from= cannot place the panel.
        XCTAssertEqual(PanelMotionPlan.restFrame(assigned: nil, transition: transition(["anchor": "1,2,3,4"]),
                                                 current: current), current)
    }

    func testHostHandlesDockOptions() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "stash-motion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(directory: dir, pasteboard: NSPasteboard(name: .init("stash-motion-\(UUID().uuidString)")))
        let panel = PanelController(model: model, frames: nil)
        defer { panel.panel.orderOut(nil) }
        let host = ControlHost(model: model, panel: panel) { _, _ in ["ok": true] }
        let router = try XCTUnwrap(host.router)
        func send(_ args: [String: String]) -> [String: Any] {
            var reply: [String: Any] = [:]
            router.handle("panel", args: args) { reply = $0 }
            return reply
        }

        // MacHUD places the panel, then shows it on hover: it rests at that frame, unfocused.
        // Inside the main screen's visible area, so AppKit does not push the window on-screen on a
        // small display (the CI runner's).
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let assigned = CGRect(x: (visible.minX + 40).rounded(), y: (visible.minY + 40).rounded(), width: 460, height: 560)
        XCTAssertEqual(send(["id": "history", "frame": "1", "x": "\(Int(assigned.minX))", "y": "\(Int(assigned.minY))", "w": "460", "h": "560"])["ok"] as? Bool, true)
        let shown = send(["id": "history", "show": "1", "from": "bottom", "anchor": "400,0,48,48", "reason": "hover"])
        XCTAssertEqual(shown["visible"] as? Bool, true)
        spin(until: panel.panel.frame == assigned)
        XCTAssertTrue(panel.panel.isVisible)
        XCTAssertFalse(panel.panel.isKeyWindow, "hover must not take focus")
        XCTAssertEqual(panel.panel.frame, assigned)

        // Pointer leaves and comes straight back.
        XCTAssertEqual(send(["id": "history", "hide": "1", "to": "bottom", "reason": "hover"])["visible"] as? Bool, false)
        XCTAssertEqual(send(["id": "history", "show": "1", "from": "bottom", "reason": "hover"])["visible"] as? Bool, true)
        spin(until: panel.panel.frame == assigned && panel.panel.alphaValue == 1)
        XCTAssertTrue(panel.panel.isVisible)
        XCTAssertEqual(panel.panel.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(panel.panel.frame, assigned)

        XCTAssertEqual(send(["id": "history", "hide": "1", "to": "bottom"])["visible"] as? Bool, false)
        spin(until: !panel.panel.isVisible && panel.panel.frame == assigned)
        XCTAssertFalse(panel.panel.isVisible)
        XCTAssertEqual(panel.panel.frame, assigned, "slide-out restores the rest frame")

        // Malformed options are rejected by the router before they reach the host.
        XCTAssertEqual(send(["id": "history", "show": "1", "from": "middle"])["ok"] as? Bool, false)
    }

    func testShowDuringHideWins() {
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 300, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let motion = PanelMotion(window: window)
        let rest = CGRect(x: 200, y: 200, width: 300, height: 200)
        let hover = PanelMotionPlan.show(HUDPanelTransition(["from": "bottom", "reason": "hover"]))

        motion.show(at: rest, plan: hover)
        spin(0.2)
        XCTAssertTrue(window.isVisible)

        // Pointer leaves then comes straight back: hide, then show, back to back.
        motion.hide(plan: .hide(HUDPanelTransition(["to": "bottom"])))
        motion.show(at: rest, plan: hover)
        spin(0.4)
        XCTAssertTrue(window.isVisible, "the stale hide must not order the window out")
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(window.frame, rest)

        // A hide on its own still finishes: ordered out, frame and alpha restored.
        motion.hide(plan: .hide(HUDPanelTransition(["to": "bottom"])))
        spin(0.4)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.frame, rest)
        XCTAssertEqual(window.alphaValue, 1)
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes: the motions are
    /// run-loop animations, and the CI runner is slow to advance them.
    private func spin(until condition: @autoclosure () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
