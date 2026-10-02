import Foundation
import HUDKit
@testable import Stash
import XCTest

/// The shipped machud.json is what MacHUD reads without launching Stash; keep it valid.
final class ManifestTests: XCTestCase {
    private var resources: URL { ShippedResources.url }

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
        XCTAssertTrue(panel.capabilities.contains(HUDTextFeed.capability))
        let schema = try XCTUnwrap(panel.settingsSchema)
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appending(path: schema))) as? [String: Any]
        let keys = (settings?["settings"] as? [[String: Any]])?.compactMap { $0["key"] as? String }
        XCTAssertEqual(Set(keys ?? []), ["historyCap", "pollIntervalMs", "ignoreList", "pasteOnEnter", "ignoredFeedSources"])

        // HUDKit's shared schema reader accepts it and validates wire values against it.
        let parsed = try HUDSettingsSchema.decode(Data(contentsOf: resources.appending(path: schema)))
        XCTAssertEqual(parsed.settings.count, 5)
        XCTAssertNoThrow(try parsed.validate(["historyCap": "50", "pollIntervalMs": "300", "pasteOnEnter": "false",
                                              "ignoreList": "a.b,c.d"]))
        XCTAssertThrowsError(try parsed.validate(["historyCap": "lots"]))
    }

    /// Stash serves one widget type next to its hover panel: no dock button of its own.
    func testManifestDeclaresTheClipsWidget() throws {
        let manifest = try HUDManifest.decode(Data(contentsOf: resources.appending(path: HUDManifest.fileName)))
        XCTAssertEqual(manifest.panels.map(\.id), ["history", "clips"])
        XCTAssertEqual(manifest.dockPanels.map(\.id), ["history"], "a widget type is never a dock button")
        XCTAssertEqual(manifest.widgetPanels.map(\.id), ["clips"])
        let clips = try XCTUnwrap(manifest.panel(id: "clips"))
        XCTAssertEqual(clips.kind, .widget)
        let spec = try XCTUnwrap(clips.widget)
        XCTAssertEqual(spec.sizes, [.small, .medium])
        XCTAssertEqual(spec.defaultSize, .small)
        XCTAssertTrue(spec.multiple)
        XCTAssertEqual(spec.settingsSchema, "clips.widget.json")

        // The per-instance schema is its own file, not the app's settings.json.
        let schema = try HUDSettingsSchema.decode(Data(contentsOf: resources.appending(path: "clips.widget.json")))
        XCTAssertEqual(schema.settings.map(\.key), ["pinnedOnly"])
        XCTAssertEqual(schema.field("pinnedOnly")?.default, .bool(false))
        XCTAssertEqual(try schema.validate(["pinnedOnly": "on"]), ["pinnedOnly": .bool(true)])
        XCTAssertThrowsError(try schema.validate(["pinnedOnly": "sometimes"]))
        XCTAssertEqual(HUDSettingsSchema.load(widget: "clips", manifest: manifest, bundleURL: try ShippedResources.bundleLike(for: self))?.settings.count, 1)
    }

    /// `builtinManifest` (used under `swift run`) mirrors the shipped machud.json.
    @MainActor
    func testBuiltinManifestMatchesTheShippedOne() throws {
        let shipped = try HUDManifest.decode(Data(contentsOf: resources.appending(path: HUDManifest.fileName)))
        let builtin = ControlHost.builtinManifest
        XCTAssertEqual(builtin.panels.map(\.id), shipped.panels.map(\.id))
        let a = try JSONSerialization.data(withJSONObject: shipped.panels.map(\.json), options: .sortedKeys)
        let b = try JSONSerialization.data(withJSONObject: builtin.panels.map(\.json), options: .sortedKeys)
        XCTAssertEqual(String(decoding: b, as: UTF8.self), String(decoding: a, as: UTF8.self))
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
