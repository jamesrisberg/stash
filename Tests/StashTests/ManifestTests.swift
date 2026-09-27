import Foundation
import HUDKit
import XCTest

/// The shipped machud.json is what MacHUD reads without launching Stash; keep it valid.
final class ManifestTests: XCTestCase {
    private var resources: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Stash/Resources")
    }

    func testManifestDecodes() throws {
        let manifest = try HUDManifest.decode(Data(contentsOf: resources.appending(path: HUDManifest.fileName)))
        XCTAssertEqual(manifest.id, "xyz.machud.stash")
        XCTAssertEqual(manifest.socket, "stash")
        let panel = try XCTUnwrap(manifest.panel(id: "history"))
        XCTAssertEqual(panel.defaultSize, HUDSize(width: 460, height: 560))
        XCTAssertEqual(panel.compactSize, HUDSize(width: 640, height: 104))
        XCTAssertEqual(panel.kind, .hover, "MacHUD shows Stash while the pointer is over its orb")
        XCTAssertEqual(panel.order, 2, "MacHUD dock: Scratch 1, Stash 2")
        for verb in ["show", "hide", "toggle", "frame", "mode", "paste"] { XCTAssertTrue(panel.verbs.contains(verb), verb) }
        let schema = try XCTUnwrap(panel.settingsSchema)
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appending(path: schema))) as? [String: Any]
        let keys = (settings?["settings"] as? [[String: Any]])?.compactMap { $0["key"] as? String }
        XCTAssertEqual(Set(keys ?? []), ["historyCap", "pollIntervalMs", "ignoreList", "pasteOnEnter"])

        // HUDKit's shared schema reader accepts it and validates wire values against it.
        let parsed = try HUDSettingsSchema.decode(Data(contentsOf: resources.appending(path: schema)))
        XCTAssertEqual(parsed.settings.count, 4)
        XCTAssertNoThrow(try parsed.validate(["historyCap": "50", "pollIntervalMs": "300", "pasteOnEnter": "false",
                                              "ignoreList": "a.b,c.d"]))
        XCTAssertThrowsError(try parsed.validate(["historyCap": "lots"]))
    }

    func testInfoPlist() throws {
        let data = try Data(contentsOf: resources.appending(path: "Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "xyz.machud.stash")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Stash")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertNotNil(plist["NSHumanReadableCopyright"])
    }
}
