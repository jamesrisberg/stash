import Foundation

/// A piece of text to reuse: inserted from MacHUD's search bar (`snippets insert`), or typed
/// as its keyword and expanded in place when `autoExpand` is on and expansion is switched on.
public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    /// Alfred's uid for an imported snippet (so a re-import updates it), else a UUID.
    public var id: String
    public var name: String
    public var keyword: String
    /// May hold `{date}`, `{time}` and `{clipboard}`, filled in when the snippet is inserted.
    public var text: String
    public var collection: String
    public var autoExpand: Bool

    public init(id: String = UUID().uuidString, name: String, keyword: String, text: String,
                collection: String = SnippetStore.defaultCollection, autoExpand: Bool = true) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.text = text
        self.collection = collection
        self.autoExpand = autoExpand
    }
}

/// The snippets and their collections, kept in `snippets.json` next to the history
/// (`{"version": 1, "collections": [...], "snippets": [...]}`) and rewritten atomically on
/// every change. Collections are listed by name, so an empty one survives.
public final class SnippetStore {
    public static let fileName = "snippets.json"
    public static let defaultCollection = "Default Collection"

    public enum StoreError: Error, CustomStringConvertible, Equatable {
        case collectionNotEmpty(String)
        public var description: String {
            switch self {
            case .collectionNotEmpty(let name): return "collection \(name) still has snippets"
            }
        }
    }

    private struct File: Codable {
        var version = 1
        var collections: [String]
        var snippets: [Snippet]
    }

    public let fileURL: URL
    public private(set) var snippets: [Snippet] = []
    /// Every collection name, in the order they were added (snippets' collections included).
    public private(set) var collections: [String] = []
    /// Anything changed (after it was saved).
    public var onChange: (() -> Void)?

    public init(directory: URL) {
        fileURL = directory.appending(path: Self.fileName)
    }

    /// Reads the file; no file is an empty store. An unreadable file throws and is left as it is.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            snippets = []
            collections = []
            return
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: fileURL))
        snippets = file.snippets
        collections = Self.merged(file.collections, file.snippets.map(\.collection))
    }

    public func snippet(id: String) -> Snippet? { snippets.first { $0.id == id } }

    /// Collection names, case-insensitively sorted.
    public var sortedCollections: [String] {
        collections.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Adds `snippet`, or replaces the one with its id. Returns whether it was new.
    @discardableResult
    public func upsert(_ snippet: Snippet) throws -> Bool {
        var next = snippets
        let isNew: Bool
        if let i = next.firstIndex(where: { $0.id == snippet.id }) {
            next[i] = snippet
            isNew = false
        } else {
            next.append(snippet)
            isNew = true
        }
        try commit(next, Self.merged(collections, [snippet.collection]))
        return isNew
    }

    public func remove(id: String) throws {
        try commit(snippets.filter { $0.id != id }, collections)
    }

    public func addCollection(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try commit(snippets, Self.merged(collections, [trimmed]))
    }

    /// Removes an empty collection; one with snippets throws.
    public func removeCollection(_ name: String) throws {
        guard !snippets.contains(where: { $0.collection == name }) else { throw StoreError.collectionNotEmpty(name) }
        try commit(snippets, collections.filter { $0 != name })
    }

    /// Replaces everything at once (one write): the import's path.
    func replace(snippets newSnippets: [Snippet], collections newCollections: [String]) throws {
        try commit(newSnippets, Self.merged(newCollections, newSnippets.map(\.collection)))
    }

    private func commit(_ newSnippets: [Snippet], _ newCollections: [String]) throws {
        let file = File(collections: newCollections, snippets: newSnippets)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
        snippets = newSnippets
        collections = newCollections
        onChange?()
    }

    /// `base` followed by the names in `extra` it lacks, in order, without duplicates.
    private static func merged(_ base: [String], _ extra: [String]) -> [String] {
        var seen = Set<String>()
        return (base + extra).filter { seen.insert($0).inserted }
    }
}
