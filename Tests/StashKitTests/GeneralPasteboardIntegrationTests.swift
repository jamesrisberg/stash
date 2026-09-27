import AppKit
import XCTest
@testable import StashKit

/// INTEGRATION TEST: the only test that touches the real, system-wide general pasteboard.
///
/// It saves every item and type on the general pasteboard, writes one marked clip, reads it
/// back through a watcher, and restores the saved contents in `tearDown` (even on failure).
/// Opt-in: it runs only with `STASH_INTEGRATION=1 swift test`, so a plain `swift test`
/// never disturbs whatever the user (or another process) has copied.
@MainActor
final class GeneralPasteboardIntegrationTests: XCTestCase {
    private var saved: [NSPasteboardItem] = []

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STASH_INTEGRATION"] == "1",
                          "set STASH_INTEGRATION=1 to run the general-pasteboard integration test")
        let pb = NSPasteboard.general
        saved = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    override func tearDown() async throws {
        guard ProcessInfo.processInfo.environment["STASH_INTEGRATION"] == "1" else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
    }

    func testRoundTripOnGeneralPasteboard() throws {
        let pb = NSPasteboard.general
        let watcher = ClipboardWatcher(pasteboard: pb, frontmostBundleID: { "com.example.test" },
                                       isSecureInputEnabled: { false })
        let text = "stash integration \(UUID().uuidString)"
        pb.clearContents()
        pb.setString(text, forType: .string)
        XCTAssertEqual(watcher.poll()?.payload.text, text)
        ClipReader.write(text: "own write", to: pb)
        XCTAssertNil(watcher.poll(), "Stash's own writes are skipped")
    }
}
