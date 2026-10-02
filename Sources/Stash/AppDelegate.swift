import AppKit
import HUDKit
import StashKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var control: ControlHost!
    private var widgets: HUDWidgetHost!
    static let hotKey = HUDHotKey(key: "v", modifiers: ["control", "option"])

    func applicationDidFinishLaunching(_ notification: Notification) {
        HUDEditMenu.install(appName: "Stash")
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }

        // `--demo`: sample clips for pictures. Never mixes with the real history: without
        // STASH_HOME it uses a throwaway folder, and it always uses a private pasteboard.
        let demo = args.contains("--demo")
        if demo {
            let dir = AppEnvironment.dataDirectory
                ?? FileManager.default.temporaryDirectory.appending(path: "StashDemo-\(ProcessInfo.processInfo.processIdentifier)")
            model = AppModel(directory: dir, pasteboard: NSPasteboard(name: NSPasteboard.Name("xyz.machud.stash.demo")))
            DemoClips.seed(model)
        } else {
            model = AppModel()
        }
        // Frames live next to the history. An instance isolated some other way (socket or
        // pasteboard only) shares the user's data folder, so it keeps none.
        let frames = AppEnvironment.isIsolated && AppEnvironment.dataDirectory == nil && !demo ? nil
            : PanelFrameStore(directory: model.directory)
        panel = PanelController(model: model, frames: frames)
        panel.onPaste = { [weak self] clip in self?.pasteFromPanel(clip) }
        model.pasteHandler = { [weak self] clip in self?.pasteFromPanel(clip) }
        model.modeHandler = { [weak self] compact in self?.panel.setMode(compact ? .compact : .full) }
        model.dismissHandler = { [weak self] in self?.panel.hide() }
        control = ControlHost(model: model, panel: panel) { [weak self] clip, _ in
            self?.pasteToFrontmost(clip) ?? ["ok": false, "error": "app gone"]
        }
        // Desktop widgets: set before the socket starts, MacHUD syncs its instances on connect.
        widgets = ClipsWidget.makeHost(model: model, manifest: control.manifest)
        control.router.widgetHost = widgets
        // A snapshot run only draws: no control socket (a running app owns that name), no
        // announcement, no clipboard watcher (it would record into the real history beside the
        // running app), no hotkey, no menu bar item.
        let snapshotting = value("--snapshot") != nil || value("--snapshot-widgets") != nil
        if !snapshotting {
            control.start()
            model.start()
            setupStatusItem()
            // While MacHUD runs, its menu hosts this one and the icon hides (HUDKit menu bar consolidation).
            control.router.menuProvider = { [weak self] in self?.statusItem?.menu }
            // menuBar.consumed is kept in <data directory>/menubar.json, so STASH_HOME isolates it too.
            HUDStatusItemPolicy.attach(statusItem, appID: control.manifest.id,
                                       store: .home(AppEnvironment.dataDirectory ?? ClipStore.defaultDirectory))
            if !AppEnvironment.noHotKeys,
               HUDHotKeyCenter.shared.register(Self.hotKey, onPress: { [weak self] in self?.panel.toggle() }) == nil {
                model.flash("⌃⌥V is taken by another app; use the menu bar icon", seconds: 8)
            }
        }

        // First launch shows the panel so the user sees something happen.
        let firstLaunch = !UserDefaults.standard.bool(forKey: "StashLaunchedBefore")
        if firstLaunch, !AppEnvironment.isIsolated { UserDefaults.standard.set(true, forKey: "StashLaunchedBefore") }
        if firstLaunch || args.contains("--show") || value("--snapshot") != nil { panel.show() }

        // `--snapshot-widgets <dir>`: PNGs of the clips widget at each size, all clips and
        // pinned only (clips-small.png, clips-medium-pinned.png, ...). Use with `--demo`.
        if let dir = value("--snapshot-widgets") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.writeWidgetSnapshots(to: URL(filePath: dir))
                if args.contains("--snapshot-quit") { NSApp.terminate(nil) }
            }
        }

        // `--snapshot <path.png>`: write a PNG of the panel after it settles (for docs and for
        // checking the UI without Screen Recording permission). `--snapshot-mode compact`
        // pictures the strip; `--snapshot-query <q>` a search; `--snapshot-hover <n>` a hovered clip.
        if let path = value("--snapshot") {
            if value("--snapshot-mode") == "compact" { panel.setMode(.compact) }
            if let q = value("--snapshot-query") { model.query = q }
            // `--snapshot-hover <n>`: draw the nth clip (1 = newest) as hovered.
            if let n = value("--snapshot-hover").flatMap(Int.init), model.clips.indices.contains(n - 1) {
                model.forcedHoverID = model.clips[n - 1].id
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.panel.writeSnapshot(to: URL(filePath: path))
                if args.contains("--snapshot-quit") { NSApp.terminate(nil) }
            }
        }
    }

    private func writeWidgetSnapshots(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for size in [HUDWidgetSize.small, .medium] {
            for pinnedOnly in [false, true] {
                let name = "\(ClipsWidget.type)-\(size.rawValue)\(pinnedOnly ? "-pinned" : "").png"
                let settings: [String: HUDSettingValue] = pinnedOnly ? [ClipsWidget.pinnedOnlyKey: .bool(true)] : [:]
                do {
                    try widgets.writeSnapshot(type: ClipsWidget.type, size: size, settings: settings, to: dir.appending(path: name))
                    print(dir.appending(path: name).path(percentEncoded: false))
                } catch {
                    NSLog("Stash: widget snapshot %@ failed: %@", name, "\(error)")
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return true
    }

    // MARK: - Paste

    /// Whether a simulated ⌘V would paste what Stash wrote (not with a private pasteboard).
    private var canSimulatePaste: Bool { AppEnvironment.pasteboardName == nil && model.pasteboard == .general }

    /// Enter in the panel: copy, then (if enabled and permitted) hide and ⌘V into the app
    /// that was frontmost when the panel opened.
    private func pasteFromPanel(_ clip: Clip) {
        guard model.copy(clip) else { model.flash("Could not copy that clip", seconds: 4); return }
        guard model.settings.pasteOnEnter else {
            model.flash("Copied")
            panel.hide()
            return
        }
        guard canSimulatePaste else {
            model.flash("Copied to the private pasteboard \(model.pasteboard.name.rawValue)")
            return
        }
        guard Paster.isTrusted else {
            model.flash("Copied. Grant Accessibility (menu bar icon) to paste automatically.", seconds: 6)
            return
        }
        let target = panel.previousApp
        panel.hide()
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { Paster.postCommandV() }
    }

    /// `action paste index=`: copy, then ⌘V into whatever is frontmost.
    private func pasteToFrontmost(_ clip: Clip) -> [String: Any] {
        guard model.copy(clip) else { return ["ok": false, "error": "could not copy clip"] }
        var r: [String: Any] = ["ok": true, "copied": true, "title": clip.title]
        if !canSimulatePaste {
            r["pasted"] = false
            r["hint"] = "private pasteboard in use; copied only"
        } else if !Paster.isTrusted {
            r["pasted"] = false
            r["hint"] = "grant Accessibility to Stash to paste; copied only"
        } else {
            if panel.isShown { panel.hide() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Paster.postCommandV() }
            r["pasted"] = true
        }
        return r
    }

    // MARK: - Status item

    private enum Tag: Int { case compact = 1, pause, accessibility, pasteOnEnter }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = HUDStatusIcon.image(fallbackSymbol: "list.clipboard", accessibilityDescription: "Stash")

        let menu = NSMenu()
        menu.delegate = self
        let toggle = NSMenuItem(title: "Show Stash", action: #selector(togglePanel), keyEquivalent: "v")
        toggle.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggle)
        let compact = NSMenuItem(title: "Compact Strip", action: #selector(toggleCompact), keyEquivalent: "")
        compact.tag = Tag.compact.rawValue
        menu.addItem(compact)
        menu.addItem(.separator())
        let pause = NSMenuItem(title: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
        pause.tag = Tag.pause.rawValue
        menu.addItem(pause)
        let enter = NSMenuItem(title: "Enter Pastes into Previous App", action: #selector(togglePasteOnEnter), keyEquivalent: "")
        enter.tag = Tag.pasteOnEnter.rawValue
        menu.addItem(enter)
        let ax = NSMenuItem(title: "Grant Accessibility…", action: #selector(grantAccessibility), keyEquivalent: "")
        ax.tag = Tag.accessibility.rawValue
        menu.addItem(ax)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear History (Keep Pinned)", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal History Folder", action: #selector(revealData), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Stash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch Tag(rawValue: item.tag) {
            case .compact: item.state = panel.mode == .compact ? .on : .off
            case .pause: item.state = model.isPaused ? .on : .off
            case .pasteOnEnter: item.state = model.settings.pasteOnEnter ? .on : .off
            case .accessibility: item.isHidden = Paster.isTrusted
            case nil: break
            }
            if item.action == #selector(togglePanel) { item.title = panel.isVisible ? "Hide Stash" : "Show Stash" }
        }
    }

    @objc private func togglePanel() { panel.toggle() }
    @objc private func toggleCompact() { panel.setMode(panel.mode == .compact ? .full : .compact) }
    @objc private func togglePause() {
        model.isPaused.toggle()
        control.publishIfChanged()
    }
    @objc private func togglePasteOnEnter() {
        var s = model.settings
        s.pasteOnEnter.toggle()
        try? model.updateSettings(s)
    }
    @objc private func grantAccessibility() {
        Paster.requestAccess()
        if !Paster.isTrusted { Paster.openSettings() }
    }
    @objc private func clearHistory() { model.clear(keepPinned: true) }
    @objc private func revealData() {
        let dir = model.store.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
