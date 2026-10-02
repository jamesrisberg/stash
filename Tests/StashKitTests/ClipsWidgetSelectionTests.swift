import XCTest
@testable import StashKit

/// What the desktop `clips` widget shows: the newest clips, optionally only pinned ones.
final class ClipsWidgetSelectionTests: XCTestCase {
    private func clip(_ text: String, pinned: Bool = false) -> Clip {
        Clip(kind: .text, text: text, pinned: pinned, size: text.utf8.count, contentHash: Clip.hash(text, kind: .text))
    }

    /// History order, newest first, as `ClipStore.clips` has it.
    private lazy var history = [clip("e"), clip("d", pinned: true), clip("c"), clip("b", pinned: true), clip("a")]

    func testTakesTheNewestInHistoryOrder() {
        XCTAssertEqual(ClipsWidgetSelection.latest(history, pinnedOnly: false, limit: 1).map(\.text), ["e"])
        XCTAssertEqual(ClipsWidgetSelection.latest(history, pinnedOnly: false, limit: 3).map(\.text), ["e", "d", "c"])
    }

    func testPinnedOnlyKeepsOnlyPinnedClipsNewestFirst() {
        XCTAssertEqual(ClipsWidgetSelection.latest(history, pinnedOnly: true, limit: 1).map(\.text), ["d"])
        XCTAssertEqual(ClipsWidgetSelection.latest(history, pinnedOnly: true, limit: 3).map(\.text), ["d", "b"])
    }

    func testFewerClipsThanTheLimitAndNone() {
        XCTAssertEqual(ClipsWidgetSelection.latest([clip("only")], pinnedOnly: false, limit: 3).count, 1)
        XCTAssertTrue(ClipsWidgetSelection.latest([], pinnedOnly: false, limit: 3).isEmpty)
        XCTAssertTrue(ClipsWidgetSelection.latest(history.filter { !$0.pinned }, pinnedOnly: true, limit: 3).isEmpty)
        XCTAssertTrue(ClipsWidgetSelection.latest(history, pinnedOnly: false, limit: 0).isEmpty)
    }

    func testSnippetJoinsLinesAndTruncates() {
        XCTAssertEqual(clip("  first line\n\n  second line  \n").snippet(limit: 120), "first line second line")
        XCTAssertEqual(clip(String(repeating: "x", count: 300)).snippet(limit: 120).count, 120)
        XCTAssertEqual(Clip(kind: .image, size: 0, contentHash: "h").snippet(limit: 120), "")
    }
}
