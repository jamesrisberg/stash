import AppKit
import XCTest
@testable import StashKit

/// Every test gets a private, uniquely named pasteboard (never `.general`) and a temp
/// directory for the store.
@MainActor
class PasteboardTestCase: XCTestCase {
    var pasteboard: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("xyz.machud.stash.tests.\(UUID().uuidString)"))
        XCTAssertNotEqual(pasteboard.name, NSPasteboard.general.name)
        root = FileManager.default.temporaryDirectory.appending(path: "StashTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    func copyText(_ text: String, extraTypes: [NSPasteboard.PasteboardType] = []) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        for type in extraTypes {
            pasteboard.addTypes([type], owner: nil)
            pasteboard.setData(Data(), forType: type)
        }
    }

    /// A 3x2 red PNG.
    func pngData(width: Int = 3, height: Int = 2) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<width { for y in 0..<height { rep.setColor(.red, atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }

    /// A clock tests advance by hand.
    final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func advance(_ s: TimeInterval) { now += s }
    }
}
