import AppKit
import HUDKit
import StashKit
@testable import Stash
import XCTest

/// The `clips` desktop widget: registered on a HUDWidgetHost, driven through the `widget` verb
/// (no windows are created), reading the app model.
@MainActor
final class ClipsWidgetTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var root: URL!
    private var model: AppModel!
    private var widgets: HUDWidgetHost!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("xyz.machud.stash.tests.\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appending(path: "StashWidgetTests-\(UUID().uuidString)")
        model = AppModel(directory: root, pasteboard: pasteboard)
        widgets = ClipsWidget.makeHost(model: model, manifest: ControlHost.builtinManifest,
                                       bundleURL: try ShippedResources.bundleLike(for: self))
        widgets.presentsWindows = false
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    private func externalCopy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        XCTAssertNotNil(model.watcher.poll())
    }

    func testRegistersTheClipsTypeOnly() {
        XCTAssertEqual(widgets.types, ["clips"])
        XCTAssertEqual(widgets.spec(for: "clips")?.sizes, [.small, .medium])
    }

    func testInstanceLifecycleOverTheWidgetVerb() throws {
        let created = widgets.handle(["action": "create", "instance": "a", "type": "clips", "size": "medium",
                                      "frame": "40,40,356,170", "settings": #"{"pinnedOnly":true}"#])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let instance = try XCTUnwrap(created["instance"] as? [String: Any])
        XCTAssertEqual((instance["settings"] as? [String: Any])?["pinnedOnly"] as? Bool, true)

        // Several instances of the type, each with its own settings.
        let second = widgets.handle(["action": "create", "instance": "b", "type": "clips", "frame": "400,40,170,170"])
        XCTAssertEqual(second["ok"] as? Bool, true, "\(second)")
        XCTAssertEqual(widgets.instances.map(\.id), ["a", "b"])
        XCTAssertEqual(widgets.context(for: "a")?["pinnedOnly"], .bool(true))
        XCTAssertEqual(widgets.context(for: "b")?["pinnedOnly"], .bool(false), "the schema default")

        // A size the type does not declare, and a bad setting, change nothing.
        XCTAssertEqual(widgets.handle(["action": "update", "instance": "b", "size": "large"])["ok"] as? Bool, false)
        XCTAssertEqual(widgets.handle(["action": "update", "instance": "b", "settings": #"{"pinnedOnly":"maybe"}"#])["ok"] as? Bool, false)
        XCTAssertEqual(widgets.instance("b")?.size, .small)

        XCTAssertEqual(widgets.handle(["action": "remove", "instance": "a"])["removed"] as? String, "a")
        XCTAssertEqual(widgets.instances.map(\.id), ["b"])
    }

    func testSnapshotsBothSizes() throws {
        externalCopy("hello widget")
        for size in [HUDWidgetSize.small, .medium] {
            let url = root.appending(path: "clips-\(size.rawValue).png")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try widgets.writeSnapshot(type: "clips", size: size, to: url)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
            XCTAssertEqual(CGFloat(rep.pixelsWide), size.points().width * 2)
        }
        XCTAssertThrowsError(try widgets.writeSnapshot(type: "clips", size: .large, to: root.appending(path: "x.png")))
    }

    // MARK: - Content

    func testRowCountPerSize() {
        XCTAssertEqual(ClipsWidget.rowCount(for: .small), 1)
        XCTAssertEqual(ClipsWidget.rowCount(for: .medium), 3)
    }

    func testContentFollowsHistoryAndThePinnedOnlySetting() {
        externalCopy("one"); externalCopy("two"); externalCopy("three"); externalCopy("four")
        model.togglePin(model.clips[2])   // "two"
        XCTAssertEqual(ClipsWidget.clips(in: model, size: .small, pinnedOnly: false).map(\.text), ["four"])
        XCTAssertEqual(ClipsWidget.clips(in: model, size: .medium, pinnedOnly: false).map(\.text), ["four", "three", "two"])
        XCTAssertEqual(ClipsWidget.clips(in: model, size: .medium, pinnedOnly: true).map(\.text), ["two"])
    }

    func testEmptyMessageDependsOnPinnedOnly() {
        XCTAssertEqual(ClipsWidget.emptyMessage(pinnedOnly: false), "Nothing copied yet")
        XCTAssertEqual(ClipsWidget.emptyMessage(pinnedOnly: true), "No pinned clips")
    }

    /// A click uses the app's copy action: the clip lands on the pasteboard without a new
    /// clip, reorder or paste.
    func testTapCopiesThroughTheExistingClickAction() {
        externalCopy("alpha"); externalCopy("beta")
        let alpha = model.clips[1]
        XCTAssertTrue(ClipsWidget.copy(alpha, in: model))
        XCTAssertEqual(pasteboard.string(forType: .string), "alpha")
        XCTAssertNil(model.watcher.poll())
        XCTAssertEqual(model.clips.map(\.text), ["beta", "alpha"])
        XCTAssertEqual(model.copiedID, alpha.id)
    }
}
