import AppKit
import XCTest
@testable import StashKit

@MainActor
final class ClipReaderTests: PasteboardTestCase {
    func testPlainText() {
        copyText("hello world")
        let p = ClipReader.read(pasteboard)
        XCTAssertEqual(p?.kind, .text)
        XCTAssertEqual(p?.text, "hello world")
        XCTAssertEqual(p?.size, 11)
    }

    func testWebURLBecomesURLClip() {
        copyText("https://example.com/a?b=1")
        XCTAssertEqual(ClipReader.read(pasteboard)?.kind, .url)
        XCTAssertTrue(ClipReader.isWebURL(" http://x.org "))
        XCTAssertFalse(ClipReader.isWebURL("see https://x.org"))
        XCTAssertFalse(ClipReader.isWebURL("file:///tmp/a"))
        XCTAssertFalse(ClipReader.isWebURL("mailto:a@b.c"))
    }

    func testRichText() throws {
        let attributed = NSAttributedString(string: "Bold move", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        let rtf = try XCTUnwrap(attributed.rtf(from: NSRange(location: 0, length: attributed.length)))
        pasteboard.clearContents()
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString("Bold move", forType: .string)
        let p = try XCTUnwrap(ClipReader.read(pasteboard))
        XCTAssertEqual(p.kind, .richText)
        XCTAssertEqual(p.text, "Bold move")
        XCTAssertEqual(p.blobData, rtf)
        XCTAssertEqual(p.blobExtension, "rtf")
    }

    func testImage() throws {
        pasteboard.clearContents()
        pasteboard.setData(pngData(), forType: .png)
        let p = try XCTUnwrap(ClipReader.read(pasteboard))
        XCTAssertEqual(p.kind, .image)
        XCTAssertEqual(p.imageSize, CGSizeCodable(width: 3, height: 2))
    }

    func testTIFFIsConvertedToPNG() throws {
        let tiff = try XCTUnwrap(NSImage(data: pngData())?.tiffRepresentation)
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        let p = try XCTUnwrap(ClipReader.read(pasteboard))
        XCTAssertEqual(p.kind, .image)
        XCTAssertEqual(p.blobExtension, "png")
        XCTAssertEqual(p.blobData?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testFileURLsWinOverText() throws {
        let a = root.appending(path: "a.txt"), b = root.appending(path: "b.txt")
        try Data("aaa".utf8).write(to: a)
        try Data("bb".utf8).write(to: b)
        pasteboard.clearContents()
        pasteboard.writeObjects([a as NSURL, b as NSURL])
        let p = try XCTUnwrap(ClipReader.read(pasteboard))
        XCTAssertEqual(p.kind, .files)
        XCTAssertEqual(p.fileURLs?.map(\.lastPathComponent), ["a.txt", "b.txt"])
        XCTAssertEqual(p.size, 5)
    }

    func testEmptyPasteboardReadsNothing() {
        pasteboard.clearContents()
        XCTAssertNil(ClipReader.read(pasteboard))
    }

    func testConcealedMarkers() {
        XCTAssertTrue(ClipReader.isConcealed([.string, .init("org.nspasteboard.ConcealedType")]))
        XCTAssertFalse(ClipReader.isConcealed([.string]))
    }

    func testWriteRoundTripsEveryKind() throws {
        let store = ClipStore(directory: root)
        let rtf = try XCTUnwrap(NSAttributedString(string: "rich").rtf(from: NSRange(location: 0, length: 4)))
        let file = root.appending(path: "f.txt")
        try Data("f".utf8).write(to: file)
        let payloads: [ClipPayload] = [
            .text("plain"),
            .text("https://example.com"),
            ClipPayload(kind: .richText, text: "rich", blobData: rtf, blobExtension: "rtf"),
            ClipPayload(kind: .image, blobData: pngData(), blobExtension: "png"),
            ClipPayload(kind: .files, text: file.path, fileURLs: [file]),
        ]
        for payload in payloads {
            let clip = try store.add(payload).clip
            XCTAssertTrue(ClipReader.write(clip, blobURL: store.blobURL(for: clip), to: pasteboard), "\(clip.kind)")
            XCTAssertTrue(pasteboard.types?.contains(ClipReader.stashMarker) ?? false)
            let back = try XCTUnwrap(ClipReader.read(pasteboard), "\(clip.kind)")
            XCTAssertEqual(back.kind, clip.kind)
            XCTAssertEqual(back.contentHash, clip.contentHash, "\(clip.kind)")
        }
    }
}
