import AppKit
import XCTest
@testable import StashKit

@MainActor
final class ClipboardWatcherTests: PasteboardTestCase {
    private var front: String? = "com.apple.TextEdit"
    private var secure = false
    private let clock = Clock()

    private func makeWatcher(ignored: Set<String> = []) -> ClipboardWatcher {
        ClipboardWatcher(pasteboard: pasteboard, ignoredBundleIDs: ignored, now: { [clock] in clock.now },
                         frontmostBundleID: { [unowned self] in self.front },
                         isSecureInputEnabled: { [unowned self] in self.secure })
    }

    func testIgnoresContentsPresentAtLaunch() {
        copyText("before launch")
        let w = makeWatcher()
        XCTAssertNil(w.poll())
    }

    func testReportsEachChangeOnce() throws {
        let w = makeWatcher()
        copyText("one")
        clock.advance(3)
        let e = try XCTUnwrap(w.poll())
        XCTAssertEqual(e.payload.text, "one")
        XCTAssertEqual(e.sourceBundleID, "com.apple.TextEdit")
        XCTAssertEqual(e.date, clock.now)
        XCTAssertNil(w.poll(), "no change, no event")
        copyText("two")
        XCTAssertEqual(w.poll()?.payload.text, "two")
    }

    func testOnlyTheLatestOfSeveralCopiesBetweenPollsIsSeen() {
        let w = makeWatcher()
        copyText("a"); copyText("b"); copyText("c")
        XCTAssertEqual(w.poll()?.payload.text, "c")
    }

    func testSkipsDuringSecureInput() {
        let w = makeWatcher()
        var skipped: [ClipboardWatcher.SkipReason] = []
        w.onSkip = { skipped.append($0) }
        secure = true
        copyText("hunter2")
        XCTAssertNil(w.poll())
        secure = false
        XCTAssertNil(w.poll(), "a skipped change stays consumed")
        XCTAssertEqual(skipped, [.secureInput])
    }

    func testSkipsIgnoredApps() {
        let w = makeWatcher(ignored: ["com.1password.1password"])
        var skipped: [ClipboardWatcher.SkipReason] = []
        w.onSkip = { skipped.append($0) }
        front = "com.1password.1password"
        copyText("secret")
        XCTAssertNil(w.poll())
        front = "com.apple.Safari"
        copyText("public")
        XCTAssertEqual(w.poll()?.payload.text, "public")
        XCTAssertEqual(skipped, [.ignoredApp])
    }

    func testSkipsConcealedAndOwnWrites() {
        let w = makeWatcher()
        var skipped: [ClipboardWatcher.SkipReason] = []
        w.onSkip = { skipped.append($0) }
        copyText("otp", extraTypes: [.init("org.nspasteboard.ConcealedType")])
        XCTAssertNil(w.poll())
        ClipReader.write(text: "from stash", to: pasteboard)
        XCTAssertNil(w.poll())
        XCTAssertEqual(skipped, [.concealed, .ownWrite])
    }

    func testPauseAndSkipCurrent() {
        let w = makeWatcher()
        w.isPaused = true
        copyText("while paused")
        XCTAssertNil(w.poll())
        w.isPaused = false
        copyText("later")
        w.skipCurrent()
        XCTAssertNil(w.poll())
    }

    func testTimerDrivesPolling() {
        let w = makeWatcher()
        w.interval = 0.05
        let got = expectation(description: "clip")
        w.onClip = { if $0.payload.text == "timed" { got.fulfill() } }
        w.start()
        copyText("timed")
        wait(for: [got], timeout: 2)
        w.stop()
        XCTAssertFalse(w.isRunning)
    }
}
