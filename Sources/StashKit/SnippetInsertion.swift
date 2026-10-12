import Foundation

/// One pasteboard item's data, by type (what `SavedClipboard` keeps).
public struct PasteboardEntry: Equatable, Sendable {
    public var type: String
    public var data: Data
    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// The clipboard as it was before a snippet borrowed it: every item, every type.
public struct SavedClipboard: Equatable, Sendable {
    public var items: [[PasteboardEntry]]
    public init(items: [[PasteboardEntry]]) { self.items = items }
}

/// What inserting a snippet needs from the system: key events, the clipboard and a clock.
/// The app's driver posts real events; tests record the calls.
public protocol SnippetInsertionDriver: AnyObject {
    /// Posts `count` presses of Delete (backspace).
    func postBackspaces(_ count: Int)
    /// Posts ⌘V; false when that is not permitted.
    func postPaste() -> Bool
    /// Types `text` as key events; false when that is not possible.
    func type(_ text: String) -> Bool
    /// The clipboard's contents, or nil when they are too large to hold and put back safely.
    func saveClipboard() -> SavedClipboard?
    /// Puts `text` on the clipboard, marked so no clipboard manager records it. Returns the
    /// pasteboard's change count after the write, nil when the write failed.
    func writeClipboard(_ text: String) -> Int?
    func clipboardChangeCount() -> Int
    func restoreClipboard(_ saved: SavedClipboard)
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void)
}

/// Replaces a typed keyword with a snippet's text: deletes the keyword, puts the text on the
/// clipboard, pastes it, then gives the clipboard back. When pasting is not possible (a
/// private pasteboard, a clipboard too large to hold, a failed write or ⌘V) it types the text
/// instead.
public enum SnippetInsertion {
    public enum Method: Equatable, Sendable { case paste, type }

    /// Lets the deletes land before the paste or the typing.
    public static let keySettle: TimeInterval = 0.05

    /// How long the snippet stays on the clipboard before the user's clipboard comes back.
    /// Native apps read the pasteboard as ⌘V arrives; an Electron app can take seconds to,
    /// and restoring before it has read would paste the user's own clipboard instead
    /// (SpeakFree's measured values). There is no signal that the paste was consumed, so the
    /// restore waits and only happens if the clipboard still holds the snippet.
    public static func restoreDelay(electron: Bool) -> TimeInterval { electron ? 3.0 : 0.3 }

    /// Starts the sequence and returns the method it chose; the paste, typing and restore
    /// happen on the driver's clock.
    @discardableResult
    public static func run(text: String, deleteCount: Int, canPaste: Bool, restoreDelay: TimeInterval,
                           driver: SnippetInsertionDriver) -> Method {
        if deleteCount > 0 { driver.postBackspaces(deleteCount) }
        guard canPaste, let saved = driver.saveClipboard(), let written = driver.writeClipboard(text) else {
            driver.after(keySettle) { _ = driver.type(text) }
            return .type
        }
        driver.after(keySettle) {
            guard driver.postPaste() else {
                driver.restoreClipboard(saved)
                _ = driver.type(text)
                return
            }
            driver.after(restoreDelay) {
                // Only if the snippet is still what is on the clipboard: a copy made since wins.
                if driver.clipboardChangeCount() == written { driver.restoreClipboard(saved) }
            }
        }
        return .paste
    }
}
