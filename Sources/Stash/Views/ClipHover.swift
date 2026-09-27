import AppKit
import SwiftUI

/// How a clip row or strip card looks for its hover, selection and just-copied state.
/// Pure so the rules are testable; the views only read it.
struct ClipRowChrome: Equatable {
    var hovered = false
    var selected = false
    var copied = false

    /// Hover lift (white 8%) when not selected; selection keeps its accent fill.
    var hoverLift: Double { hovered && !selected ? 0.08 : 0 }
    /// The type icon brightens under the pointer (and while "Copied" shows).
    var iconHighlighted: Bool { hovered || copied }
    /// The trailing hint: "Copied" wins, else the click hint while hovered.
    var hint: String? {
        if copied { return Self.copiedText }
        return hovered ? Self.hoverText : nil
    }
    var showsHint: Bool { hint != nil }

    static let hoverText = "Click to copy · ⏎ paste"
    static let copiedText = "Copied"
}

/// Hover tracking through an `NSTrackingArea` with `.activeAlways`: the panel is a
/// non-activating HUD panel that is often not key, where SwiftUI hover and cursor rects
/// can lag or not fire. Each row owns one, so a hover only re-renders that row. The pointer
/// becomes a hand while inside.
struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var inside = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil } // never takes clicks

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self))
            // A row that scrolls under a still pointer (or appears under it) updates too.
            if let window, window.isVisible {
                let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                set(bounds.contains(p))
            }
        }

        override func mouseEntered(with event: NSEvent) { set(true) }
        override func mouseMoved(with event: NSEvent) { if inside { NSCursor.pointingHand.set() } }
        override func mouseExited(with event: NSEvent) { set(false) }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { set(false) }
            super.viewWillMove(toWindow: newWindow)
        }

        private func set(_ value: Bool) {
            guard value != inside else { return }
            inside = value
            (value ? NSCursor.pointingHand : NSCursor.arrow).set()
            onChange?(value)
        }
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }
}

/// The trailing "Click to copy · ⏎ paste" / "✓ Copied" pill.
struct ClipHint: View {
    let chrome: ClipRowChrome

    var body: some View {
        Group {
            if chrome.copied {
                Label(ClipRowChrome.copiedText, systemImage: "checkmark")
                    .foregroundStyle(.green)
            } else {
                Text(ClipRowChrome.hoverText).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        // Near-opaque, so the preview text it sits over reads as tucked underneath.
        .background(Capsule().fill(Color(white: 0.12).opacity(0.96)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .opacity(chrome.showsHint ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: chrome)
        .allowsHitTesting(false)
    }
}
