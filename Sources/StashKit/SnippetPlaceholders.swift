import Foundation

/// Fills in a snippet's placeholders the way Alfred does by default: `{date}` and `{time}` in
/// the system's medium style, `{clipboard}` as the clipboard's plain text (nothing when it
/// holds none). Any other `{…}` is left exactly as typed; the Alfred import reports the
/// placeholder-shaped ones (`unknownTokens`).
public struct SnippetPlaceholders {
    public static let supported = ["{date}", "{time}", "{clipboard}"]

    public var now: () -> Date
    public var clipboard: () -> String?
    public var locale: Locale
    public var timeZone: TimeZone

    public init(now: @escaping () -> Date = Date.init, clipboard: @escaping () -> String?,
                locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        self.now = now
        self.clipboard = clipboard
        self.locale = locale
        self.timeZone = timeZone
    }

    /// `text` with the supported placeholders filled in. The clipboard is read only when
    /// `{clipboard}` occurs, and once.
    public func expand(_ text: String) -> String {
        guard text.contains("{") else { return text }
        var out = text
        if out.contains("{date}") || out.contains("{time}") {
            let date = now()
            out = out.replacingOccurrences(of: "{date}", with: format(date, date: .medium, time: .none))
            out = out.replacingOccurrences(of: "{time}", with: format(date, date: .none, time: .medium))
        }
        if out.contains("{clipboard}") {
            out = out.replacingOccurrences(of: "{clipboard}", with: clipboard() ?? "")
        }
        return out
    }

    /// `{date}` and `{time}` filled in, `{clipboard}` left as typed: what a preview shows, so a
    /// list of snippets never puts the clipboard (perhaps a password) on screen.
    public func expandForPreview(_ text: String) -> String {
        var preview = self
        preview.clipboard = { "{clipboard}" }
        return preview.expand(text)
    }

    private func format(_ date: Date, date dateStyle: DateFormatter.Style, time timeStyle: DateFormatter.Style) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = dateStyle
        f.timeStyle = timeStyle
        return f.string(from: date)
    }

    /// Placeholder-shaped tokens (a brace, a letter, no line break, a closing brace) other than
    /// the supported three, each occurrence in order: `{cursor}`, `{snippet:sig}`,
    /// `{date:short}`. Braces that do not start with a letter (JSON, code) are not counted.
    public static func unknownTokens(in text: String) -> [String] {
        guard text.contains("{") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return tokenPattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }.filter { !supported.contains($0) }
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: #"\{[A-Za-z][^{}\n]*\}"#)
}
