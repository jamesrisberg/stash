import CoreGraphics
import Foundation
import HUDKit
@testable import Stash
import XCTest

/// Dismiss hides, summon restores: the frames the panel comes back to.
final class PanelFrameStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "stash-frames-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripPerMode() {
        let full = CGRect(x: 100.5, y: 200, width: 460, height: 560)
        let compact = CGRect(x: 300, y: 800, width: 640, height: 104)
        XCTAssertNil(PanelFrameStore(directory: directory).frame(for: .full))
        PanelFrameStore(directory: directory).save(full, for: .full)
        PanelFrameStore(directory: directory).save(compact, for: .compact)
        // A new store (a relaunch) reads the same frames back.
        let reread = PanelFrameStore(directory: directory)
        XCTAssertEqual(reread.frame(for: .full), full)
        XCTAssertEqual(reread.frame(for: .compact), compact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reread.fileURL.path(percentEncoded: false)))
    }

    func testParkedAndDegenerateFramesAreNotKept() {
        let store = PanelFrameStore(directory: directory)
        store.save(CGRect(x: -440, y: 0, width: 460, height: 560), for: .parked)
        store.save(CGRect(x: 0, y: 0, width: 0, height: 0), for: .full)
        XCTAssertNil(store.frame(for: .parked))
        XCTAssertNil(store.frame(for: .full))
    }

    @MainActor
    func testBuiltinManifestIsHoverLikeTheBundledOne() throws {
        XCTAssertEqual(ControlHost.builtinManifest.panel(id: "history")?.kind, .hover)
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/Stash/Resources/machud.json")
        XCTAssertEqual(try HUDManifest.decode(Data(contentsOf: url)), ControlHost.builtinManifest)
    }
}
