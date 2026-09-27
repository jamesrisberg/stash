import AppKit
import Combine
import FileKit
import StashKit

/// App state shared by the panel, the menu and the control socket.
@MainActor
final class AppModel: ObservableObject {
    static let bundleID = "xyz.machud.stash"

    /// Where the history, preferences and panel frames live.
    let directory: URL
    let store: ClipStore
    let settingsStore: SettingsStore
    let watcher: ClipboardWatcher
    let pasteboard: NSPasteboard
    let thumbnails = ThumbnailGenerator(size: CGSize(width: 96, height: 96))

    @Published private(set) var clips: [Clip] = []
    @Published private(set) var settings: StashSettings
    @Published var query = "" { didSet { if query != oldValue { selectFirst() } } }
    @Published var selectedID: UUID?
    @Published var isCompact = false
    @Published private(set) var hint: String?
    @Published var isPaused = false { didSet { watcher.isPaused = isPaused } }
    /// Bumped on every show so the search field takes focus.
    @Published private(set) var focusToken = 0
    /// The clip a click just copied; its row shows "Copied" until this clears (600 ms).
    @Published private(set) var copiedID: UUID?
    /// `--snapshot-hover <n>`: draws row n as hovered (the pointer cannot be synthesised offscreen).
    @Published var forcedHoverID: UUID?
    /// Sift's targets, for "Send to Sift target" on file clips.
    @Published private(set) var targets: [Target] = []

    /// A clip was recorded (from the pasteboard or `action copy`).
    var onNewClip: (() -> Void)?
    /// Anything in the history changed.
    var onClipsChange: (() -> Void)?
    /// Set by the app delegate: paste a clip into the previous app.
    var pasteHandler: ((Clip) -> Void)?
    /// Set by the app delegate: switch the panel to a mode.
    var modeHandler: ((Bool) -> Void)?

    func paste(_ clip: Clip) { pasteHandler?(clip) }
    func setCompact(_ compact: Bool) { modeHandler?(compact) }
    /// Set by the app delegate: dismiss (hide) the panel.
    var dismissHandler: (() -> Void)?
    func dismissPanel() { dismissHandler?() }

    private let imageCache = NSCache<NSUUID, NSImage>()
    private var appNames: [String: String] = [:]
    private var hintWork: DispatchWorkItem?
    private var copiedWork: DispatchWorkItem?
    static let copiedFeedbackSeconds = 0.6

