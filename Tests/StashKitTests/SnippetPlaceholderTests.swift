import Foundation
import XCTest
@testable import StashKit

/// `{date}`, `{time}` and `{clipboard}`, Alfred's defaults: the date and time in the system's
/// medium style, the clipboard as plain text. Every other `{…}` is left as typed.
final class SnippetPlaceholderTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_791_731_045) // 2026-10-11 15:04:05 UTC
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US")

    private func placeholders(clipboard: String? = "copied words") -> SnippetPlaceholders {
        SnippetPlaceholders(now: { [instant] in instant }, clipboard: { clipboard }, locale: locale, timeZone: utc)
    }

    private func medium(date: DateFormatter.Style, time: DateFormatter.Style) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = utc
        f.dateStyle = date
        f.timeStyle = time
        return f.string(from: instant)
    }

    func testDateAndTimeUseTheMediumStyle() {
        let date = placeholders().expand("{date}")
        let time = placeholders().expand("{time}")
        XCTAssertEqual(date, medium(date: .medium, time: .none))
        XCTAssertEqual(time, medium(date: .none, time: .medium))
        XCTAssertEqual(date, "Oct 11, 2026")
        XCTAssertTrue(time.hasPrefix("3:04:05"), time)
    }

    func testClipboardIsThePlainTextOnTheClipboard() {
        XCTAssertEqual(placeholders().expand("Re: {clipboard}."), "Re: copied words.")
        XCTAssertEqual(placeholders(clipboard: nil).expand("Re: {clipboard}."), "Re: .", "nothing on the clipboard inserts nothing")
    }

    func testRepeatedAndMixedPlaceholders() {
        let text = placeholders().expand("{date} {date}\n{clipboard} at {time}")
        XCTAssertEqual(text, "Oct 11, 2026 Oct 11, 2026\ncopied words at \(medium(date: .none, time: .medium))")
    }

    func testOtherTokensAreLeftAsTyped() {
        let text = "Hi {cursor} {date:short} {clipboard:1} {\"k\": 2} {}"
        XCTAssertEqual(placeholders().expand(text), text)
    }

    func testUnknownTokensListsPlaceholderShapedTokensOnly() {
        let text = "{date} {cursor} {snippet:sig} {date:short} {Name} {\"k\": 2} { spaced } {} {time}"
        XCTAssertEqual(SnippetPlaceholders.unknownTokens(in: text), ["{cursor}", "{snippet:sig}", "{date:short}", "{Name}"])
    }

    func testClipboardIsReadOnlyWhenUsed() {
        var reads = 0
        let p = SnippetPlaceholders(now: Date.init, clipboard: { reads += 1; return "x" }, locale: locale, timeZone: utc)
        _ = p.expand("no placeholders")
        XCTAssertEqual(reads, 0)
        _ = p.expand("{clipboard}{clipboard}")
        XCTAssertEqual(reads, 1)
    }
}
