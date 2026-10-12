import Foundation
import XCTest
@testable import StashKit

/// The insert sequence against a fake driver: delete the keyword, borrow the clipboard,
/// paste, give the clipboard back; type the text when pasting is not possible.
final class SnippetInsertionTests: XCTestCase {
    /// Records every step; `after` work waits until the test runs it.
    final class FakeDriver: SnippetInsertionDriver {
        var log: [String] = []
        var clipboard: [[PasteboardEntry]] = [[PasteboardEntry(type: "public.utf8-plain-text", data: Data("mine".utf8))]]
        var changeCount = 10
        var canSave = true
        var pasteWorks = true
        var pending: [(delay: TimeInterval, work: () -> Void)] = []

        func postBackspaces(_ count: Int) { log.append("backspace×\(count)") }
        func postPaste() -> Bool { log.append("paste"); return pasteWorks }
        func type(_ text: String) -> Bool { log.append("type:\(text)"); return true }
        func saveClipboard() -> SavedClipboard? {
            log.append("save")
            return canSave ? SavedClipboard(items: clipboard) : nil
        }
        func writeClipboard(_ text: String) -> Int? {
            log.append("write:\(text)")
            clipboard = [[PasteboardEntry(type: "public.utf8-plain-text", data: Data(text.utf8))]]
            changeCount += 1
            return changeCount
        }
        func clipboardChangeCount() -> Int { changeCount }
        func restoreClipboard(_ saved: SavedClipboard) {
            log.append("restore")
            clipboard = saved.items
            changeCount += 1
        }
        func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
            log.append("wait \(seconds)")
            pending.append((seconds, work))
        }

        /// Runs scheduled work in order, including work it schedules.
        func runAll() {
            while !pending.isEmpty { pending.removeFirst().work() }
        }

        var clipboardText: String? { clipboard.first?.first.map { String(decoding: $0.data, as: UTF8.self) } }
    }

    private var driver: FakeDriver!
    private var inserter: SnippetInserter!

    override func setUp() {
        driver = FakeDriver()
        inserter = SnippetInserter(driver: driver)
    }

    @discardableResult
    private func run(_ text: String, delete: Int, canPaste: Bool = true, restoreDelay: TimeInterval = 0.3)
        -> SnippetInserter.Method {
        inserter.run(text: text, deleteCount: delete, canPaste: canPaste, restoreDelay: restoreDelay)
    }

    func testPastesThenRestoresTheClipboard() {
        XCTAssertEqual(run("Kind regards", delete: 3), .paste)
        driver.runAll()
        XCTAssertEqual(driver.log, ["backspace×3", "save", "write:Kind regards",
                                    "wait \(SnippetInserter.keySettle)", "paste", "wait 0.3", "restore"])
        XCTAssertEqual(driver.clipboardText, "mine", "the user's clipboard is back")
    }

    func testTheClipboardIsNotRestoredOverANewerCopy() {
        run("Kind regards", delete: 3)
        driver.pending.removeFirst().work()   // paste
        driver.changeCount += 1               // the user copies something before the restore
        driver.clipboard = [[PasteboardEntry(type: "public.utf8-plain-text", data: Data("newer".utf8))]]
        driver.runAll()
        XCTAssertFalse(driver.log.contains("restore"))
        XCTAssertEqual(driver.clipboardText, "newer")
    }

    func testNoKeywordMeansNoBackspaces() {
        run("text", delete: 0)
        driver.runAll()
        XCTAssertFalse(driver.log.contains { $0.hasPrefix("backspace") })
        XCTAssertTrue(driver.log.contains("paste"))
    }

    func testTypesWhenPastingIsNotPossible() {
        XCTAssertEqual(run("Kind regards", delete: 3, canPaste: false), .type)
        driver.runAll()
        XCTAssertEqual(driver.log, ["backspace×3", "wait \(SnippetInserter.keySettle)", "type:Kind regards"])
        XCTAssertEqual(driver.clipboardText, "mine", "the clipboard is never touched")
    }

    func testTypesWhenTheClipboardCannotBeSavedSafely() {
        driver.canSave = false
        XCTAssertEqual(run("Kind regards", delete: 3), .type)
        driver.runAll()
        XCTAssertEqual(driver.log, ["backspace×3", "save", "wait \(SnippetInserter.keySettle)", "type:Kind regards"])
    }

    func testAFailedPasteRestoresAtOnceAndTypesInstead() {
        driver.pasteWorks = false
        run("Kind regards", delete: 3)
        driver.runAll()
        XCTAssertEqual(driver.log, ["backspace×3", "save", "write:Kind regards",
                                    "wait \(SnippetInserter.keySettle)", "paste", "restore", "type:Kind regards"])
        XCTAssertEqual(driver.clipboardText, "mine")
    }

    func testRestoreDelayIsLongerForElectronApps() {
        XCTAssertEqual(SnippetInserter.restoreDelay(electron: false), 0.3)
        XCTAssertEqual(SnippetInserter.restoreDelay(electron: true), 3.0)
    }

    // MARK: - Back to back

    /// A second snippet before the first one's restore: the clipboard saved for the first (the
    /// user's) is reused, not the first snippet's text, and only the last restore runs.
    func testBackToBackInsertsGiveBackTheUsersClipboard() {
        run("first", delete: 3)
        driver.pending.removeFirst().work()          // first paste; its restore is now pending
        run("second", delete: 3)
        driver.runAll()
        XCTAssertEqual(driver.log.filter { $0 == "save" }.count, 1, "the user's clipboard is saved once")
        XCTAssertEqual(driver.log.filter { $0 == "restore" }.count, 1, "the first restore was replaced")
        XCTAssertEqual(driver.clipboardText, "mine")
    }

    func testBackToBackRestoresRunInEitherOrderAndStillEndWithTheUsersClipboard() {
        run("first", delete: 3, restoreDelay: 3.0)
        driver.pending.removeFirst().work()          // first paste, 3 s restore pending
        run("second", delete: 3, restoreDelay: 0.3)
        driver.pending.removeFirst().work()          // the first's stale restore runs late: nothing
        XCTAssertFalse(driver.log.contains("restore"))
        driver.runAll()
        XCTAssertEqual(driver.clipboardText, "mine")
    }

    func testAUserCopyBetweenInsertsIsWhatComesBack() {
        run("first", delete: 3)
        driver.pending.removeFirst().work()          // first paste; restore pending
        driver.changeCount += 1                      // the user copies
        driver.clipboard = [[PasteboardEntry(type: "public.utf8-plain-text", data: Data("newer".utf8))]]
        run("second", delete: 3)
        driver.runAll()
        XCTAssertEqual(driver.clipboardText, "newer")
    }

    func testAfterARestoreTheNextInsertSavesAfresh() {
        run("first", delete: 3)
        driver.runAll()
        driver.clipboard = [[PasteboardEntry(type: "public.utf8-plain-text", data: Data("later".utf8))]]
        driver.changeCount += 1
        run("second", delete: 3)
        driver.runAll()
        XCTAssertEqual(driver.log.filter { $0 == "save" }.count, 2)
        XCTAssertEqual(driver.clipboardText, "later")
    }
}
