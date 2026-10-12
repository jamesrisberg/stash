import AppKit
import HUDKit
import StashKit
@testable import Stash
import XCTest

/// The `snippets` socket verb (agreed with MacHUD's search bar), keyword expansion through the
/// app's controller, and the system driver's clipboard half. Nothing here posts a key event:
/// the controller gets a fake driver, and only the real driver's pasteboard methods run, on a
/// private pasteboard.
@MainActor
final class SnippetsTests: XCTestCase {
    final class FakeDriver: SnippetInsertionDriver {
        var log: [String] = []
        var changeCount = 0
        func postBackspaces(_ count: Int) { log.append("backspace×\(count)") }
        func postPaste() -> Bool { log.append("paste"); return true }
        func type(_ text: String) -> Bool { log.append("type:\(text)"); return true }
        func saveClipboard() -> SavedClipboard? { log.append("save"); return SavedClipboard(items: []) }
        func writeClipboard(_ text: String) -> Int? { log.append("write:\(text)"); changeCount += 1; return changeCount }
        func clipboardChangeCount() -> Int { changeCount }
        func restoreClipboard(_ saved: SavedClipboard) { log.append("restore") }
        /// Off: scheduled work runs at once. On: it waits for `runNext`/`runAll`.
        var deferred = false
        var pending: [() -> Void] = []
        func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
            if deferred { pending.append(work) } else { work() }
        }
        func runNext() { if !pending.isEmpty { pending.removeFirst()() } }
        func runAll() { while !pending.isEmpty { runNext() } }
    }

    private var pasteboard: NSPasteboard!
    private var root: URL!
    private var model: AppModel!
    private var driver: FakeDriver!
    private var snippets: SnippetsController!
    private var trusted = true
    private var canPaste = true

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("xyz.machud.stash.tests.\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appending(path: "StashSnippetsTests-\(UUID().uuidString)")
        model = AppModel(directory: root, pasteboard: pasteboard)
        driver = FakeDriver()
        snippets = SnippetsController(model: model, driver: driver, alfredFolder: root.appending(path: "no-alfred"))
        snippets.isTrusted = { [unowned self] in self.trusted }
        snippets.canSimulatePaste = { [unowned self] in self.canPaste }
        snippets.schedule = { [unowned self] delay, work in self.driver.after(delay) { MainActor.assumeIsolated { work() } } }
        snippets.placeholders = SnippetPlaceholders(now: { Date(timeIntervalSince1970: 1_791_731_045) },
                                                    clipboard: { "on the clipboard" },
                                                    locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        try snippets.store.upsert(Snippet(id: "sig", name: "Signature", keyword: "sig", text: "Kind regards,\nA. Tester", collection: "Mail"))
        try snippets.store.upsert(Snippet(id: "today", name: "Today", keyword: "tdy", text: "Today is {date}", collection: "Dates"))
        try snippets.store.upsert(Snippet(id: "quote", name: "Quote clipboard", keyword: "qcb", text: "> {clipboard}", collection: "Mail"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    private func call(_ args: [String: String]) -> [String: Any] {
        var reply: [String: Any] = [:]
        snippets.handle(args) { reply = $0 }
        return reply
    }

    /// The CLI's `stash snippets list query=x` arrives as `{_: "list", list: "1", query: "x"}`.
    private func cli(_ words: String...) -> [String: Any] {
        call(HUDSocketClient.parseArguments(words))
    }

    // MARK: - list

    func testListReplyShape() throws {
        let reply = cli("list")
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let rows = try XCTUnwrap(reply["snippets"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["today", "quote", "sig"], "by collection, then name")
        for row in rows { XCTAssertEqual(Set(row.keys), ["id", "name", "keyword", "collection", "preview"]) }
        let sig = try XCTUnwrap(rows.first { $0["id"] as? String == "sig" })
        XCTAssertEqual(sig["name"] as? String, "Signature")
        XCTAssertEqual(sig["keyword"] as? String, "sig")
        XCTAssertEqual(sig["collection"] as? String, "Mail")
        XCTAssertEqual(sig["preview"] as? String, "Kind regards, A. Tester", "one line")
    }

    func testListPreviewExpandsDateButNotTheClipboard() throws {
        let rows = try XCTUnwrap(cli("list", "query=tdy")["snippets"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["preview"] as? String, "Today is Oct 11, 2026")
        let quote = try XCTUnwrap(cli("list", "query=qcb")["snippets"] as? [[String: Any]])
        XCTAssertEqual(quote.first?["preview"] as? String, "> {clipboard}",
                       "a preview never shows what is on the clipboard")
    }

    func testListQueryAndLimit() throws {
        let rows = try XCTUnwrap(call(["action": "list", "query": "MAIL"])["snippets"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["id"] as? String }), ["sig", "quote"])
        let limited = try XCTUnwrap(cli("list", "limit=1")["snippets"] as? [[String: Any]])
        XCTAssertEqual(limited.count, 1)
    }

    // MARK: - insert

    func testInsertPastesTheExpandedText() {
        let reply = cli("insert", "id=today")
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["pasted"] as? Bool, true)
        XCTAssertNil(reply["hint"])
        XCTAssertEqual(driver.log.filter { !$0.hasPrefix("save") && !$0.hasPrefix("restore") },
                       ["write:Today is Oct 11, 2026", "paste"], "no keyword to delete")
        XCTAssertTrue(model.clips.isEmpty, "an inserted snippet is not recorded as a clip")
    }

    func testInsertWithoutAccessibilityCopiesOnly() throws {
        trusted = false
        let reply = cli("insert", "id=sig")
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["pasted"] as? Bool, false)
        XCTAssertEqual(reply["hint"] as? String, "grant Accessibility to Stash to paste; copied only")
        XCTAssertEqual(pasteboard.string(forType: .string), "Kind regards,\nA. Tester")
        XCTAssertTrue(driver.log.isEmpty, "nothing is typed or pasted")
        XCTAssertNil(model.watcher.poll(), "Stash's own copy is not recorded")
    }

    func testInsertWithAPrivatePasteboardCopiesOnly() {
        canPaste = false
        let reply = cli("insert", "id=sig")
        XCTAssertEqual(reply["pasted"] as? Bool, false)
        XCTAssertEqual(reply["hint"] as? String, "private pasteboard in use; copied only")
    }

    func testInsertErrors() {
        XCTAssertEqual(cli("insert")["ok"] as? Bool, false)
        let missing = cli("insert", "id=nope")
        XCTAssertEqual(missing["ok"] as? Bool, false)
        XCTAssertEqual(missing["error"] as? String, "no snippet nope")
    }

    // MARK: - import-alfred

    private func alfredFixture() throws -> URL {
        let folder = root.appending(path: "alfred/snippets")
        let dir = folder.appending(path: "Greetings")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["snippetkeywordprefix": "!"], format: .xml, options: 0)
            .write(to: dir.appending(path: "info.plist"))
        for (uid, keyword, text) in [("A1", "hi", "Hello {cursor}"), ("A2", "bye", "Goodbye")] {
            let body = ["alfredsnippet": ["snippet": text, "uid": uid, "name": "Name \(uid)", "keyword": keyword]]
            try JSONSerialization.data(withJSONObject: body).write(to: dir.appending(path: "x [\(uid)].json"))
        }
        try FileManager.default.createDirectory(at: folder.appending(path: "Empty"), withIntermediateDirectories: true)
        return folder
    }

    func testImportAlfredDryRunReportsCountsOnly() throws {
        let folder = try alfredFixture()
        let reply = cli("import-alfred", "dry-run=1", "path=\(folder.path(percentEncoded: false))")
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["dryRun"] as? Bool, true)
        XCTAssertEqual(reply["snippets"] as? Int, 2)
        XCTAssertEqual(reply["collections"] as? Int, 2)
        XCTAssertEqual(reply["byCollection"] as? [String: Int], ["Greetings": 2, "Empty": 0])
        XCTAssertEqual(reply["added"] as? Int, 2)
        XCTAssertEqual(reply["updated"] as? Int, 0)
        XCTAssertEqual(reply["unchanged"] as? Int, 0)
        XCTAssertEqual(reply["skipped"] as? Int, 0)
        XCTAssertEqual(reply["unknownPlaceholders"] as? [String: Int], ["cursor": 1])
        XCTAssertNil(snippets.store.snippet(id: "A1"), "a dry run changes nothing")
    }

    func testImportAlfredThenReimport() throws {
        let folder = try alfredFixture()
        let first = cli("import-alfred", "path=\(folder.path(percentEncoded: false))")
        XCTAssertEqual(first["dryRun"] as? Bool, false)
        XCTAssertEqual(first["added"] as? Int, 2)
        XCTAssertEqual(snippets.store.snippet(id: "A1")?.keyword, "!hi")
        XCTAssertTrue(snippets.collections.contains("Empty"))
        let again = cli("import-alfred", "path=\(folder.path(percentEncoded: false))")
        XCTAssertEqual(again["unchanged"] as? Int, 2)
        XCTAssertEqual(snippets.store.snippets.count, 5)
    }

    func testImportAlfredWithoutAlfredFails() {
        let reply = cli("import-alfred")
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertNotNil(reply["error"] as? String)
    }

    // MARK: - expansion

    func testExpansionOnOffAndStatus() throws {
        XCTAssertEqual(cli("expansion")["expansion"] as? String, "off", "off by default")
        let on = cli("expansion", "on")
        XCTAssertEqual(on["ok"] as? Bool, true)
        XCTAssertEqual(on["expansion"] as? String, "on")
        XCTAssertTrue(model.settings.snippetExpansion)
        XCTAssertTrue(SettingsStore(directory: root).load().snippetExpansion, "saved to preferences.json")
        XCTAssertEqual(call(["action": "expansion", "state": "off"])["expansion"] as? String, "off")
        XCTAssertFalse(model.settings.snippetExpansion)
        XCTAssertEqual(cli("expansion", "maybe")["ok"] as? Bool, false)
    }

    func testUnknownSubcommand() {
        let reply = cli("frobnicate")
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertTrue((reply["error"] as? String ?? "").contains("list"))
    }

    // MARK: - Keyword expansion through the controller

    private let editor = SnippetExpansionEngine.Context(secureInput: false, frontmostBundleID: "com.example.editor")

    private func type(_ text: String, context: SnippetExpansionEngine.Context? = nil) {
        for c in text { snippets.keyTyped(KeyInput(keyCode: 0, characters: String(c), modifiers: []), context: context ?? editor) }
    }

    func testTypedKeywordsDoNothingWhileExpansionIsOff() {
        type("sig")
        XCTAssertTrue(driver.log.isEmpty)
    }

    func testATypedKeywordIsReplacedByItsExpansion() throws {
        try model.updateSettings(try model.settings.applying(["snippetExpansion": "on"]))
        type("hello tdy")
        XCTAssertEqual(driver.log.first, "backspace×3")
        XCTAssertTrue(driver.log.contains("write:Today is Oct 11, 2026"))
        XCTAssertTrue(driver.log.contains("paste"))
    }

    /// MacHUD's search bar finds snippets by keyword: typing one there must not expand it.
    func testStashsIgnoredAppsStashAndMacHUDNeverExpand() throws {
        try model.updateSettings(try model.settings.applying(["snippetExpansion": "on", "ignoreList": "com.example.vault"]))
        type("sig", context: .init(secureInput: false, frontmostBundleID: "com.example.vault"))
        type("sig", context: .init(secureInput: false, frontmostBundleID: AppModel.bundleID))
        type("sig", context: .init(secureInput: false, frontmostBundleID: SnippetsController.machudBundleID))
        type("sig", context: .init(secureInput: true, frontmostBundleID: "com.example.editor"))
        XCTAssertTrue(driver.log.isEmpty)
    }

    /// `snippets insert` right after an expansion: the clipboard restored is the user's.
    func testAnInsertRightAfterAnExpansionReusesTheSavedClipboard() throws {
        try model.updateSettings(try model.settings.applying(["snippetExpansion": "on"]))
        driver.deferred = true
        type("tdy")
        driver.runNext()                     // the expansion runs; its paste is next
        driver.runNext()                     // paste; restore pending
        _ = cli("insert", "id=sig")
        driver.pending.removeLast()()        // the insert, before the expansion's restore is due
        driver.runAll()
        XCTAssertEqual(driver.log.filter { $0 == "save" }.count, 1)
        XCTAssertEqual(driver.log.filter { $0 == "restore" }.count, 1)
    }

    // MARK: - Mapping a key's target process

    func testTheTargetProcessNamesTheApp() {
        var cache = KeyTargetCache()
        let resolve: (pid_t) -> String? = { $0 == 4242 ? "com.example.editor" : nil }
        XCTAssertEqual(cache.bundleID(pid: getpid(), frontmost: "com.example.other", stashIsKey: false, resolve: resolve),
                       AppModel.bundleID, "Stash's own process")
        XCTAssertEqual(cache.bundleID(pid: 4242, frontmost: "com.example.other", stashIsKey: false, resolve: resolve),
                       "com.example.editor")
        XCTAssertEqual(cache.bundleID(pid: 0, frontmost: "com.example.other", stashIsKey: false, resolve: resolve),
                       "com.example.other", "no target process: the frontmost app")
    }

    /// Stash's hover panel takes keys without Stash being frontmost or, perhaps, the target.
    func testAStashKeyWindowMeansStash() {
        var cache = KeyTargetCache()
        XCTAssertEqual(cache.bundleID(pid: 4242, frontmost: "com.example.editor", stashIsKey: true, resolve: { _ in "com.example.editor" }),
                       AppModel.bundleID)
    }

    /// Only a resolved process is remembered; the frontmost fallback is not, so a process that
    /// resolves later is named correctly.
    func testOnlyResolvedTargetsAreCached() {
        var cache = KeyTargetCache()
        var known: String?
        let resolve: (pid_t) -> String? = { _ in known }
        XCTAssertEqual(cache.bundleID(pid: 4242, frontmost: "com.example.front", stashIsKey: false, resolve: resolve), "com.example.front")
        known = "com.example.panel"
        XCTAssertEqual(cache.bundleID(pid: 4242, frontmost: "com.example.front", stashIsKey: false, resolve: resolve), "com.example.panel")
        known = nil
        XCTAssertEqual(cache.bundleID(pid: 4242, frontmost: "com.example.front", stashIsKey: false, resolve: resolve), "com.example.panel",
                       "a resolved process is remembered")
        cache.forget(pid: 4242)
        XCTAssertEqual(cache.bundleID(pid: 4242, frontmost: "com.example.front", stashIsKey: false, resolve: resolve), "com.example.front")
    }

    // MARK: - The system driver's clipboard half (private pasteboard; no key events)

    func testSystemDriverBorrowsTheClipboardWithoutRecordingIt() throws {
        let system = SystemSnippetDriver(pasteboard: pasteboard, watcher: model.watcher)
        model.watcher.isSecureInputEnabled = { false }
        model.watcher.frontmostBundleID = { "com.example.editor" }
        pasteboard.clearContents()
        pasteboard.setString("the user's own", forType: .string)
        XCTAssertNotNil(model.watcher.poll(), "an ordinary copy is recorded")

        let saved = try XCTUnwrap(system.saveClipboard())
        let written = try XCTUnwrap(system.writeClipboard("snippet text"))
        XCTAssertEqual(system.clipboardChangeCount(), written)
        XCTAssertEqual(pasteboard.string(forType: .string), "snippet text")
        XCTAssertNil(model.watcher.poll(), "the expansion's own paste is not recorded")

        system.restoreClipboard(saved)
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's own")
        XCTAssertNil(model.watcher.poll(), "nor is the restore")
        XCTAssertEqual(model.clips.count, 1)
    }
}
