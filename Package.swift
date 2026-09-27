// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Stash",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StashKit", targets: ["StashKit"]),
        .executable(name: "Stash", targets: ["Stash"]),
        // Installed as `stash`; a distinct product name because Stash and stash would collide
        // on a case-insensitive volume.
        .executable(name: "StashCLI", targets: ["StashCLI"]),
    ],
    dependencies: [
        .package(path: "../hudkit"),
        // FileKit: thumbnails, file actions and Sift's targets for file-type clips.
        .package(path: "../sift"),
    ],
    targets: [
        // Clipboard core: watcher, clip model, persistent store, settings, search. No UI.
        .target(
            name: "StashKit",
            path: "Sources/StashKit"
        ),
        .executableTarget(
            name: "Stash",
            dependencies: [
                "StashKit",
                .product(name: "FileKit", package: "sift"),
                .product(name: "HUDKit", package: "hudkit"),
            ],
            path: "Sources/Stash",
            // Bundle files (Info.plist, machud.json, settings.json), assembled into the .app by
            // the build script, not SwiftPM.
            exclude: ["Resources"]
        ),
        // `stash <command> [key=value ...]`: a thin client for Stash's MacHUD control socket.
        .executableTarget(
            name: "StashCLI",
            dependencies: [.product(name: "HUDKit", package: "hudkit")],
            path: "Sources/StashCLI"
        ),
        .testTarget(
            name: "StashKitTests",
            dependencies: ["StashKit"],
            path: "Tests/StashKitTests"
        ),
        // Host logic in the app target (e.g. where `panel mode parked` parks) and the shipped
        // manifest/settings schema.
        .testTarget(
            name: "StashTests",
            dependencies: ["Stash", "StashKit", .product(name: "HUDKit", package: "hudkit")],
            path: "Tests/StashTests"
        ),
    ]
)
