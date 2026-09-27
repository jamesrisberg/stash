import Foundation

/// Clip history persisted as `history.json` plus a `blobs/` folder, by default under
/// `~/Library/Application Support/Stash`.
///
/// Clips are kept newest first. `cap` bounds the number of unpinned clips (pinned clips are
/// exempt); the oldest unpinned clips and their blobs are dropped first. A clip identical to
/// the newest one is not added twice.
public final class ClipStore {
    public enum AddResult: Equatable {
        case added(Clip)
        /// Identical to the newest clip; nothing was added.
        case duplicate(Clip)

        public var clip: Clip {
            switch self { case .added(let c), .duplicate(let c): return c }
        }
        public var isNew: Bool { if case .added = self { return true } else { return false } }
    }

    public let directory: URL
    public var cap: Int { didSet { if cap != oldValue { enforceCap(); save() } } }
    public private(set) var clips: [Clip] = []
    /// Called after every change.
    public var onChange: (() -> Void)?

    private let fileManager = FileManager.default

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "Stash", directoryHint: .isDirectory)
    }

    public var indexURL: URL { directory.appending(path: "history.json") }
    public var blobsURL: URL { directory.appending(path: "blobs", directoryHint: .isDirectory) }

    public init(directory: URL = ClipStore.defaultDirectory, cap: Int = 200) {
        self.directory = directory
        self.cap = max(1, cap)
    }

    private struct FileFormat: Codable {
        var version: Int
        var clips: [Clip]
    }

    // MARK: - Persistence

    /// Loads the history. A missing file is an empty history; a corrupt one throws rather
    /// than being silently replaced.
    public func load() throws {
        guard fileManager.fileExists(atPath: indexURL.path(percentEncoded: false)) else {
            clips = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        clips = try decoder.decode(FileFormat.self, from: Data(contentsOf: indexURL)).clips
        enforceCap()
        removeOrphanBlobs()
    }

    public func save() {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(FileFormat(version: 1, clips: clips)).write(to: indexURL, options: .atomic)
        } catch {
            NSLog("Stash: saving history failed: %@", error.localizedDescription)
        }
    }

    public func blobURL(for clip: Clip) -> URL? {
        clip.blob.map { blobsURL.appending(path: $0) }
    }

    // MARK: - Changes

    @discardableResult
    public func add(_ payload: ClipPayload, source: String? = nil, date: Date = Date()) throws -> AddResult {
        let hash = payload.contentHash
        if let newest = clips.first, newest.contentHash == hash {
            return .duplicate(newest)
        }
        let id = UUID()
        var blob: String?
        if let data = payload.blobData {
            let name = "\(id.uuidString).\(payload.blobExtension ?? "bin")"
            try fileManager.createDirectory(at: blobsURL, withIntermediateDirectories: true)
            try data.write(to: blobsURL.appending(path: name), options: .atomic)
            blob = name
        }
        let clip = Clip(id: id, kind: payload.kind, text: payload.text, fileURLs: payload.fileURLs, blob: blob,
                        sourceBundleID: source, date: date, size: payload.size, contentHash: hash,
                        imageSize: payload.imageSize)
        clips.insert(clip, at: 0)
        enforceCap()
        changed()
        return .added(clip)
    }

    public func clip(id: UUID) -> Clip? { clips.first { $0.id == id } }

    public func remove(id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        deleteBlob(of: clips.remove(at: i))
        changed()
    }

    public func setPinned(_ pinned: Bool, id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].pinned != pinned else { return }
        clips[i].pinned = pinned
        if !pinned { enforceCap() }
        changed()
    }

    public func togglePin(id: UUID) {
        guard let clip = clip(id: id) else { return }
        setPinned(!clip.pinned, id: id)
    }

    /// Moves a clip to the top (it was just pasted again).
    public func promote(id: UUID, date: Date = Date()) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        var clip = clips.remove(at: i)
        clip.date = date
        clips.insert(clip, at: 0)
        changed()
    }

    /// Removes every clip, or only the unpinned ones.
    public func clear(keepPinned: Bool = true) {
        let (keep, drop) = (clips.filter { keepPinned && $0.pinned }, clips.filter { !(keepPinned && $0.pinned) })
        drop.forEach(deleteBlob)
        clips = keep
        changed()
    }

    // MARK: - Queries

    public var pinned: [Clip] { clips.filter(\.pinned) }
    public var unpinned: [Clip] { clips.filter { !$0.pinned } }

    /// Clips whose text contains every whitespace-separated term of `query` (case- and
    /// diacritic-insensitive), newest first. An empty query matches everything.
    public func search(_ query: String) -> [Clip] {
        Self.filter(clips, query: query)
    }

    public static func filter(_ clips: [Clip], query: String) -> [Clip] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return clips }
        return clips.filter { clip in
            guard let text = clip.searchableText else { return false }
            return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    // MARK: - Private

    private func changed() {
        save()
        onChange?()
    }

    private func enforceCap() {
        var unpinnedSeen = 0
        var dropped: [Clip] = []
        clips.removeAll { clip in
            guard !clip.pinned else { return false }
            unpinnedSeen += 1
            if unpinnedSeen > cap { dropped.append(clip); return true }
            return false
        }
        dropped.forEach(deleteBlob)
    }

    private func deleteBlob(of clip: Clip) {
        guard let url = blobURL(for: clip) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func removeOrphanBlobs() {
        let live = Set(clips.compactMap(\.blob))
        let names = (try? fileManager.contentsOfDirectory(atPath: blobsURL.path(percentEncoded: false))) ?? []
        for name in names where !live.contains(name) {
            try? fileManager.removeItem(at: blobsURL.appending(path: name))
        }
    }
}
