import XCTest
@testable import StashKit

final class SettingsTests: XCTestCase {
    func testDefaultsIncludePasswordManagers() {
        let s = StashSettings()
        XCTAssertEqual(s.historyCap, 200)
        XCTAssertEqual(s.pollIntervalMs, 250)
        XCTAssertEqual(s.pollInterval, 0.25)
        XCTAssertTrue(s.pasteOnEnter)
        XCTAssertTrue(s.ignoreList.contains("com.1password.1password"))
        XCTAssertTrue(s.ignoreList.contains("com.bitwarden.desktop"))
        XCTAssertEqual(s.ignoredFeedSources, [], "every text-feed source shows by default")
    }

    func testApplyingValidatesEverythingFirst() throws {
        let s = StashSettings()
        let t = try s.applying(["historyCap": "50", "pollIntervalMs": "500", "ignoreList": "a.b, c.d ,", "pasteOnEnter": "off",
                                "ignoredFeedSources": "Dictation, Agent ,"])
        XCTAssertEqual(t.historyCap, 50)
        XCTAssertEqual(t.pollInterval, 0.5)
        XCTAssertEqual(t.ignoreList, ["a.b", "c.d"])
        XCTAssertFalse(t.pasteOnEnter)
        XCTAssertEqual(t.ignoredFeedSources, ["Dictation", "Agent"])
        XCTAssertEqual(t.json["ignoreList"] as? String, "a.b,c.d")
        XCTAssertEqual(t.json["ignoredFeedSources"] as? String, "Dictation,Agent")
        XCTAssertThrowsError(try s.applying(["historyCap": "3"]))
        XCTAssertThrowsError(try s.applying(["pollIntervalMs": "0.25"]))
        XCTAssertThrowsError(try s.applying(["pasteOnEnter": "maybe"]))
        XCTAssertThrowsError(try s.applying(["color": "red"]))
    }

    func testStoreRoundTripAndPartialFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "StashSettings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        XCTAssertEqual(store.load(), StashSettings())
        var s = StashSettings()
        s.historyCap = 42
        try store.save(s)
        XCTAssertEqual(store.load(), s)
        try Data(#"{"pasteOnEnter": false}"#.utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load().historyCap, 200, "missing keys take defaults")
        XCTAssertFalse(store.load().pasteOnEnter)
    }

    func testOneUndecodableValueKeepsTheOtherSavedSettings() throws {
        let json = #"{"historyCap": "lots", "pasteOnEnter": false, "ignoreList": ["com.example.a"]}"#
        let s = try JSONDecoder().decode(StashSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.historyCap, StashSettings().historyCap, "the bad value takes its default")
        XCTAssertEqual(s.pasteOnEnter, false)
        XCTAssertEqual(s.ignoreList, ["com.example.a"])
    }
}

final class EventThrottleTests: XCTestCase {
    func testLeadingFireThenOneTrailing() {
        var t = EventThrottle(interval: 1)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(t.signal(now: t0), .fire)
        XCTAssertEqual(t.signal(now: t0 + 0.25), .schedule(after: 0.75))
        XCTAssertEqual(t.signal(now: t0 + 0.5), .coalesced)
        t.firePending(now: t0 + 1)
        XCTAssertEqual(t.signal(now: t0 + 1.2), .schedule(after: 0.8))
        t.firePending(now: t0 + 2)
        XCTAssertEqual(t.signal(now: t0 + 3.5), .fire)
    }
}
