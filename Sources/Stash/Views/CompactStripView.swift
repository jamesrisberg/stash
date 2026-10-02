import StashKit
import SwiftUI

/// Compact mode: the five newest clips as a horizontal strip. Click copies, double-click
/// pastes, ⌘-click pins, drag drops.
struct CompactStripView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.stripClips.isEmpty {
                Label("Nothing copied yet", systemImage: "list.clipboard")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(model.stripClips.enumerated()), id: \.element.id) { index, clip in
                    ClipCard(model: model, clip: clip, number: index + 1,
                             selected: clip.id == model.selectedID, copied: clip.id == model.copiedID)
                }
                Spacer(minLength: 0)
            }
            Button { model.setCompact(false) } label: {
                Image(systemName: "rectangle.expand.vertical").font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Full history")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One strip card, with its own hover state.
struct ClipCard: View {
    @ObservedObject var model: AppModel
    let clip: Clip
    let number: Int
    let selected: Bool
    let copied: Bool
    @State private var hovered = false

    var body: some View {
        let chrome = ClipRowChrome(hovered: hovered || model.forcedHoverID == clip.id, selected: selected, copied: copied)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: clip.kind.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(clip.kind.tint)
                    .brightness(chrome.iconHighlighted ? 0.18 : 0)
                Text(ClipFormat.age(clip.date)).font(.system(size: 9.5)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if clip.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.orange) }
                // The corner number gives way to a copy glyph (hover) or a green check (copied).
                if chrome.copied {
                    Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.green)
                } else if chrome.hovered {
                    Image(systemName: "doc.on.doc").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                } else {
                    Text("\(number)").font(.system(size: 9.5, weight: .semibold).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            if clip.kind == .image || clip.kind == .files {
                HStack(alignment: .center, spacing: 6) {
                    ClipThumbnail(model: model, clip: clip, side: 32, highlighted: chrome.iconHighlighted)
                    if clip.kind == .image, let size = clip.imageSize {
                        Text("\(Int(size.width))×\(Int(size.height))").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if clip.kind == .files {
                    Text(clip.title).font(.system(size: 10)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
            } else {
                Text(clip.snippet(limit: 120))
                    .font(.system(size: 11))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(width: 112, height: 82, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.07 + chrome.hoverLift)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1))
        .background(HoverTracker { hovered = $0 })
        .animation(.easeOut(duration: 0.1), value: hovered)
        .contentShape(Rectangle())
        .onTapGesture { model.click(clip) }
        .onDrag { ClipDrag.provider(for: clip, model: model) }
        .contextMenu { ClipMenu(model: model, clip: clip) }
        .help("\(clip.title)\nClick to copy · double-click to paste · ⌘-click to pin")
    }
}
