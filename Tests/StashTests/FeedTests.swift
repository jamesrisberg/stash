import AppKit
import HUDKit
import StashKit
@testable import Stash
import XCTest

/// HUDKit's `text-feed` capability: `feed {action:"add", text, source, title?, date?}` records a
/// history item without ever touching the pasteboard.
@MainActor
final class FeedTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var root: URL!
    private var model: AppModel!
    private var host: ControlHost!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("xyz.machud.stash.tests.\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appending(path: "StashFeedTests-\(UUID().uuidString)")
        model = AppModel(directory: root, pasteboard: pasteboard)
        let panel = PanelController(model: model, frames: nil)
        host = ControlHost(model: model, panel: panel) { _, _ in ["ok": true] }
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    private func feed(_ args: [String: String]) -> [String: Any] {
        var reply: [String: Any] = [:]
        host.handleFeed(args) { reply = $0 }
        return reply
    }

    // MARK: - AppModel.receiveFeedItem

    func testReceiveFeedItemNeverTouchesThePasteboard() {
        let before = pasteboard.changeCount
        let clip = model.receiveFeedItem(text: "call the vet back", source: "Dictation", title: nil, date: Date())
        XCTAssertNotNil(clip)
        XCTAssertEqual(pasteboard.changeCount, before, "a feed item is not a clipboard event")
        XCTAssertNil(model.watcher.poll(), "the watcher never sees it either")
        XCTAssertEqual(model.clips.first?.feedSource, "Dictation")
    }

    func testReceiveFeedItemHonoursIgnoredFeedSources() throws {
        try model.updateSettings(try model.settings.applying(["ignoredFeedSources": "Dictation"]))
        XCTAssertNil(model.receiveFeedItem(text: "ignored", source: "Dictation", title: nil, date: Date()))
        XCTAssertTrue(model.clips.isEmpty)
        XCTAssertNotNil(model.receiveFeedItem(text: "kept", source: "Agent", title: nil, date: Date()))
        XCTAssertEqual(model.clips.count, 1)
    }

    // MARK: - The `feed` socket verb

    func testFeedAddRecordsAndRepliesWithAnID() {
        let reply = feed(HUDTextFeed.addArgs(text: "remind me to call back", source: "Dictation"))
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let id = try? XCTUnwrap(reply["id"] as? String)
        XCTAssertNotNil(id)
        XCTAssertFalse(id!.isEmpty)
        XCTAssertEqual(model.clips.first?.text, "remind me to call back")
        XCTAssertEqual(model.clips.first?.feedSource, "Dictation")
        XCTAssertEqual(model.clips.first?.id.uuidString, id)
    }

    func testFeedAddDefaultsActionToAdd() {
        // The MacHUD broker always sends `action=add`, but a bare `feed` (no `action=`) should
        // behave the same rather than erroring, matching `settings`'s default sub-verb.
        let reply = feed(["text": "hi", "source": "Agent"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(model.clips.count, 1)
    }

    func testFeedAddWithTitleSetsTheDisplayedTitle() {
        let reply = feed(HUDTextFeed.addArgs(text: "the body", source: "Agent", title: "Reply to James"))
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(model.clips.first?.title, "Reply to James")
        XCTAssertEqual(model.clips.first?.text, "the body")
    }

    func testFeedAddRequiresTextAndSource() {
        XCTAssertEqual(feed(["action": "add", "source": "Dictation"])["ok"] as? Bool, false)
        XCTAssertEqual(feed(["action": "add", "text": "hi"])["ok"] as? Bool, false)
        XCTAssertTrue(model.clips.isEmpty)
    }

    func testFeedRejectsAnUnknownAction() {
        var args = HUDTextFeed.addArgs(text: "hi", source: "Dictation")
        args["action"] = "remove"
        let reply = feed(args)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertTrue(model.clips.isEmpty)
    }

    func testFeedAddOnAnIgnoredSourceRepliesOkWithNoID() throws {
        try model.updateSettings(try model.settings.applying(["ignoredFeedSources": "Dictation"]))
        let reply = feed(HUDTextFeed.addArgs(text: "hi", source: "Dictation"))
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["id"] as? String, "")
        XCTAssertTrue(model.clips.isEmpty)
    }

    func testFeedAddParsesAnExplicitDate() throws {
        let reply = feed(HUDTextFeed.addArgs(text: "hi", source: "Dictation", date: "2026-01-02T03:04:05Z"))
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        XCTAssertEqual(model.clips.first?.date, expected)
    }

    // MARK: - Manifest and describe()

    func testManifestDeclaresTheCapability() {
        XCTAssertTrue(ControlHost.builtinManifest.panel(id: ControlHost.panelID)?.capabilities.contains(HUDTextFeed.capability) == true)
    }

    func testListDescribesAFeedItemWithItsSourceAndAFeedFlag() {
        _ = model.receiveFeedItem(text: "call the vet back", source: "Dictation", title: nil, date: Date())
        var reply: [String: Any] = [:]
        host.performAction("list", args: [:]) { reply = $0 }
        let results = try? XCTUnwrap(reply["results"] as? [[String: Any]])
        let first = results?.first
        XCTAssertEqual(first?["source"] as? String, "Dictation")
        XCTAssertEqual(first?["feed"] as? Bool, true)
    }
}
