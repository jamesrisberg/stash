import Foundation
import XCTest
@testable import StashKit

/// `snippets list query=`: name, keyword and collection, case-insensitive, best first; and
/// the one-line preview.
final class SnippetSearchTests: XCTestCase {
    private let snippets = [
        Snippet(id: "1", name: "Signature", keyword: "sig", text: "a", collection: "Mail"),
        Snippet(id: "2", name: "Design brief", keyword: "brief", text: "b", collection: "Work"),
        Snippet(id: "3", name: "Assign reviewer", keyword: "asr", text: "c", collection: "Work"),
        Snippet(id: "4", name: "Home address", keyword: "addr", text: "d", collection: "Signed forms"),
        Snippet(id: "5", name: "Sigil", keyword: "sgl", text: "e", collection: "Misc"),
    ]

    private func ids(_ query: String) -> [String] { SnippetSearch.rank(snippets, query: query).map(\.id) }

    func testAnEmptyQueryListsEverythingByCollectionThenName() {
        XCTAssertEqual(ids(""), ["1", "5", "4", "3", "2"])
        XCTAssertEqual(ids("   "), ids(""))
    }

    func testRanking() {
        // keyword exact, then name prefix, then name contains (by collection, then name), then collection.
        XCTAssertEqual(ids("sig"), ["1", "5", "3", "2", "4"])
    }

    func testCaseInsensitive() {
        XCTAssertEqual(ids("SIG"), ids("sig"))
        XCTAssertEqual(ids("work"), ["3", "2"])
    }

    func testKeywordPrefixBeatsNameContains() {
        XCTAssertEqual(ids("ad"), ["4"])
        XCTAssertEqual(ids("br"), ["2"])
    }

    func testNoMatches() {
        XCTAssertEqual(ids("zzz"), [])
    }

    func testPreviewIsOneShortLine() {
        XCTAssertEqual(SnippetSearch.preview("  Kind regards,\n\n\tA. Tester  "), "Kind regards, A. Tester")
        let long = String(repeating: "word ", count: 40)
        let preview = SnippetSearch.preview(long)
        XCTAssertLessThanOrEqual(preview.count, SnippetSearch.previewLength + 1)
        XCTAssertGreaterThan(preview.count, SnippetSearch.previewLength - 6)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertFalse(preview.contains("\n"))
    }
}
