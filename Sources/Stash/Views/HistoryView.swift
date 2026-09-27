import AppKit
import StashKit
import SwiftUI

/// Full panel: search field, pinned section, recent clips, key hints.
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.4)
            if model.clips.isEmpty {
                empty("Nothing copied yet", "Copy something and it appears here.", symbol: "list.clipboard")
            } else if model.visibleOrder.isEmpty {
                empty("No matches", "Nothing in the history contains \u{201C}\(model.query)\u{201D}.", symbol: "magnifyingglass")
            } else {
                list
            }
            Divider().opacity(0.4)
            footer
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { searchFocused = true }
    }

    /// The header: a slim grip strip over the search row. The whole header drags the panel
    /// (the search field and buttons keep their clicks); ✕ dismisses it.
    private var searchBar: some View {
        VStack(spacing: 0) {
            Capsule().fill(.white.opacity(0.22)).frame(width: 36, height: 4)
                .frame(maxWidth: .infinity).frame(height: 12)
                .padding(.top, 2)
                .help("Drag to move")
            searchRow
        }
        .background(WindowDragArea())
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search clips", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text("\(model.clips.count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(.white.opacity(0.1)))
                .foregroundStyle(.secondary)
                .help("Clips in history")
            Button { model.setCompact(true) } label: { Image(systemName: "rectangle.compress.vertical") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Compact strip")
            Button { model.dismissPanel() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Close (esc)")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !model.pinnedResults.isEmpty {
                        header("Pinned", symbol: "pin.fill")
                        ForEach(model.pinnedResults) { row($0) }
                    }
                    if !model.recentResults.isEmpty {
                        header("Recent", symbol: "clock")
                        ForEach(model.recentResults) { row($0) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: model.selectedID) {
                if let id = model.selectedID { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
            }
        }
    }

    private func header(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(_ clip: Clip) -> some View {
        // One tap gesture, dispatched on the event's click count and modifiers: waiting for a
        // possible double click would delay every single-click copy.
        ClipRow(model: model, clip: clip, selected: clip.id == model.selectedID,
                copied: clip.id == model.copiedID)
            .id(clip.id)
            .contentShape(Rectangle())
            .onTapGesture { model.click(clip) }
            .onDrag { ClipDrag.provider(for: clip, model: model) }
            .contextMenu { ClipMenu(model: model, clip: clip) }
    }

    private func empty(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let hint = model.hint {
                Label(hint, systemImage: "info.circle").lineLimit(2)
            } else if model.isPaused {
                Label("Recording paused", systemImage: "pause.circle")
            } else {
                // The drag hint drops out first when the panel is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { keyHints; Spacer(minLength: 8); Text("drag out").foregroundStyle(.tertiary).fixedSize() }
                    HStack(spacing: 10) { keyHints; Spacer(minLength: 0) }
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var keyHints: some View {
        keyHint("click", "copy")
        keyHint("↩", model.settings.pasteOnEnter ? "paste" : "copy")
        keyHint("⌘click", "pin")
        keyHint("⌫", "delete")
        keyHint("esc", "close")
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10.5, weight: .semibold))
                .fixedSize()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
            Text(label)
        }
        .fixedSize()
    }
}

/// Drags the borderless panel from wherever SwiftUI content does not take the click.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        // The panel never activates Stash, so the first click must already drag.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ClipRow: View {
    @ObservedObject var model: AppModel
    let clip: Clip
    let selected: Bool
    var copied = false
    /// Per-row, so a hover re-renders this row only.
    @State private var hovered = false

    private var chrome: ClipRowChrome {
        ClipRowChrome(hovered: hovered || model.forcedHoverID == clip.id, selected: selected, copied: copied)
    }

    var body: some View {
        let chrome = chrome
        return HStack(spacing: 10) {
            ClipThumbnail(model: model, clip: clip, side: 36, highlighted: chrome.iconHighlighted)
            VStack(alignment: .leading, spacing: 3) {
                Text(preview)
                    .font(clip.kind == .text && looksLikeCode ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                HStack(spacing: 5) {
                    Text(clip.kind.label).foregroundStyle(clip.kind.tint)
                    if let app = model.appName(clip.sourceBundleID) { Text("· \(app)") }
                    Text("· \(ClipFormat.age(clip.date))")
                    if clip.kind != .text && clip.kind != .url && clip.size > 0 { Text("· \(ClipFormat.size(clip.size))") }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if clip.pinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.orange).rotationEffect(.degrees(35))
                    .opacity(chrome.showsHint ? 0 : 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .trailing) { ClipHint(chrome: chrome).padding(.trailing, 8) }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.32) : Color.white.opacity(chrome.hoverLift))
        )
        .background(HoverTracker { hovered = $0 })
        .animation(.easeOut(duration: 0.1), value: hovered)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
    }

    private var preview: String {
        switch clip.kind {
        case .text, .richText:
            let t = (clip.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let collapsed = t.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .prefix(3).joined(separator: " ⏎ ")
            return collapsed.count > 300 ? String(collapsed.prefix(300)) + "…" : collapsed
        case .files:
            let urls = clip.fileURLs ?? []
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files: " + urls.map(\.lastPathComponent).joined(separator: ", ")
        case .url, .image:
            return clip.title
        }
    }

    private var looksLikeCode: Bool {
        let t = clip.text ?? ""
        return t.contains("{") || t.contains(";") || t.contains("func ") || t.contains("=>") || t.hasPrefix("$ ")
    }
}
