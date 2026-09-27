import AppKit
import XCTest
@testable import StashKit

@MainActor
final class ClipStoreTests: PasteboardTestCase {
    private func date(_ n: Int) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(n)) }

    func testAddsNewestFirstAndPersists() throws {
        let store = ClipStore(directory: root)
        try store.add(.text("first"), source: "com.a", date: date(1))
        try store.add(.text("second"), date: date(2))
        XCTAssertEqual(store.clips.map(\.text), ["second", "first"])

        let reloaded = ClipStore(directory: root)
        try reloaded.load()
        XCTAssertEqual(reloaded.clips.map(\.text), ["second", "first"])
        XCTAssertEqual(reloaded.clips.last?.sourceBundleID, "com.a")
        XCTAssertEqual(reloaded.clips.first?.date, date(2))
    }

    func testDedupesConsecutiveIdenticalClips() throws {
        let store = ClipStore(directory: root)
        XCTAssertTrue(try store.add(.text("same")).isNew)
        XCTAssertFalse(try store.add(.text("same")).isNew)
        try store.add(.text("other"))
        XCTAssertTrue(try store.add(.text("same")).isNew, "only consecutive copies are merged")
        XCTAssertEqual(store.clips.map(\.text), ["same", "other", "same"])
    }

    func testCapDropsOldestUnpinnedAndTheirBlobs() throws {
        let store = ClipStore(directory: root, cap: 3)
        let image = try store.add(ClipPayload(kind: .image, blobData: pngData(), blobExtension: "png")).clip
        let imageBlob = try XCTUnwrap(store.blobURL(for: image))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageBlob.path))
        let pinned = try store.add(.text("keep me")).clip
        store.setPinned(true, id: pinned.id)
        for i in 0..<3 { try store.add(.text("t\(i)")) }
        XCTAssertEqual(store.clips.map(\.text), ["t2", "t1", "t0", "keep me"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageBlob.path), "dropped clip's blob is deleted")

        store.cap = 1
        XCTAssertEqual(store.clips.map(\.text), ["t2", "keep me"], "pinned clips are exempt")
        store.setPinned(false, id: pinned.id)
        XCTAssertEqual(store.clips.map(\.text), ["t2"], "unpinning re-applies the cap")
    }

    func testRemovePinPromoteClear() throws {
        let store = ClipStore(directory: root)
        var changes = 0
        store.onChange = { changes += 1 }
        let a = try store.add(.text("a"), date: date(1)).clip
        let b = try store.add(.text("b"), date: date(2)).clip
        let c = try store.add(.text("c"), date: date(3)).clip
        store.togglePin(id: a.id)
        XCTAssertEqual(store.pinned.map(\.text), ["a"])
        XCTAssertEqual(store.unpinned.map(\.text), ["c", "b"])
        store.promote(id: b.id, date: date(4))
        XCTAssertEqual(store.clips.map(\.text), ["b", "c", "a"])
        store.remove(id: c.id)
        XCTAssertEqual(store.clips.map(\.text), ["b", "a"])
        store.clear()
        XCTAssertEqual(store.clips.map(\.text), ["a"], "clear keeps pinned clips")
        store.clear(keepPinned: false)
        XCTAssertTrue(store.clips.isEmpty)
        XCTAssertEqual(changes, 8)
    }

    func testSearchMatchesAllTermsCaseAndDiacriticInsensitive() throws {
        let store = ClipStore(directory: root)
        try store.add(.text("Café au lait recipe"))
        try store.add(.text("https://example.com/cafe"))
        try store.add(ClipPayload(kind: .image, blobData: pngData(), blobExtension: "png"))
        try store.add(ClipPayload(kind: .files, text: "/tmp/Cafe Menu.pdf", fileURLs: [URL(filePath: "/tmp/Cafe Menu.pdf")]))
        try store.add(.text("unrelated"))
        XCTAssertEqual(store.search("CAFE").count, 3)
        XCTAssertEqual(store.search("cafe recipe").map(\.text), ["Café au lait recipe"])
        XCTAssertEqual(store.search("menu").first?.kind, .files)
        XCTAssertEqual(store.search("  ").count, 5)
        XCTAssertTrue(store.search("zzz").isEmpty)
    }

    func testCorruptHistoryThrowsAndOrphanBlobsAreRemoved() throws {
        let store = ClipStore(directory: root)
        try store.add(ClipPayload(kind: .image, blobData: pngData(), blobExtension: "png"))
        let orphan = store.blobsURL.appending(path: "orphan.png")
        try Data([1]).write(to: orphan)
        let reloaded = ClipStore(directory: root)
        try reloaded.load()
        XCTAssertEqual(reloaded.clips.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))

        try Data("{nope".utf8).write(to: store.indexURL)
        XCTAssertThrowsError(try ClipStore(directory: root).load())
    }

    func testTitles() throws {
        let store = ClipStore(directory: root)
        XCTAssertEqual(try store.add(.text("  line one\nline two")).clip.title, "line one")
        XCTAssertEqual(try store.add(ClipPayload(kind: .image, blobData: pngData(width: 4, height: 5), blobExtension: "png",
                                                 imageSize: CGSizeCodable(width: 4, height: 5))).clip.title, "Image 4×5")
        let urls = [URL(filePath: "/tmp/a.txt"), URL(filePath: "/tmp/b.txt")]
        XCTAssertEqual(try store.add(ClipPayload(kind: .files, fileURLs: urls)).clip.title, "2 files")
    }
}
