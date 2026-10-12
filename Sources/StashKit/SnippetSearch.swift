import Foundation

/// Finding snippets by name, keyword or collection (`snippets list query=`, the Snippets
/// window), and the one-line preview MacHUD's search bar shows.
public enum SnippetSearch {
    public static let previewLength = 80

    /// Matching snippets, best first: keyword equal to the query, keyword starting with it,
    /// name starting with it, a word of the name starting with it, keyword containing it, name
    /// containing it, collection containing it. Case-insensitive; ties by collection, then name.
    /// An empty query lists everything by collection, then name.
    public static func rank(_ snippets: [Snippet], query: String) -> [Snippet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scored: [(Int, Snippet)] = snippets.compactMap { s in
            guard !q.isEmpty else { return (0, s) }
            return score(s, q).map { ($0, s) }
        }
        return scored.sorted { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            return ordered(a.1, b.1)
        }.map(\.1)
    }

    private static func score(_ s: Snippet, _ q: String) -> Int? {
        let keyword = s.keyword.lowercased()
        let name = s.name.lowercased()
        if keyword == q { return 0 }
        if keyword.hasPrefix(q) { return 1 }
        if name.hasPrefix(q) { return 2 }
        if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 3 }
        if keyword.contains(q) { return 4 }
        if name.contains(q) { return 5 }
        if s.collection.lowercased().contains(q) { return 6 }
        return nil
    }

    /// By collection, then name, case-insensitively.
    public static func ordered(_ a: Snippet, _ b: Snippet) -> Bool {
        let c = a.collection.localizedCaseInsensitiveCompare(b.collection)
        if c != .orderedSame { return c == .orderedAscending }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// `text` on one line (runs of whitespace and line breaks become one space), cut to
    /// `previewLength` characters with an ellipsis.
    public static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard line.count > previewLength else { return line }
        return String(line.prefix(previewLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
