import Foundation

/// A key press as the expansion engine sees it: the virtual key code, the characters it typed
/// (empty for a dead key or a function key) and the modifiers held.
public struct KeyInput: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let control = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// The virtual key codes the engine treats specially (Carbon's `kVK_…` values).
    public enum Code {
        public static let returnKey: UInt16 = 36
        public static let tab: UInt16 = 48
        public static let delete: UInt16 = 51
        public static let escape: UInt16 = 53
        public static let keypadEnter: UInt16 = 76
        public static let home: UInt16 = 115
        public static let pageUp: UInt16 = 116
        public static let forwardDelete: UInt16 = 117
        public static let end: UInt16 = 119
        public static let pageDown: UInt16 = 121
        public static let leftArrow: UInt16 = 123
        public static let rightArrow: UInt16 = 124
        public static let downArrow: UInt16 = 125
        public static let upArrow: UInt16 = 126

        /// Keys that move the insertion point or leave the field: what was typed before them
        /// is no longer what ends at the cursor.
        static let resetting: Set<UInt16> = [returnKey, tab, escape, keypadEnter, home, pageUp, forwardDelete, end,
                                             pageDown, leftArrow, rightArrow, downArrow, upArrow]
    }

    public var keyCode: UInt16
    public var characters: String
    public var modifiers: Modifiers

    public init(keyCode: UInt16, characters: String, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
    }
}

/// Watches typed characters for a snippet keyword. Keeps a short rolling buffer of what was
/// typed into the frontmost app; when the buffer ends with an auto-expanding snippet's
/// keyword, reports the snippet and how many characters to delete, and starts over.
///
/// The buffer resets on navigation keys, shortcuts (⌘ or ⌃ held), Delete with any modifier
/// (which removes a word or a line in the app, not one character), a different target app, and
/// `reset()` (clicks, app switches). While secure input is on (a password field), an input
/// method is composing, or an ignored app is the target, nothing is kept at all. A dead key
/// (⌥E, then a letter) composes a character in the app that the key events do not show, so
/// the dead key and the key after it start over too: keywords match typed ASCII best. Keywords
/// are case-sensitive and match anywhere, as in Alfred.
public final class SnippetExpansionEngine {
    public struct Context: Equatable, Sendable {
        public var secureInput: Bool
        /// The app the key goes to.
        public var frontmostBundleID: String?
        /// An input method (not a plain keyboard layout) is the input source: keys go into
        /// marked text, not straight into the document.
        public var composing: Bool
        public init(secureInput: Bool, frontmostBundleID: String?, composing: Bool = false) {
            self.secureInput = secureInput
            self.frontmostBundleID = frontmostBundleID
            self.composing = composing
        }
    }

    public struct Match: Equatable, Sendable {
        public var snippet: Snippet
        /// Characters to delete before inserting: the keyword as typed.
        public var deleteCount: Int
    }

    /// The longest buffer kept, in characters; longer keywords never match.
    public static let maxBuffer = 64

    public var isEnabled = true { didSet { if !isEnabled { reset() } } }
    public var ignoredBundleIDs: Set<String> = []
    public var snippets: [Snippet] = [] {
        didSet { candidates = snippets.filter { $0.autoExpand && !$0.keyword.isEmpty && $0.keyword.count <= Self.maxBuffer } }
    }

    public private(set) var buffer = ""
    private var bufferApp: String?
    /// A dead key was pressed: the next character is composed in the app.
    private var afterDeadKey = false
    private var candidates: [Snippet] = []

    public init() {}

    public func reset() {
        buffer = ""
        bufferApp = nil
        afterDeadKey = false
    }

    /// Feeds one key press. Returns the snippet to expand when this key completed a keyword.
    public func handle(_ key: KeyInput, context: Context) -> Match? {
        guard isEnabled, !context.secureInput, !context.composing,
              !(context.frontmostBundleID.map(ignoredBundleIDs.contains) ?? false) else {
            reset()
            return nil
        }
        if context.frontmostBundleID != bufferApp {
            reset()
            bufferApp = context.frontmostBundleID
        }
        let startOver = !key.modifiers.isDisjoint(with: [.command, .control])
            || KeyInput.Code.resetting.contains(key.keyCode)
            || (key.keyCode == KeyInput.Code.delete && !key.modifiers.isEmpty)
        if startOver {
            reset()
            bufferApp = context.frontmostBundleID
            return nil
        }
        if key.keyCode == KeyInput.Code.delete {
            if !buffer.isEmpty { buffer.removeLast() }
            return nil
        }
        // A key that types nothing is a dead key (or a function key); the key after a dead
        // key types a character the event does not show. Neither is counted.
        if key.characters.isEmpty || afterDeadKey {
            reset()
            bufferApp = context.frontmostBundleID
            afterDeadKey = key.characters.isEmpty
            return nil
        }
        guard !key.characters.contains(where: \.isNewline) else { return nil }
        buffer += key.characters
        if buffer.count > Self.maxBuffer { buffer = String(buffer.suffix(Self.maxBuffer)) }

        guard let snippet = candidates.filter({ buffer.hasSuffix($0.keyword) }).max(by: { $0.keyword.count < $1.keyword.count })
        else { return nil }
        buffer = ""
        return Match(snippet: snippet, deleteCount: snippet.keyword.count)
    }
}
