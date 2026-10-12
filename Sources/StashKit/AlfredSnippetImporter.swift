import Foundation

/// Reads Alfred's snippets: one folder per collection under
/// `Alfred.alfredpreferences/snippets`, each snippet a `<name> [<uid>].json` file holding
/// `{"alfredsnippet": {"snippet", "uid", "name", "keyword", "dontautoexpand"?}}`, and the
/// collection's `info.plist` naming a keyword prefix and suffix (`snippetkeywordprefix`,
/// `snippetkeywordsuffix`) that Alfred adds to every keyword in it. Only reads; Alfred's files
/// are never changed.
public struct AlfredSnippetImporter {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    public enum ImportError: Error, CustomStringConvertible {
        case noFolder(String)
        public var description: String {
            switch self {
            case .noFolder(let path): return "no Alfred snippets folder at \(path)"
            }
        }
    }

    /// Alfred's snippets folder: inside the preferences `prefs.json` points at (`current`,
    /// set when Alfred's preferences are synced), else in Alfred's Application Support folder.
    public static func defaultFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let support = home.appending(path: "Library/Application Support/Alfred")
        if let data = try? Data(contentsOf: support.appending(path: "prefs.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let current = json["current"] as? String, !current.isEmpty {
            let synced = URL(filePath: (current as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: synced.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue {
                return synced.appending(path: "snippets")
            }
        }
        return support.appending(path: "Alfred.alfredpreferences/snippets")
    }

    private struct File: Decodable {
        struct Body: Decodable {
            var snippet: String
            var uid: String
            var name: String?
            var keyword: String?
            var dontautoexpand: Bool?
        }
        var alfredsnippet: Body
    }

    public func read() throws -> AlfredImport {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.noFolder(folder.path(percentEncoded: false))
        }
        var result = AlfredImport()
        let dirs = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        for dir in dirs {
            let collection = dir.lastPathComponent
            result.collections.append(collection)
            result.countsByCollection[collection] = 0
            let (prefix, suffix) = affixes(in: dir)
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                guard let data = try? Data(contentsOf: file),
                      let body = try? JSONDecoder().decode(File.self, from: data).alfredsnippet,
                      !body.uid.isEmpty else {
                    result.skippedFiles += 1
                    continue
                }
                let keyword = body.keyword ?? ""
                let snippet = Snippet(id: body.uid,
                                      name: body.name ?? keyword,
                                      keyword: keyword.isEmpty ? "" : prefix + keyword + suffix,
                                      text: body.snippet,
                                      collection: collection,
                                      autoExpand: !(body.dontautoexpand ?? false))
                result.snippets.append(snippet)
                result.countsByCollection[collection, default: 0] += 1
                for token in SnippetPlaceholders.unknownTokens(in: body.snippet) {
                    result.unknownPlaceholders[token, default: 0] += 1
                }
            }
        }
        return result
    }

    private func affixes(in dir: URL) -> (String, String) {
        guard let data = try? Data(contentsOf: dir.appending(path: "info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return ("", "")
        }
        return (plist["snippetkeywordprefix"] as? String ?? "", plist["snippetkeywordsuffix"] as? String ?? "")
    }
}

/// What an Alfred snippets folder holds, ready to merge into a `SnippetStore`.
public struct AlfredImport: Equatable, Sendable {
    /// Folder names, sorted; empty collections included.
    public var collections: [String] = []
    public var snippets: [Snippet] = []
    public var countsByCollection: [String: Int] = [:]
    /// Placeholder-shaped tokens Stash does not fill in (left as typed), with how often each occurs.
    public var unknownPlaceholders: [String: Int] = [:]
    /// `.json` files that are not readable Alfred snippets.
    public var skippedFiles = 0

    public init() {}
}

public struct SnippetImportSummary: Equatable, Sendable {
    public var added: Int
    public var updated: Int
    public var unchanged: Int

    public init(added: Int, updated: Int, unchanged: Int) {
        self.added = added
        self.updated = updated
        self.unchanged = unchanged
    }
}

extension SnippetStore {
    /// Adds or updates the imported snippets by id (Alfred's uid), so importing twice never
    /// duplicates; snippets made in Stash are kept. `dryRun` counts without writing.
    @discardableResult
    public func merge(_ batch: AlfredImport, dryRun: Bool = false) throws -> SnippetImportSummary {
        var summary = SnippetImportSummary(added: 0, updated: 0, unchanged: 0)
        var next = snippets
        for snippet in batch.snippets {
            if let i = next.firstIndex(where: { $0.id == snippet.id }) {
                if next[i] == snippet { summary.unchanged += 1 } else { summary.updated += 1; next[i] = snippet }
            } else {
                summary.added += 1
                next.append(snippet)
            }
        }
        guard !dryRun else { return summary }
        let newCollections = collections + batch.collections.filter { !collections.contains($0) }
        if next != snippets || newCollections != collections {
            try replace(snippets: next, collections: newCollections)
        }
        return summary
    }
}
