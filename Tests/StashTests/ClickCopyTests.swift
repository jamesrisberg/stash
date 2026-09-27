import AppKit
import StashKit
@testable import Stash
import XCTest

/// Click = copy: writes to the model's (injected, private) pasteboard, leaves the order alone
/// and is never recorded again by Stash's own watcher.
@MainActor
final class ClickCopyTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var root: URL!
    private var model: AppModel!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("xyz.machud.stash.tests.\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appending(path: "StashClickTests-\(UUID().uuidString)")
        model = AppModel(directory: root, pasteboard: pasteboard)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    /// Copies from "another app": plain string, no Stash marker, recorded through the watcher.
    private func externalCopy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        XCTAssertNotNil(model.watcher.poll())
    }

    func testClickCopyWritesToInjectedPasteboardWithoutDuplicatingOrReordering() throws {
        externalCopy("alpha"); externalCopy("beta"); externalCopy("gamma")
        let before = model.clips.map(\.id)
        XCTAssertEqual(model.clips.map(\.text), ["gamma", "beta", "alpha"])
        let alpha = model.clips[2]

        XCTAssertTrue(model.clickCopy(alpha))
        XCTAssertEqual(pasteboard.string(forType: .string), "alpha")
        XCTAssertNotEqual(NSPasteboard.general.name, pasteboard.name)

        // The watcher sees the change but skips Stash's own write.
        XCTAssertNil(model.watcher.poll())
        XCTAssertEqual(model.clips.map(\.id), before, "no new clip, no reorder")
        XCTAssertEqual(model.selectedID, alpha.id)
        XCTAssertEqual(model.copiedID, alpha.id)
    }

    func testOwnWriteIsSkippedByMarkerEvenIfChangeCountWasMissed() {
        externalCopy("alpha"); externalCopy("beta")
        let alpha = model.clips[1]
        // Another poll path (a fresh watcher on the same pasteboard) that did not see the
        // skip: the Stash marker alone keeps it out.
        let other = ClipboardWatcher(pasteboard: pasteboard)
        XCTAssertTrue(model.clickCopy(alpha))
        var skipped: ClipboardWatcher.SkipReason?
        other.onSkip = { skipped = $0 }
        XCTAssertNil(other.poll())
        XCTAssertEqual(skipped, .ownWrite)
    }

    func testCopiedFlagClearsAfter600ms() {
        externalCopy("alpha")
        model.clickCopy(model.clips[0])
        XCTAssertNotNil(model.copiedID)
        RunLoop.main.run(until: Date().addingTimeInterval(AppModel.copiedFeedbackSeconds + 0.25))
        XCTAssertNil(model.copiedID)
    }

    func testEnterStyleCopyStillPromotes() {
        externalCopy("alpha"); externalCopy("beta")
        XCTAssertTrue(model.copy(model.clips[1]))
        XCTAssertEqual(model.clips.first?.text, "alpha")
        XCTAssertNil(model.watcher.poll())
        XCTAssertEqual(model.clips.count, 2)
    }

    func testClickDispatch() {
        XCTAssertEqual(AppModel.clickAction(clickCount: 1, modifiers: []), .copy)
        XCTAssertEqual(AppModel.clickAction(clickCount: 2, modifiers: []), .paste)
        XCTAssertEqual(AppModel.clickAction(clickCount: 1, modifiers: .command), .togglePin)
        XCTAssertEqual(AppModel.clickAction(clickCount: 2, modifiers: .command), .togglePin)
        XCTAssertEqual(AppModel.clickAction(clickCount: 1, modifiers: .shift), .copy)
    }

    func testClickWithoutEventCopiesAndCommandClickPins() throws {
        externalCopy("alpha")
        let clip = model.clips[0]
        model.click(clip, event: nil)
        XCTAssertEqual(model.copiedID, clip.id)
        XCTAssertFalse(model.clips[0].pinned)
        let cmdClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: .command,
                                                        timestamp: 0, windowNumber: 0, context: nil,
                                                        eventNumber: 0, clickCount: 1, pressure: 0))
        model.click(clip, event: cmdClick)
        XCTAssertTrue(model.clips[0].pinned)
    }
}

final class ClipRowChromeTests: XCTestCase {
    func testIdle() {
        let c = ClipRowChrome()
        XCTAssertEqual(c.hoverLift, 0)
        XCTAssertFalse(c.iconHighlighted)
        XCTAssertNil(c.hint)
        XCTAssertFalse(c.showsHint)
    }

    func testHoverLiftsBrightensAndHints() {
        let c = ClipRowChrome(hovered: true)
        XCTAssertEqual(c.hoverLift, 0.08)
        XCTAssertTrue(c.iconHighlighted)
        XCTAssertEqual(c.hint, "Click to copy · ⏎ paste")
    }

    func testSelectionKeepsItsFillButStillHints() {
        let c = ClipRowChrome(hovered: true, selected: true)
        XCTAssertEqual(c.hoverLift, 0)
        XCTAssertEqual(c.hint, ClipRowChrome.hoverText)
    }

    func testCopiedWinsOverHoverAndShowsWithoutHover() {
        XCTAssertEqual(ClipRowChrome(hovered: true, copied: true).hint, "Copied")
        let off = ClipRowChrome(copied: true)
        XCTAssertEqual(off.hint, "Copied")
        XCTAssertTrue(off.iconHighlighted)
    }
}
