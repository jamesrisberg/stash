import Foundation
import XCTest
@testable import StashKit

/// Import from Alfred's snippet folders, built here as synthetic fixtures in Alfred's format:
/// `<collection>/<name> [<uid>].json` holding `{"alfredsnippet": {snippet, uid, name, keyword,
/// dontautoexpand?}}`, plus each collection's `info.plist` with `snippetkeywordprefix` and
/// `snippetkeywordsuffix`.
final class AlfredImportTests: XCTestCase {
    private var root: URL!
    private var folder: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "StashAlfredTests-\(UUID().uuidString)")
        folder = root.appending(path: "Alfred.alfredpreferences/snippets")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    private func collection(_ name: String, prefix: String? = nil, suffix: String? = nil) throws -> URL {
        let dir = folder.appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var info: [String: Any] = [:]
        if let prefix { info["snippetkeywordprefix"] = prefix }
        if let suffix { info["snippetkeywordsuffix"] = suffix }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: dir.appending(path: "info.plist"))
        return dir
    }

    private func snippet(in dir: URL, uid: String, name: String, keyword: String, text: String, dontAutoExpand: Bool? = nil) throws {
        var body: [String: Any] = ["snippet": text, "uid": uid, "name": name, "keyword": keyword]
        if let dontAutoExpand { body["dontautoexpand"] = dontAutoExpand }
        let data = try JSONSerialization.data(withJSONObject: ["alfredsnippet": body], options: [.prettyPrinted])
        try data.write(to: dir.appending(path: "\(name) [\(uid)].json"))
    }

    private func standardFixture() throws {
        let mail = try collection("Mail", prefix: ";", suffix: "")
        try snippet(in: mail, uid: "U1", name: "Signature", keyword: "sig", text: "Sent {date} at {time}")
        try snippet(in: mail, uid: "U2", name: "Address", keyword: "addr", text: "1 Example Way", dontAutoExpand: true)
        try Data("notes".utf8).write(to: mail.appending(path: "notes.txt"))
        let prompts = try collection("Prompts", suffix: "!")
        try snippet(in: prompts, uid: "U3", name: "Review", keyword: "rev",
                    text: "Review {clipboard} {cursor} then {snippet:sig}. JSON stays: {\"a\": 1}")
        try Data("{ not json".utf8).write(to: prompts.appending(path: "Broken [U9].json"))
        _ = try collection("Empty")
    }

    // MARK: - Reading

    func testReadsCollectionsKeywordsAndFlags() throws {
        try standardFixture()
        let result = try AlfredSnippetImporter(folder: folder).read()
        XCTAssertEqual(result.collections, ["Empty", "Mail", "Prompts"], "every folder is a collection, empty ones too")
        XCTAssertEqual(result.countsByCollection, ["Empty": 0, "Mail": 2, "Prompts": 1])
        XCTAssertEqual(result.snippets.count, 3)
        XCTAssertEqual(result.skippedFiles, 1, "the unreadable .json is skipped, the .txt is not a snippet")

        let byID = Dictionary(uniqueKeysWithValues: result.snippets.map { ($0.id, $0) })
        XCTAssertEqual(byID["U1"]?.keyword, ";sig", "the collection's prefix is applied")
        XCTAssertEqual(byID["U1"]?.name, "Signature")
        XCTAssertEqual(byID["U1"]?.collection, "Mail")
        XCTAssertEqual(byID["U1"]?.text, "Sent {date} at {time}", "placeholders are kept for expansion time")
        XCTAssertEqual(byID["U1"]?.autoExpand, true)
        XCTAssertEqual(byID["U2"]?.autoExpand, false, "dontautoexpand turns auto-expansion off")
        XCTAssertEqual(byID["U3"]?.keyword, "rev!", "the collection's suffix is applied")
    }

    func testReportsUnknownPlaceholdersOnly() throws {
        try standardFixture()
        let result = try AlfredSnippetImporter(folder: folder).read()
        XCTAssertEqual(result.unknownPlaceholders, ["cursor": 1, "snippet": 1],
                       "by name only; date, time and clipboard are supported; JSON braces are not placeholders")
    }

    func testAMissingFolderThrows() {
        XCTAssertThrowsError(try AlfredSnippetImporter(folder: root.appending(path: "nope")).read())
    }

    // MARK: - Merging into the store

    func testImportAddsThenReimportUpdatesByUIDWithoutDuplicating() throws {
        try standardFixture()
        let store = SnippetStore(directory: root.appending(path: "stash"))
        let first = try store.merge(try AlfredSnippetImporter(folder: folder).read())
        XCTAssertEqual(first, SnippetImportSummary(added: 3, updated: 0, unchanged: 0))
        XCTAssertEqual(store.snippets.count, 3)
        XCTAssertEqual(store.sortedCollections, ["Empty", "Mail", "Prompts"])

        let again = try store.merge(try AlfredSnippetImporter(folder: folder).read())
        XCTAssertEqual(again, SnippetImportSummary(added: 0, updated: 0, unchanged: 3))

        try snippet(in: folder.appending(path: "Mail"), uid: "U1", name: "Signature", keyword: "sig", text: "Changed")
        let changed = try store.merge(try AlfredSnippetImporter(folder: folder).read())
        XCTAssertEqual(changed, SnippetImportSummary(added: 0, updated: 1, unchanged: 2))
        XCTAssertEqual(store.snippets.count, 3)
        XCTAssertEqual(store.snippet(id: "U1")?.text, "Changed")
    }

    func testImportKeepsSnippetsMadeInStash() throws {
        try standardFixture()
        let store = SnippetStore(directory: root.appending(path: "stash"))
        try store.upsert(Snippet(id: "mine", name: "Mine", keyword: "mm", text: "x", collection: "Mail"))
        _ = try store.merge(try AlfredSnippetImporter(folder: folder).read())
        XCTAssertNotNil(store.snippet(id: "mine"))
        XCTAssertEqual(store.snippets.count, 4)
    }

    func testDryRunCountsButWritesNothing() throws {
        try standardFixture()
        let store = SnippetStore(directory: root.appending(path: "stash"))
        let summary = try store.merge(try AlfredSnippetImporter(folder: folder).read(), dryRun: true)
        XCTAssertEqual(summary, SnippetImportSummary(added: 3, updated: 0, unchanged: 0))
        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path(percentEncoded: false)))
    }

    // MARK: - Where Alfred keeps its preferences

    func testDefaultFolderFollowsAlfredsSyncedPreferences() throws {
        let home = root.appending(path: "home")
        let support = home.appending(path: "Library/Application Support/Alfred")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        XCTAssertEqual(AlfredSnippetImporter.defaultFolder(home: home).path(percentEncoded: false),
                       support.appending(path: "Alfred.alfredpreferences/snippets").path(percentEncoded: false))

        let synced = root.appending(path: "Sync/Alfred.alfredpreferences")
        try FileManager.default.createDirectory(at: synced, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["current": synced.path(percentEncoded: false)])
            .write(to: support.appending(path: "prefs.json"))
        XCTAssertEqual(AlfredSnippetImporter.defaultFolder(home: home).standardizedFileURL.path(percentEncoded: false),
                       synced.appending(path: "snippets").standardizedFileURL.path(percentEncoded: false))
    }
}
