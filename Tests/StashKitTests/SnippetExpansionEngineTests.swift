import Foundation
import XCTest
@testable import StashKit

/// The typed-keyword matcher, driven by synthetic key events: a rolling buffer of typed
/// characters, reset by navigation keys, shortcuts, clicks and app switches, and silent while
/// secure input is on or an ignored app is frontmost.
final class SnippetExpansionEngineTests: XCTestCase {
    private var engine: SnippetExpansionEngine!
    private let editor = SnippetExpansionEngine.Context(secureInput: false, frontmostBundleID: "com.example.editor")

    override func setUp() {
        engine = SnippetExpansionEngine()
        engine.snippets = [
            Snippet(id: "sig", name: "Signature", keyword: "sig", text: "Kind regards", collection: "Mail"),
            Snippet(id: "sig2", name: "Long signature", keyword: "xsig", text: "Very kind regards", collection: "Mail"),
            Snippet(id: "addr", name: "Address", keyword: ";addr", text: "1 Example Way", collection: "Mail"),
            Snippet(id: "manual", name: "Manual", keyword: "man!", text: "only by search", collection: "Mail", autoExpand: false),
        ]
        engine.ignoredBundleIDs = ["com.example.vault"]
    }

    // MARK: - Helpers

    private func key(_ characters: String, code: UInt16 = 0, _ modifiers: KeyInput.Modifiers = []) -> KeyInput {
        KeyInput(keyCode: code, characters: characters, modifiers: modifiers)
    }

    /// Types `text` one character per key; returns the matches in order.
    @discardableResult
    private func type(_ text: String, context: SnippetExpansionEngine.Context? = nil) -> [SnippetExpansionEngine.Match] {
        text.compactMap { engine.handle(key(String($0)), context: context ?? editor) }
    }

    private func press(_ code: UInt16, _ modifiers: KeyInput.Modifiers = []) -> SnippetExpansionEngine.Match? {
        engine.handle(key("", code: code, modifiers), context: editor)
    }

    // MARK: - Matching

    func testTypingAKeywordExpandsItAndClearsTheBuffer() {
        let matches = type("hello sig")
        XCTAssertEqual(matches.map(\.snippet.id), ["sig"])
        XCTAssertEqual(matches.first?.deleteCount, 3, "the keyword's typed characters are deleted")
        XCTAssertEqual(engine.buffer, "")
    }

    func testTheLongestKeywordEndingTheBufferWins() {
        XCTAssertEqual(type("xsig").map(\.snippet.id), ["sig2"])
        XCTAssertEqual(type("xsig").first?.deleteCount, 4)
    }

    func testPunctuationKeywordsMatch() {
        XCTAssertEqual(type("see ;addr").map(\.snippet.id), ["addr"])
    }

    func testSnippetsThatDoNotAutoExpandNeverMatch() {
        XCTAssertTrue(type("man!").isEmpty)
    }

    func testKeywordsAreCaseSensitive() {
        XCTAssertTrue(type("SIG").isEmpty)
    }

    func testDisabledEngineNeverMatches() {
        engine.isEnabled = false
        XCTAssertTrue(type("sig").isEmpty)
    }

    func testTheBufferIsBounded() {
        type(String(repeating: "a", count: 500))
        XCTAssertLessThanOrEqual(engine.buffer.count, SnippetExpansionEngine.maxBuffer)
        XCTAssertEqual(type("sig").map(\.snippet.id), ["sig"])
    }

    // MARK: - Editing and resets

    func testBackspaceEditsTheBuffer() {
        type("sx")
        XCTAssertNil(press(KeyInput.Code.delete))
        XCTAssertEqual(type("ig").map(\.snippet.id), ["sig"], "s, x, ⌫, i, g is \"sig\"")
    }

