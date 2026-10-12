import Foundation
import XCTest
@testable import StashKit

/// `snippets.json`: snippets grouped into collections, written atomically next to the history.
final class SnippetStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "StashSnippetTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAMissingFileLoadsEmpty() throws {
        let store = SnippetStore(directory: root)
        try store.load()
        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertTrue(store.collections.isEmpty)
        XCTAssertEqual(store.fileURL.lastPathComponent, "snippets.json")
    }

    func testRoundTrip() throws {
        let store = SnippetStore(directory: root)
        let sig = Snippet(name: "Signature", keyword: "sig", text: "Kind regards,\nA. Tester", collection: "Mail")
        let addr = Snippet(name: "Address", keyword: "addr", text: "1 Example Way", collection: "Mail", autoExpand: false)
        try store.upsert(sig)
        try store.upsert(addr)
        try store.addCollection("Empty")

        let reloaded = SnippetStore(directory: root)
        try reloaded.load()
        XCTAssertEqual(reloaded.snippets, [sig, addr])
        XCTAssertEqual(Set(reloaded.collections), ["Mail", "Empty"], "an empty collection survives a reload")
        XCTAssertEqual(reloaded.snippet(id: addr.id)?.autoExpand, false)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
        let first = (json?["snippets"] as? [[String: Any]])?.first
        XCTAssertEqual(Set(first?.keys.map { $0 } ?? []), ["id", "name", "keyword", "text", "collection", "autoExpand"])
    }

    func testUpsertReplacesBySameIDAndReportsNew() throws {
        let store = SnippetStore(directory: root)
        var s = Snippet(id: "one", name: "A", keyword: "a1", text: "x", collection: "C")
        XCTAssertTrue(try store.upsert(s))
        s.text = "y"
        XCTAssertFalse(try store.upsert(s))
        XCTAssertEqual(store.snippets.count, 1)
        XCTAssertEqual(store.snippet(id: "one")?.text, "y")
    }

    func testRemoveAndCollections() throws {
        let store = SnippetStore(directory: root)
        try store.upsert(Snippet(id: "a", name: "A", keyword: "ka", text: "x", collection: "Work"))
        try store.upsert(Snippet(id: "b", name: "B", keyword: "kb", text: "y", collection: "Home"))
        XCTAssertEqual(store.sortedCollections, ["Home", "Work"])
        try store.remove(id: "a")
        XCTAssertNil(store.snippet(id: "a"))
        XCTAssertEqual(store.sortedCollections, ["Home", "Work"], "a collection stays when its last snippet goes")
        XCTAssertThrowsError(try store.removeCollection("Home"), "a collection with snippets cannot be removed")
        try store.removeCollection("Work")
        XCTAssertEqual(store.sortedCollections, ["Home"])
    }

    func testOnChangeFiresOnEveryWrite() throws {
        let store = SnippetStore(directory: root)
        var changes = 0
        store.onChange = { changes += 1 }
        try store.upsert(Snippet(id: "a", name: "A", keyword: "ka", text: "x", collection: "C"))
        try store.remove(id: "a")
        try store.addCollection("D")
        XCTAssertEqual(changes, 3)
    }

    func testAnUnreadableFileThrowsAndIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "snippets.json")
        try Data("not json".utf8).write(to: url)
        let store = SnippetStore(directory: root)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
    }
}
