import AppKit
import StashKit

/// Environment overrides so a test instance can run next to the user's Stash without
/// touching its history, socket, hotkey or the system clipboard:
///
/// - `STASH_HOME=<dir>`: history, blobs, preferences and panel frames (default
///   `~/Library/Application Support/Stash`).
/// - `STASH_SOCKET=<name or /abs/path>`: control socket (default `stash`).
/// - `STASH_PASTEBOARD=<name>`: watch and write a private named pasteboard instead of the
///   general one. Simulated ⌘V is disabled then, since the target app would paste the
///   general pasteboard.
/// - `STASH_NO_HOTKEYS=1`: do not register ⌃⌥V.
enum AppEnvironment {
    static let env = ProcessInfo.processInfo.environment

    static var dataDirectory: URL? { dataDirectory(in: env) }

    /// `STASH_HOME`; nil when it is unset or empty.
    static func dataDirectory(in env: [String: String]) -> URL? {
        let value = env["STASH_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        return value.map { URL(filePath: ($0 as NSString).expandingTildeInPath, directoryHint: .isDirectory) }
    }

    static var socketName: String? { nonEmpty("STASH_SOCKET") }

    static var pasteboardName: String? { nonEmpty("STASH_PASTEBOARD") }

    static var noHotKeys: Bool { env["STASH_NO_HOTKEYS"] == "1" }

    static var pasteboard: NSPasteboard {
        pasteboardName.map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? .general
    }

    /// True when anything is redirected; frames are then not saved to the user's defaults.
    static var isIsolated: Bool { dataDirectory != nil || socketName != nil || pasteboardName != nil }

    private static func nonEmpty(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
}