    func testNavigationKeysReset() {
        for code in [KeyInput.Code.leftArrow, KeyInput.Code.rightArrow, KeyInput.Code.upArrow, KeyInput.Code.downArrow,
                     KeyInput.Code.home, KeyInput.Code.end, KeyInput.Code.pageUp, KeyInput.Code.pageDown,
                     KeyInput.Code.tab, KeyInput.Code.returnKey, KeyInput.Code.keypadEnter, KeyInput.Code.escape,
                     KeyInput.Code.forwardDelete] {
            type("si")
            XCTAssertNil(press(code))
            XCTAssertEqual(engine.buffer, "", "key code \(code) resets")
            XCTAssertTrue(type("g").isEmpty, "key code \(code): the keyword was interrupted")
        }
    }

    func testShortcutsReset() {
        type("si")
        XCTAssertNil(engine.handle(key("v", .command), context: editor))
        XCTAssertTrue(type("g").isEmpty, "⌘V in between")
        type("si")
        XCTAssertNil(engine.handle(key("a", .control), context: editor))
        XCTAssertTrue(type("g").isEmpty, "⌃A in between")
    }

    func testShiftAndOptionCharactersAreTyped() {
        engine.snippets.append(Snippet(id: "deg", name: "Degrees", keyword: "Dº", text: "degrees", collection: "C"))
        XCTAssertNil(engine.handle(key("D", .shift), context: editor))
        XCTAssertEqual(engine.handle(key("º", .option), context: editor)?.snippet.id, "deg")
    }

    func testBackspaceWithAModifierResets() {
        for modifiers: KeyInput.Modifiers in [.option, .shift, .command, .control] {
            type("sigx")
            XCTAssertNil(press(KeyInput.Code.delete, modifiers))
            XCTAssertEqual(engine.buffer, "", "\(modifiers) Delete removes more than one character in the app")
            XCTAssertTrue(type("g").isEmpty)
        }
    }

    /// A dead key (⌥E, then a letter) composes in the app; what the buffer would hold is not
    /// what was typed, so the dead key and the key that completes it both start over.
    func testDeadKeysStartOver() {
        type("si")
        XCTAssertNil(engine.handle(key("", code: 14, .option), context: editor), "⌥E starts a dead key")
        XCTAssertEqual(engine.buffer, "")
        XCTAssertTrue(type("e").isEmpty, "the composed character is not counted")
        XCTAssertEqual(engine.buffer, "")
        XCTAssertEqual(type("sig").map(\.snippet.id), ["sig"], "typing after it counts again")
    }

    func testAnInputMethodComposingNeverMatches() {
        let composing = SnippetExpansionEngine.Context(secureInput: false, frontmostBundleID: "com.example.editor", composing: true)
        XCTAssertTrue(type("sig", context: composing).isEmpty)
        XCTAssertEqual(engine.buffer, "")
    }

    func testClicksAndAppSwitchesReset() {
        type("si")
        engine.reset()
        XCTAssertTrue(type("g").isEmpty)
    }

    func testFrontmostAppChangeResets() {
        type("si")
        let other = SnippetExpansionEngine.Context(secureInput: false, frontmostBundleID: "com.example.other")
        XCTAssertTrue(type("g", context: other).isEmpty, "the first two characters went to another app")
    }

    // MARK: - Privacy

    func testSecureInputNeverMatchesAndForgetsWhatWasTyped() {
        let secure = SnippetExpansionEngine.Context(secureInput: true, frontmostBundleID: "com.example.editor")
        XCTAssertTrue(type("sig", context: secure).isEmpty)
        XCTAssertEqual(engine.buffer, "", "nothing typed into a password field is kept")
        type("si", context: secure)
        XCTAssertTrue(type("g").isEmpty, "characters typed under secure input never complete a keyword")
    }

    func testIgnoredAppsNeverMatch() {
        let vault = SnippetExpansionEngine.Context(secureInput: false, frontmostBundleID: "com.example.vault")
        XCTAssertTrue(type("sig", context: vault).isEmpty)
        XCTAssertEqual(engine.buffer, "")
    }
}
