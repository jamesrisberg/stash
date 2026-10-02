import Foundation
import XCTest

/// The app's bundle files as shipped (`Sources/Stash/Resources`).
enum ShippedResources {
    static var url: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Stash/Resources")
    }

    /// A directory laid out like an app bundle (`Contents/Resources` is the shipped folder), for
    /// code that reads a bundle's resources (`HUDWidgetHost`, `HUDSettingsSchema.load(widget:)`).
    static func bundleLike(for test: XCTestCase) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "StashBundleLike-\(UUID().uuidString)")
        let contents = root.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: contents.appending(path: "Resources"), withDestinationURL: url)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
