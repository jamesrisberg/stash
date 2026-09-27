import AppKit
import Carbon
import HUDKit
import StashKit
import SwiftUI

/// Owns the panel window: visibility, the full / compact / parked modes (via HUDKit's
/// parking helpers), frames (including frames MacHUD assigns over the socket), keyboard
/// handling and snapshots.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let fullSize = CGSize(width: 460, height: 560)
    static let compactSize = CGSize(width: 640, height: 104)
    static let fullStyle = HUDGlassView.Style(cornerRadius: 16, borderWidth: 0.5, borderAlpha: 0.22, gloss: false)
    static let compactStyle = HUDGlassView.Style(cornerRadius: 20, borderWidth: 0.5, borderAlpha: 0.2, gloss: true)

    let model: AppModel
    let panel: HUDPanelWindow
    /// Nil when frames must not be kept (an isolated instance without its own `STASH_HOME`).
    private let frames: PanelFrameStore?
    private let glass: HUDGlassView
    private let host: NSView
    private var keyMonitor: Any?

    private(set) var mode: HUDPanelMode = .full
    private var modeBeforeParking: HUDPanelMode = .full
    private var restFrame: CGRect?
    /// The edge and peek to park at (MacHUD's, once it has named them).
    private(set) var parking = ParkingSpot(peek: 14)
    /// Whether the panel is meant to be on screen (tracked separately from `isVisible`,
    /// which stays true during the fade-out).
    private(set) var isShown = false
    private var isAdjustingFrame = false
    /// The app that was frontmost when the panel opened; paste goes back to it.
    private(set) var previousApp: NSRunningApplication?

    /// Visibility, mode or frame changed (for `state` events).
    var onStateChange: (() -> Void)?
    /// Enter on a clip (a double click goes through `AppModel.paste`).
    var onPaste: ((Clip) -> Void)?

    /// Show/hide slides and fades (durations by MacHUD's `reason=`, see `PanelMotionPlan`).
    private var motion: PanelMotion!
    /// The frame MacHUD assigned with `panel frame`; shows rest there. Cleared when the user
    /// moves the panel themselves.
    private(set) var assignedFrame: CGRect?

    init(model: AppModel, frames: PanelFrameStore?) {
        self.model = model
        self.frames = frames
        panel = HUDPanelWindow(contentRect: CGRect(origin: .zero, size: Self.fullSize),
                               styleMask: HUDPanelWindow.recipeStyleMask.union(.resizable), backing: .buffered, defer: false)
        glass = HUDGlassView(style: Self.fullStyle)
        let root = RootView(model: model)
        host = NSHostingView(rootView: root)
        super.init()

        panel.keyable = true
        panel.applyHUDRecipe()
        panel.title = "Stash"
        panel.identifier = NSUserInterfaceItemIdentifier("xyz.machud.stash.history")
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 340, height: 300)
        panel.delegate = self

        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        panel.contentView = glass
        motion = PanelMotion(window: panel)

        if let saved = frames?.frame(for: .full) {
            panel.setFrame(saved, display: false)
        } else {
            centerOnMouseScreen()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    var isVisible: Bool { isShown }

    // MARK: - Visibility

    func show() { show(HUDPanelTransition()) }

    /// Shows the panel, sliding out of `transition.from` when MacHUD names the dock edge.
    /// `reason=hover` is a quick fade that never takes key; anything else focuses the panel.
    func show(_ transition: HUDPanelTransition) {
        if mode == .parked { return unpark() }
        let plan = PanelMotionPlan.show(transition)
        if !isShown, plan.takesKey, let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        if assignedFrame == nil, transition.anchor == nil,
           !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { centerOnMouseScreen() }
        let current = isShown ? (motion.restFrame ?? panel.frame) : panel.frame
        let rest = PanelMotionPlan.restFrame(assigned: assignedFrame, transition: transition, current: current)
        let wasShown = isShown
        isShown = true
        model.panelWillShow()
        motion.show(at: rest, plan: plan)
        if !wasShown { onStateChange?() }
    }

    func hide() { hide(HUDPanelTransition()) }

    /// Hides the panel; `transition.to` slides it back toward the dock (0.1 s).
    func hide(_ transition: HUDPanelTransition) {
        guard isShown else { return }
        isShown = false
        if mode == .parked, let restFrame {
            mode = modeBeforeParking
            setFrameQuietly(restFrame)
            self.restFrame = nil
        }
        motion.hide(plan: .hide(transition))
        onStateChange?()
    }

    func toggle() {
        if mode == .parked { return unpark() }
        isShown && panel.isKeyWindow ? hide() : show()
    }

    // MARK: - Modes

    /// `options` carry the edge/peek MacHUD parks at; they only matter for `.parked`.
    func setMode(_ newMode: HUDPanelMode, options: HUDPanelModeOptions = HUDPanelModeOptions()) {
        switch newMode {
        case .parked:
            park(options)
        case .full, .compact:
            if mode == .parked { unpark(to: newMode) } else { apply(newMode) }
            if !isShown { show() }
        }
        onStateChange?()
    }

    private func apply(_ newMode: HUDPanelMode) {
        guard newMode != mode else { return }
        saveCurrentFrame()
        mode = newMode
        model.isCompact = newMode == .compact
        model.selectFirst()
        glass.style = newMode == .compact ? Self.compactStyle : Self.fullStyle
        if newMode == .compact {
            panel.styleMask.remove(.resizable)
            panel.minSize = NSSize(width: 300, height: Self.compactSize.height)
            setFrameQuietly(frames?.frame(for: .compact) ?? defaultCompactFrame(), animate: isShown)
        } else {
            panel.styleMask.insert(.resizable)
            panel.minSize = NSSize(width: 340, height: 300)
            setFrameQuietly(frames?.frame(for: .full) ?? defaultFullFrame(), animate: isShown)
        }
        panel.invalidateShadow()
    }

    private func park(_ options: HUDPanelModeOptions) {
        let moved = parking.update(with: options)
        if mode == .parked {
            // Already parked: move to the newly requested edge or peek.
            if moved, let restFrame { setFrameQuietly(parking.offScreenFrame(for: restFrame)) }
            return
        }
        if !isShown { show() }
        motion.cancel()
        modeBeforeParking = mode
        restFrame = panel.frame
        mode = .parked
        let edge = parking.edge(for: panel.frame, in: HUDParking.screenFrame(for: panel.frame))
        isAdjustingFrame = true
        HUDParking.slideOut(panel, edge: edge, peek: parking.peek) { [weak self] in self?.isAdjustingFrame = false }
    }

    private func unpark(to target: HUDPanelMode? = nil) {
        guard mode == .parked else { return }
        let rest = restFrame ?? panel.frame
        mode = modeBeforeParking
        restFrame = nil
        isShown = true
        isAdjustingFrame = true
        HUDParking.slideIn(panel, to: rest) { [weak self] in
            guard let self else { return }
            self.isAdjustingFrame = false
            if let target, target != self.mode { self.apply(target) }
            self.panel.makeKey()
            self.onStateChange?()
        }
    }

    /// Cooperative placement from MacHUD (`panel frame`), kept as the frame for the current mode.
    func setFrame(_ frame: CGRect) {
        assignedFrame = frame
        if mode == .parked {
            restFrame = frame
            setFrameQuietly(parking.offScreenFrame(for: frame))
            return
        }
        setFrameQuietly(frame)
        if isShown { motion.setRestFrame(frame) }
        saveCurrentFrame()
        onStateChange?()
    }

    private func setFrameQuietly(_ frame: CGRect, animate: Bool = false) {
        isAdjustingFrame = true
        panel.setFrame(frame, display: true, animate: animate)
        isAdjustingFrame = false
    }

    // MARK: - Keyboard

    /// Arrows move, Enter pastes, ⌘C copies, ⌘P pins, Delete removes (⌘Delete always; plain
    /// Delete when the search field is empty), Escape clears the search or closes.
    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = mods.contains(.command)
        switch Int(event.keyCode) {
        case kVK_DownArrow: model.moveSelection(by: 1); return true
        case kVK_UpArrow: model.moveSelection(by: -1); return true
        case kVK_RightArrow where model.isCompact: model.moveSelection(by: 1); return true
        case kVK_LeftArrow where model.isCompact: model.moveSelection(by: -1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let clip = model.selected { onPaste?(clip) }
            return true
        case kVK_Escape:
            if !model.query.isEmpty { model.query = "" } else { hide() }
            return true
        case kVK_Delete, kVK_ForwardDelete:
            guard command || model.query.isEmpty, let clip = model.selected else { return false }
            model.remove(clip)
            return true
        case kVK_ANSI_P where command:
            if let clip = model.selected { model.togglePin(clip) }
            return true
        case kVK_ANSI_C where command:
            // Copy the selected clip unless text is selected in the search field.
            if let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length > 0 { return false }
            if let clip = model.selected, model.copy(clip) { model.flash("Copied") }
            return true
        case kVK_ANSI_W where command:
            hide()
            return true
        default:
            return false
        }
    }

    // MARK: - Frames

    private func saveCurrentFrame() {
        frames?.save(panel.frame, for: mode)
    }

    private func defaultFullFrame() -> CGRect {
        let full = panel.frame
        let frame = CGRect(x: full.midX - Self.fullSize.width / 2, y: full.maxY - Self.fullSize.height,
                           width: Self.fullSize.width, height: Self.fullSize.height)
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
        return HUDParking.restFrame(for: frame, in: visible)
    }

    /// The strip starts centred under the top edge of where the full panel was.
    private func defaultCompactFrame() -> CGRect {
        let full = panel.frame
        let frame = CGRect(x: full.midX - Self.compactSize.width / 2, y: full.maxY - Self.compactSize.height,
                           width: Self.compactSize.width, height: Self.compactSize.height)
        return HUDParking.restFrame(for: frame, in: HUDParking.screenFrame(for: full))
    }

    func windowDidMove(_ notification: Notification) {
        guard !isAdjustingFrame, !motion.isAnimating, !panel.inLiveResize else { return }
        userPlaced()
    }

    func windowDidEndLiveResize(_ notification: Notification) { userPlaced() }

    /// The user dragged or resized the panel: that frame wins over MacHUD's until it assigns another.
    private func userPlaced() {
        assignedFrame = nil
        motion.userMovedWindow()
        saveCurrentFrame()
    }

    private func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }

    // MARK: - Snapshot

    /// Writes a PNG of the panel. The glass blurs what is behind the window, which a view
    /// cache cannot capture, so the content is composited on a dark stand-in with the
    /// panel's corners and hairline border (same approach as Sift).
    func writeSnapshot(to url: URL) {
        let view = host
        let scale = panel.backingScaleFactor
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let radius = (mode == .compact ? Self.compactStyle : Self.fullStyle).cornerRadius
        let rect = CGRect(origin: .zero, size: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.withAlphaComponent(0.22).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            NSLog("Stash: wrote snapshot %@", url.path(percentEncoded: false))
        } catch {
            NSLog("Stash: snapshot failed: %@", error.localizedDescription)
        }
    }
}
