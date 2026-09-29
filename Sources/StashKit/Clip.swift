import CryptoKit
import Foundation

/// One clipboard history entry. Text-like content lives inline (`text`); binary content
/// (rich text, images) lives in a blob file next to the index, named by `blob`.
public struct Clip: Codable, Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text
        /// RTF blob plus its plain-text rendering in `text`.
        case richText
        /// PNG blob.
        case image
        /// One or more file URLs (`fileURLs`); `text` holds their paths, one per line.
        case files
        /// A single web URL in `text`.
        case url
    }

    public var id: UUID
    public var kind: Kind
    /// Plain text (text, url), the plain rendering (richText), or the paths (files). Nil for images.
    public var text: String?
    /// For `.files`.
    public var fileURLs: [URL]?
    /// Blob file name (in the store's `blobs` folder) for `.richText` and `.image`.
    public var blob: String?
    /// Bundle id of the app that was frontmost when the clip was copied.
    public var sourceBundleID: String?
    public var date: Date
    public var pinned: Bool
    /// Content size in bytes (text as UTF-8, blob bytes, or total file sizes when known).
    public var size: Int
    /// Hex SHA-256 of the content, for dedupe.
    public var contentHash: String
    /// Pixel size for images.
    public var imageSize: CGSizeCodable?
    /// Set instead of `sourceBundleID` for an item that arrived through the `text-feed`
    /// capability (`feed add`) rather than the pasteboard: a short label such as "Dictation" or
    /// "Agent". Nil for an ordinary clipboard clip. Missing on clips written before this field
    /// existed, which decode it as nil.
    public var feedSource: String?
    /// Optional title a feed sender attached, shown instead of the text-derived `title` when set.
    public var feedTitle: String?

    public init(id: UUID = UUID(), kind: Kind, text: String? = nil, fileURLs: [URL]? = nil, blob: String? = nil,
                sourceBundleID: String? = nil, date: Date = Date(), pinned: Bool = false, size: Int,
                contentHash: String, imageSize: CGSizeCodable? = nil, feedSource: String? = nil,
                feedTitle: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.fileURLs = fileURLs
        self.blob = blob
        self.sourceBundleID = sourceBundleID
        self.date = date
        self.pinned = pinned
        self.size = size
        self.contentHash = contentHash
        self.imageSize = imageSize
        self.feedSource = feedSource
        self.feedTitle = feedTitle
    }

    /// Whether this is a `text-feed` item rather than a clipboard clip.
    public var isFeedItem: Bool { feedSource != nil }

    /// One-line summary for lists and `action search`: a feed sender's own `title` when given,
    /// else the usual text-derived summary.
    public var title: String {
        if let feedTitle, !feedTitle.isEmpty { return feedTitle }
        switch kind {
        case .image:
            if let s = imageSize { return "Image \(Int(s.width))×\(Int(s.height))" }
            return "Image"
        case .files:
            let urls = fileURLs ?? []
            if urls.count == 1 { return urls[0].lastPathComponent }
            return "\(urls.count) files"
        case .text, .richText, .url:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let line = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.count > 200 ? String(line.prefix(200)) + "…" : line
        }
    }

    /// The text a search matches against: content for text-like clips, names and paths for files.
    public var searchableText: String? {
        switch kind {
        case .text, .richText, .url: return text
        case .files: return (fileURLs ?? []).map { $0.path(percentEncoded: false) }.joined(separator: "\n")
        case .image: return nil
        }
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(_ string: String, kind: Kind) -> String {
        hash(Data((kind.rawValue + "\u{0}" + string).utf8))
    }
}

/// A `CGSize` that encodes as `[w, h]`.
public struct CGSizeCodable: Codable, Equatable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        width = try c.decode(Double.self)
        height = try c.decode(Double.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(width)
        try c.encode(height)
    }
}

/// What a pasteboard read produces: the clip (without an id-bound blob name yet) plus the
/// blob bytes to store, if any.
public struct ClipPayload: Equatable, Sendable {
    public var kind: Clip.Kind
    public var text: String?
    public var fileURLs: [URL]?
    public var blobData: Data?
    /// Blob file extension: "rtf" or "png".
    public var blobExtension: String?
    public var imageSize: CGSizeCodable?

    public init(kind: Clip.Kind, text: String? = nil, fileURLs: [URL]? = nil, blobData: Data? = nil,
                blobExtension: String? = nil, imageSize: CGSizeCodable? = nil) {
        self.kind = kind
        self.text = text
        self.fileURLs = fileURLs
        self.blobData = blobData
        self.blobExtension = blobExtension
        self.imageSize = imageSize
    }

    public static func text(_ string: String) -> ClipPayload {
        ClipPayload(kind: ClipReader.isWebURL(string) ? .url : .text, text: string)
    }

    public var contentHash: String {
        switch kind {
        case .image: return Clip.hash(blobData ?? Data())
        case .files: return Clip.hash((fileURLs ?? []).map(\.absoluteString).joined(separator: "\n"), kind: .files)
        case .richText: return Clip.hash(text ?? "", kind: .richText)
        case .text, .url: return Clip.hash(text ?? "", kind: .text)
        }
    }

    public var size: Int {
        if let blobData { return blobData.count }
        if kind == .files {
            return (fileURLs ?? []).reduce(0) { total, url in
                total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return (text ?? "").utf8.count
    }
}
