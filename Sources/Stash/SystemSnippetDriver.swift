import AppKit
import Carbon
import StashKit

/// Inserts snippets for real: Delete and ⌘V key events (Accessibility), Unicode key events for
/// the typed fallback, and the clipboard borrowed and given back. Every event it posts carries
/// `SnippetKeyTap.eventTag`, so the key tap never reads Stash's own typing as the user's.
/// Its writes never become clips: the snippet carries the nspasteboard.org transient and
/// concealed markers plus Stash's own, and the watcher skips both the write and the restore.
final class SystemSnippetDriver: SnippetInsertionDriver {
    /// The largest clipboard held and put back around a paste; above it the text is typed.
    static let maxRestorableBytes = 16 * 1024 * 1024

    private let pasteboard: NSPasteboard
    private let watcher: ClipboardWatcher

    init(pasteboard: NSPasteboard, watcher: ClipboardWatcher) {
        self.pasteboard = pasteboard
        self.watcher = watcher
    }

    // MARK: Key events

    func postBackspaces(_ count: Int) {
        guard count > 0, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for _ in 0..<count {
            post(source: source, key: CGKeyCode(kVK_Delete), flags: [])
        }
    }

    func postPaste() -> Bool {
        MainActor.assumeIsolated { Paster.postCommandV(tag: SnippetKeyTap.eventTag) }
    }

    /// Types `text` as Unicode key events, at most 20 UTF-16 units per event (the API's limit),
    /// never splitting a character. A line break is ⇧↩, which breaks the line without sending
    /// in chat apps.
    func type(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: SnippetKeyTap.eventTag)
                event.post(tap: .cghidEventTap)
            }
            chunk.removeAll()
        }
        for character in text {
            if character.isNewline {
                flush()
                post(source: source, key: CGKeyCode(kVK_Return), flags: .maskShift)
                continue
            }
            let units = Array(String(character).utf16)
            if chunk.count + units.count > 20 { flush() }
            chunk.append(contentsOf: units)
        }
        flush()
        return true
    }

    private func post(source: CGEventSource, key: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: SnippetKeyTap.eventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Clipboard

    func saveClipboard() -> SavedClipboard? {
        var bytes = 0
        var items: [[PasteboardEntry]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entries: [PasteboardEntry] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                bytes += data.count
                if bytes > Self.maxRestorableBytes { return nil }
                entries.append(PasteboardEntry(type: type.rawValue, data: data))
            }
            items.append(entries)
        }
        return SavedClipboard(items: items)
    }

    func writeClipboard(_ text: String) -> Int? {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in [ClipReader.stashMarker, NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                       NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")] {
            item.setData(Data(), forType: marker)
        }
        let ok = pasteboard.writeObjects([item])
        skipCurrent()
        return ok ? pasteboard.changeCount : nil
    }

    func clipboardChangeCount() -> Int { pasteboard.changeCount }

    func restoreClipboard(_ saved: SavedClipboard) {
        pasteboard.clearContents()
        let items = saved.items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type)) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        skipCurrent()
    }

    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func skipCurrent() {
        MainActor.assumeIsolated { watcher.skipCurrent() }
    }

    /// Whether `app` is built on Electron, whose apps can take seconds to read a paste.
    static func isElectron(_ app: NSRunningApplication?) -> Bool {
        guard let url = app?.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: url.appending(path: "Contents/Frameworks/Electron Framework.framework")
            .path(percentEncoded: false))
    }
}