    init(directory: URL = AppEnvironment.dataDirectory ?? ClipStore.defaultDirectory,
         pasteboard: NSPasteboard = AppEnvironment.pasteboard) {
        self.directory = directory
        settingsStore = SettingsStore(directory: directory)
        let loaded = settingsStore.load()
        settings = loaded
        store = ClipStore(directory: directory, cap: loaded.historyCap)
        self.pasteboard = pasteboard
        watcher = ClipboardWatcher(pasteboard: pasteboard, interval: loaded.pollInterval,
                                   ignoredBundleIDs: Set(loaded.ignoreList))
        do {
            try store.load()
        } catch {
            // Keep the unreadable file for the user (moved aside) and start empty.
            let aside = store.indexURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: store.indexURL, to: aside)
            NSLog("Stash: history unreadable (%@); moved to %@", error.localizedDescription, aside.path(percentEncoded: false))
            flash("History file was unreadable; kept as \(aside.lastPathComponent)", seconds: 6)
        }
        clips = store.clips
        store.onChange = { [weak self] in
            guard let self else { return }
            self.clips = self.store.clips
            if let id = self.selectedID, self.store.clip(id: id) == nil || !self.visibleOrder.contains(where: { $0.id == id }) {
                self.selectFirst()
            }
            self.onClipsChange?()
        }
        watcher.onClip = { [weak self] event in self?.record(event.payload, source: event.sourceBundleID, date: event.date) }
        watcher.onSkip = { reason in
            if reason == .secureInput || reason == .ignoredApp { NSLog("Stash: skipped a copy (%@)", reason.rawValue) }
        }
        targets = (try? TargetStore().load()) ?? []
        selectFirst()
    }

    func start() { watcher.start() }

    // MARK: - Lists

    var filtered: [Clip] { ClipStore.filter(clips, query: query) }
    var pinnedResults: [Clip] { filtered.filter(\.pinned) }
    var recentResults: [Clip] { filtered.filter { !$0.pinned } }
    /// Keyboard order: pinned section, then recent.
    var visibleOrder: [Clip] { pinnedResults + recentResults }
    /// Compact strip: the five newest clips.
    var stripClips: [Clip] { Array(clips.prefix(5)) }

    var selected: Clip? { selectedID.flatMap(store.clip(id:)) }

    /// Selects the newest clip (not a pinned one: Enter should paste what was just copied).
    func selectFirst() {
        selectedID = isCompact ? stripClips.first?.id : (recentResults.first ?? visibleOrder.first)?.id
    }

    func moveSelection(by delta: Int) {
        let order = isCompact ? stripClips : visibleOrder
        guard !order.isEmpty else { return }
        let current = selectedID.flatMap { id in order.firstIndex { $0.id == id } } ?? -1
        let next = current < 0 ? (delta > 0 ? 0 : order.count - 1) : min(max(current + delta, 0), order.count - 1)
        selectedID = order[next].id
    }

    func panelWillShow() {
        targets = (try? TargetStore().load()) ?? targets
        if selected == nil { selectFirst() }
        focusToken += 1
    }

    // MARK: - Recording

    private func record(_ payload: ClipPayload, source: String?, date: Date) {
        do {
            if try store.add(payload, source: source, date: date).isNew {
                selectFirst()
                onNewClip?()
            }
        } catch {
            NSLog("Stash: could not record clip: %@", error.localizedDescription)
        }
    }

    /// `action copy text=`: records the text and puts it on the pasteboard.
    @discardableResult
    func copyText(_ text: String) -> Clip? {
        ClipReader.write(text: text, to: pasteboard)
        watcher.skipCurrent()
        record(.text(text), source: Self.bundleID, date: Date())
        return store.clips.first
    }

    // MARK: - Clip actions

    /// Puts the clip on the pasteboard and moves it to the top (Enter, ⌘C, paste).
    @discardableResult
    func copy(_ clip: Clip) -> Bool {
        let ok = write(clip)
        if ok { store.promote(id: clip.id) }
        selectedID = clip.id
        return ok
    }

    /// A click on a row or card: puts the clip on the pasteboard and flags the row "Copied"
    /// for 600 ms. Never pastes, never hides the panel, and leaves the order alone (the
    /// watcher skips Stash's own write, so the clip is not recorded again either).
    @discardableResult
    func clickCopy(_ clip: Clip) -> Bool {
        let ok = write(clip)
        selectedID = clip.id
        guard ok else { flash("Could not copy that clip", seconds: 4); return false }
        copiedID = clip.id
        copiedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if self?.copiedID == clip.id { self?.copiedID = nil }
        }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedFeedbackSeconds, execute: work)
        return true
    }

    /// Writes a clip (with Stash's marker) and marks the change as seen, so the watcher
    /// never records Stash's own copy as a new clip.
    private func write(_ clip: Clip) -> Bool {
        let ok = ClipReader.write(clip, blobURL: store.blobURL(for: clip), to: pasteboard)
        watcher.skipCurrent()
        return ok
    }

    /// What a click does, by modifier and click count: ⌘-click pins, a double click pastes,
    /// anything else copies.
    enum ClickAction: Equatable { case copy, paste, togglePin }

    static func clickAction(clickCount: Int, modifiers: NSEvent.ModifierFlags) -> ClickAction {
        if modifiers.contains(.command) { return .togglePin }
        return clickCount >= 2 ? .paste : .copy
    }

    /// Runs the click action for the current mouse event.
    func click(_ clip: Clip, event: NSEvent? = NSApp.currentEvent) {
        let mouse = event.flatMap { [.leftMouseUp, .leftMouseDown].contains($0.type) ? $0 : nil }
        switch Self.clickAction(clickCount: mouse?.clickCount ?? 1,
                                modifiers: mouse?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []) {
        case .copy: clickCopy(clip)
        case .paste: paste(clip)
        case .togglePin: togglePin(clip)
        }
    }

    func remove(_ clip: Clip) {
        let order = visibleOrder
        let next = order.firstIndex(of: clip).flatMap { i in order.indices.contains(i + 1) ? order[i + 1] : (i > 0 ? order[i - 1] : nil) }
        store.remove(id: clip.id)
        selectedID = next?.id ?? visibleOrder.first?.id
    }

    func togglePin(_ clip: Clip) {
        store.togglePin(id: clip.id)
        selectedID = clip.id
    }

    func clear(keepPinned: Bool = true) {
        store.clear(keepPinned: keepPinned)
        imageCache.removeAllObjects()
        selectFirst()
    }

    /// Copies a file clip's files into a Sift target through FileKit (never moves: the
    /// clipboard refers to the originals).
    func send(_ clip: Clip, to target: Target) {
        guard let urls = clip.fileURLs, !urls.isEmpty else { return }
        do {
            let ops = try FileActionService().copy(urls, into: target.url, onCollision: .keepBoth)
            flash("Copied \(ops.count) item\(ops.count == 1 ? "" : "s") to \(target.name)")
        } catch {
            flash("Could not copy to \(target.name): \(error.localizedDescription)", seconds: 5)
        }
    }

    // MARK: - Settings

    func updateSettings(_ new: StashSettings) throws {
        try settingsStore.save(new)
        settings = new
        store.cap = new.historyCap
        watcher.interval = new.pollInterval
        watcher.ignoredBundleIDs = Set(new.ignoreList)
    }

    // MARK: - Presentation helpers

    func flash(_ message: String, seconds: Double = 3) {
        hint = message
        hintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hint = nil }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func image(for clip: Clip) -> NSImage? {
        guard clip.kind == .image, let url = store.blobURL(for: clip) else { return nil }
        if let hit = imageCache.object(forKey: clip.id as NSUUID) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: clip.id as NSUUID)
        return image
    }

    func appName(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if bundleID == Self.bundleID { return "Stash" }
        if let name = appNames[bundleID] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path(percentEncoded: false)) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        appNames[bundleID] = name ?? bundleID
        return name ?? bundleID
    }

    func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }
}
