import AppKit
import Carbon
import HUDKit
import StashKit
import SwiftUI

/// The Snippets window: a normal (windowed) HUD window, opened from the menu bar menu, listing
/// snippets by collection with an editor beside the list. Windowed rather than part of the
/// hover panel because editing needs a window that stays put while the pointer moves away.
@MainActor
final class SnippetsWindow: NSObject {
    static let size = CGSize(width: 760, height: 500)
    static let style = HUDGlassView.Style(cornerRadius: 16, borderWidth: 0.5, borderAlpha: 0.22, gloss: false)

    let window: HUDPanelWindow
    private let host: NSView
    private let state: SnippetsViewState
    private var keyMonitor: Any?

    init(snippets: SnippetsController, model: AppModel) {
        window = HUDPanelWindow(contentRect: CGRect(origin: .zero, size: Self.size),
                                styleMask: HUDPanelWindow.windowedStyleMask.union(.resizable), backing: .buffered, defer: false)
        window.applyHUDRecipe(behavior: .windowed)
        window.title = "Stash Snippets"
        window.identifier = NSUserInterfaceItemIdentifier("xyz.machud.stash.snippets")
        window.minSize = NSSize(width: 560, height: 360)
        state = SnippetsViewState()
        let glass = HUDGlassView(style: Self.style)
        host = NSHostingView(rootView: SnippetsView(snippets: snippets, model: model, state: state,
                                                    close: { [weak window] in window?.orderOut(nil) })
            .environment(\.colorScheme, .dark))
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        window.contentView = glass
        super.init()
        window.center()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  Int(event.keyCode) == kVK_ANSI_W else { return event }
            self.window.orderOut(nil)
            return nil
        }
    }

    func show(selecting id: String? = nil, message: String? = nil) {
        if let id { state.selectedID = id }
        if let message { state.message = message }
        if !window.isVisible, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        }
        window.activateOnShow(HUDPanelTransition(reason: .summon))
    }

    func writeSnapshot(to url: URL) {
        ViewSnapshot.write(host, cornerRadius: Self.style.cornerRadius, to: url)
    }
}
