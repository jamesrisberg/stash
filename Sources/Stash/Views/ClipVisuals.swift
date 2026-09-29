import AppKit
import StashKit
import SwiftUI

extension Clip.Kind {
    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .image: "photo"
        case .files: "doc"
        case .url: "link"
        }
    }

    var label: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich text"
        case .image: "Image"
        case .files: "File"
        case .url: "Link"
        }
    }

    var tint: Color {
        switch self {
        case .text: Color(red: 0.62, green: 0.66, blue: 0.75)
        case .richText: Color(red: 0.49, green: 0.36, blue: 0.99)
        case .image: Color(red: 0.96, green: 0.45, blue: 0.71)
        case .files: Color(red: 0.38, green: 0.65, blue: 0.98)
        case .url: Color(red: 0.18, green: 0.83, blue: 0.75)
        }
    }
}

/// Square preview: image thumbnail, FileKit Quick Look thumbnail for files, else a type icon.
struct ClipThumbnail: View {
    @ObservedObject var model: AppModel
    let clip: Clip
    var side: CGFloat = 34
    /// Brighter tile and icon (hovered or just copied).
    var highlighted = false

    @State private var fileThumb: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                .fill(clip.kind.tint.opacity(highlighted ? 0.30 : 0.16))
            if let image = model.image(for: clip) ?? fileThumb {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: clip.kind == .image ? .fill : .fit)
                    .padding(clip.kind == .image ? 0 : 2)
            } else {
                Image(systemName: clip.kind.symbol)
                    .font(.system(size: side * 0.42, weight: .medium))
                    .foregroundStyle(clip.kind.tint)
                    .brightness(highlighted ? 0.18 : 0)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
        .task(id: clip.id) { await loadFileThumbnail() }
    }

    private func loadFileThumbnail() async {
        guard clip.kind == .files, let url = clip.fileURLs?.first else { return }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let cg = await model.thumbnails.thumbnail(for: url, modified: modified) {
            fileThumb = NSImage(cgImage: cg, size: .zero)
        } else {
            fileThumb = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        }
    }
}

extension Clip {
    /// SF Symbol for a feed item's small source label (nil for an ordinary clipboard clip).
    var feedSymbol: String? {
        guard let feedSource else { return nil }
        switch feedSource {
        case "Dictation": return "mic.fill"
        case "Agent": return "sparkles"
        default: return "arrow.down.circle.fill"
        }
    }
}

enum ClipFormat {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func age(_ date: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(date) < 45 ? "now" : relative.localizedString(for: date, relativeTo: now)
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Drag a clip out: text as a string (links also as a URL), files as their URLs, images as
/// PNG data plus a file promise named "Stash Image.png".
enum ClipDrag {
    @MainActor
    static func provider(for clip: Clip, model: AppModel) -> NSItemProvider {
        switch clip.kind {
        case .files:
            if let url = clip.fileURLs?.first, let provider = NSItemProvider(contentsOf: url) { return provider }
        case .image:
            if let blob = model.store.blobURL(for: clip) {
                let provider = NSItemProvider()
                provider.suggestedName = "Stash Image"
                provider.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .all) { done in
                    done(try? Data(contentsOf: blob), nil)
                    return nil
                }
                provider.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .all) { done in
                    let dir = FileManager.default.temporaryDirectory.appending(path: "StashDrag-\(UUID().uuidString)")
                    let file = dir.appending(path: "Stash Image.png")
                    do {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: blob, to: file)
                        done(file, false, nil)
                    } catch {
                        done(nil, false, error)
                    }
                    return nil
                }
                return provider
            }
        case .url:
            if let text = clip.text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let provider = NSItemProvider(object: url as NSURL)
                provider.registerObject(text as NSString, visibility: .all)
                return provider
            }
        case .text, .richText:
            break
        }
        return NSItemProvider(object: (clip.text ?? "") as NSString)
    }
}

/// Context menu shared by rows and strip cards.
struct ClipMenu: View {
    @ObservedObject var model: AppModel
    let clip: Clip

    var body: some View {
        Button("Copy") { model.clickCopy(clip) }
        Button("Paste") { model.paste(clip) }
        Button(clip.pinned ? "Unpin" : "Pin") { model.togglePin(clip) }
        if clip.kind == .files, let urls = clip.fileURLs {
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            if !model.targets.isEmpty {
                Menu("Copy to Sift Target") {
                    ForEach(model.targets) { target in
                        Button(target.name) { model.send(clip, to: target) }.disabled(!target.exists)
                    }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { model.remove(clip) }
    }
}
