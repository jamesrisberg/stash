import AppKit
import HUDKit
import StashKit
import SwiftUI

/// The `clips` desktop widget: the latest clips, small (one) or medium (three). A click
/// copies a clip back onto the clipboard through the app's click action. The per-instance
/// setting `pinnedOnly` (clips.widget.json) limits it to pinned clips.
enum ClipsWidget {
    static let type = "clips"
    static let pinnedOnlyKey = "pinnedOnly"

    /// A widget host serving the `clips` type. Keep it alive and set it as the router's
    /// `widgetHost` before the socket starts.
    @MainActor
    static func makeHost(model: AppModel, manifest: HUDManifest? = HUDManifest.main,
                         bundleURL: URL = Bundle.main.bundleURL) -> HUDWidgetHost {
        let host = HUDWidgetHost(manifest: manifest, bundleURL: bundleURL)
        host.register(type) { [weak model] context in
            if let model { ClipsWidgetView(model: model, context: context) }
        }
        return host
    }

    static func rowCount(for size: HUDWidgetSize) -> Int {
        size == .small ? 1 : 3
    }

    @MainActor
    static func clips(in model: AppModel, size: HUDWidgetSize, pinnedOnly: Bool) -> [Clip] {
        ClipsWidgetSelection.latest(model.clips, pinnedOnly: pinnedOnly, limit: rowCount(for: size))
    }

    static func emptyMessage(pinnedOnly: Bool) -> String {
        pinnedOnly ? "No pinned clips" : "Nothing copied yet"
    }

    /// What a tap does: the app's click-copy (no paste, no reorder, no new clip).
    @MainActor
    @discardableResult
    static func copy(_ clip: Clip, in model: AppModel) -> Bool {
        model.clickCopy(clip)
    }

    /// One line (or a few) of preview: the text of text-like clips, else the clip's title.
    static func preview(_ clip: Clip, limit: Int) -> String {
        switch clip.kind {
        case .text, .richText, .url:
            let text = clip.snippet(limit: limit)
            return text.isEmpty ? clip.title : text
        case .image, .files:
            return clip.title
        }
    }
}

struct ClipsWidgetView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var context: HUDWidgetContext

    private var pinnedOnly: Bool { context[ClipsWidget.pinnedOnlyKey]?.boolValue ?? false }

    var body: some View {
        let clips = ClipsWidget.clips(in: model, size: context.size, pinnedOnly: pinnedOnly)
        Group {
            if clips.isEmpty {
                empty
            } else if context.size == .small {
                SmallClip(model: model, clip: clips[0], copied: clips[0].id == model.copiedID, pinnedOnly: pinnedOnly)
            } else {
                VStack(spacing: 4) {
                    ForEach(clips) { clip in
                        ClipLine(model: model, clip: clip, copied: clip.id == model.copiedID)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: pinnedOnly ? "pin" : "list.clipboard")
                .font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
            Text(ClipsWidget.emptyMessage(pinnedOnly: pinnedOnly))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The small widget: the newest clip, with its type, age and a copy hint.
private struct SmallClip: View {
    @ObservedObject var model: AppModel
    let clip: Clip
    let copied: Bool
    let pinnedOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: clip.kind.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(clip.kind.tint)
                Text(ClipFormat.age(clip.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if clip.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
            }
            if clip.kind == .image || clip.kind == .files {
                ClipThumbnail(model: model, clip: clip, side: 64)
                Text(ClipsWidget.preview(clip, limit: 80))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            } else {
                Text(ClipsWidget.preview(clip, limit: 220))
                    .font(.system(size: 13))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Spacer(minLength: 0)
            CopyHint(copied: copied)
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture { ClipsWidget.copy(clip, in: model) }
    }
}

/// A medium widget row: type tile (thumbnail for images and files), preview, age.
private struct ClipLine: View {
    @ObservedObject var model: AppModel
    let clip: Clip
    let copied: Bool

    var body: some View {
        HStack(spacing: 9) {
            ClipThumbnail(model: model, clip: clip, side: 30, highlighted: copied)
            VStack(alignment: .leading, spacing: 1) {
                Text(ClipsWidget.preview(clip, limit: 80)).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Text(ClipFormat.age(clip.date)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if copied {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
            } else if clip.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(copied ? 0.16 : 0.07)))
        .contentShape(Rectangle())
        .onTapGesture { ClipsWidget.copy(clip, in: model) }
    }
}

private struct CopyHint: View {
    let copied: Bool
    var body: some View {
        if copied {
            Label("Copied", systemImage: "checkmark").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.green)
        } else {
            Text("Click to copy").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }
}
