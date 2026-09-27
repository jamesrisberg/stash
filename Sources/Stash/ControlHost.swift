import AppKit
import HUDKit
import StashKit

/// Stash's side of the MacHUD contract: serves the control socket at
/// `~/Library/Application Support/MacHUD/sockets/stash.sock` through HUDKit's router.
/// See docs/CONTRACT.md for the verbs.
@MainActor
final class ControlHost: HUDPanelHost {
    static let panelID = "history"
    static let actions = ["show", "hide", "toggle", "paste", "copy", "copy-clip", "search", "list", "pin", "delete", "clear"]

    /// Used when running outside a bundle (e.g. `swift run`); mirrors Sources/Stash/Resources/machud.json.
    static let builtinManifest = HUDManifest(id: AppModel.bundleID, name: "Stash", socket: "stash", panels: [
        HUDManifest.Panel(id: panelID, title: "Stash", symbol: "list.clipboard",
                          defaultSize: HUDSize(PanelController.fullSize), compactSize: HUDSize(PanelController.compactSize),
                          capabilities: ["providesDrag"],
                          verbs: ["show", "hide", "toggle", "frame", "mode", "paste"],
                          settingsSchema: "settings.json", kind: .hover, order: 2),
    ])

    let manifest: HUDManifest
    let server: HUDSocketServer
    private(set) var router: HUDControlRouter!
    private let model: AppModel
    private let panel: PanelController
    private let paste: (Clip, Bool) -> [String: Any]
    private var lastPublished: String?
    private var routerWillPublish = false
    /// New-clip state events: at most one a second, bursts collapse into one trailing event.
    private var throttle = EventThrottle(interval: 1)

    init(model: AppModel, panel: PanelController, paste: @escaping (Clip, Bool) -> [String: Any]) {
        self.model = model
        self.panel = panel
        self.paste = paste
        var manifest = HUDManifest.main ?? Self.builtinManifest
        if let socket = AppEnvironment.socketName { manifest.socket = socket }
        self.manifest = manifest
        server = HUDSocketServer(path: manifest.socketPath, label: "stash.socket")
        router = HUDControlRouter(host: self, server: server, manifest: manifest)
    }

    func start() {
        router.install()
        if !server.start() { NSLog("Stash: control socket failed to start at %@", server.path) }
        panel.onStateChange = { [weak self] in self?.publishIfChanged() }
        model.onClipsChange = { [weak self] in self?.clipsChangedThrottled() }
    }

    /// History changes (the badge) go out rate-limited.
    private func clipsChangedThrottled() {
        switch throttle.signal(now: Date()) {
        case .fire:
            publishIfChanged()
        case .schedule(let delay):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.throttle.firePending(now: Date())
                self.publishIfChanged()
            }
        case .coalesced:
            break
        }
    }

    /// Pushes `state` to subscribers when anything they can see changed.
    func publishIfChanged() {
        let signature = panelStates.map { "\($0.visible)|\($0.mode)|\($0.badge ?? "")|\($0.status ?? "")" }.joined()
        guard signature != lastPublished else { return }
        lastPublished = signature
        if !routerWillPublish { router.publishState() }
    }

    private func routed(_ body: () throws -> Void) rethrows {
        routerWillPublish = true
        defer { routerWillPublish = false }
        try body()
    }

    // MARK: - HUDPanelHost

    var panelDescriptors: [HUDManifest.Panel] { manifest.panels }

    var panelStates: [HUDPanelState] {
        let pinned = model.clips.filter(\.pinned).count
        var status = model.isPaused ? "paused" : "\(pinned) pinned"
        if !model.query.isEmpty { status += ", search: \(model.query)" }
        return [HUDPanelState(id: Self.panelID, visible: panel.isShown, mode: panel.mode,
                              badge: String(model.clips.count), status: status)]
    }

    private func check(_ id: String) throws {
        guard id == Self.panelID else { throw HUDControlError.noSuchPanel(id) }
    }

    func showPanel(_ id: String) throws { try check(id); routed { panel.show() } }
    func hidePanel(_ id: String) throws { try check(id); routed { panel.hide() } }

    /// MacHUD's dock: `from=`/`anchor=` slide out of the button, `reason=hover` is a quick
    /// fade that never takes focus, `reason=click|summon` focuses the panel.
    func showPanel(_ id: String, options: [String: String]) throws {
        try check(id)
        routed { panel.show(HUDPanelTransition(options)) }
    }

    /// `to=<edge>` slides back toward the dock in 0.1 s.
    func hidePanel(_ id: String, options: [String: String]) throws {
        try check(id)
        routed { panel.hide(HUDPanelTransition(options)) }
    }

    func setPanelFrame(_ id: String, frame: CGRect) throws {
        try check(id)
        guard frame.width >= 100, frame.height >= 40 else { throw HUDControlError.invalid("frame too small") }
        routed { panel.setFrame(frame) }
    }

    func setPanelMode(_ id: String, mode: HUDPanelMode) throws {
        try setPanelMode(id, mode: mode, options: HUDPanelModeOptions())
    }

    /// `parked` honours the edge/peek MacHUD passes (HUDKit 0.2) and remembers them.
    func setPanelMode(_ id: String, mode: HUDPanelMode, options: HUDPanelModeOptions) throws {
        try check(id)
        routed { panel.setMode(mode, options: options) }
    }

    // MARK: Settings

    func settings() -> [String: Any] { model.settings.json }

    func updateSettings(_ values: [String: String]) throws {
        let new: StashSettings
        do { new = try model.settings.applying(values) } catch { throw HUDControlError.invalid("\(error)") }
        try model.updateSettings(new)
    }

    // MARK: Actions

    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        do {
            switch name {
            case "show", "hide", "toggle":
                switch name {
                case "show": panel.show()
                case "hide": panel.hide()
                default: panel.isShown ? panel.hide() : panel.show()
                }
                done(["ok": true, "visible": panel.isShown])
            case "copy":
                guard let text = args["text"], !text.isEmpty else { throw HUDControlError.invalid("text= required") }
                let clip = model.copyText(text)
                done(["ok": true, "count": model.clips.count, "id": clip?.id.uuidString ?? ""])
            case "copy-clip":
                // What a click on a row does: copy only, no paste, no reorder, no new clip.
                let clip = try clip(at: args["index"] ?? "1")
                let ok = model.clickCopy(clip)
                done(["ok": ok, "copied": ok, "id": clip.id.uuidString, "title": clip.title,
                      "count": model.clips.count, "pasteboard": model.pasteboard.name.rawValue])
            case "paste":
                let clip = try clip(at: args["index"] ?? "1")
                done(paste(clip, true))
            case "search":
                let q = args["q"] ?? args["query"] ?? ""
                model.query = q
                let limit = Int(args["limit"] ?? "") ?? 20
                let hits = model.store.search(q)
                done(["ok": true, "total": hits.count, "results": hits.prefix(limit).map(describe)])
                publishIfChanged()
            case "list":
                let limit = Int(args["limit"] ?? "") ?? 20
                done(["ok": true, "total": model.clips.count, "results": model.clips.prefix(limit).map(describe)])
            case "pin":
                let clip = try clip(at: args["index"] ?? "")
                let on = args["on"].map { ["1", "true", "yes", "on"].contains($0.lowercased()) } ?? !clip.pinned
                model.store.setPinned(on, id: clip.id)
                done(["ok": true, "pinned": on])
            case "delete":
                let clip = try clip(at: args["index"] ?? "")
                model.remove(clip)
                done(["ok": true, "count": model.clips.count])
            case "clear":
                let all = ["1", "true", "yes"].contains((args["all"] ?? "").lowercased())
                model.clear(keepPinned: !all)
                done(["ok": true, "count": model.clips.count])
            default:
                throw HUDControlError.invalid("unknown action \(name) (\(Self.actions.joined(separator: ", ")))")
            }
        } catch {
            done(["ok": false, "error": "\(error)"])
        }
    }

    /// `index=` is 1-based over the history, newest first (the order `list` prints).
    private func clip(at raw: String) throws -> Clip {
        guard let n = Int(raw), n >= 1 else { throw HUDControlError.invalid("index= must be a number from 1") }
        guard n <= model.clips.count else { throw HUDControlError.invalid("index \(n) out of range (1-\(model.clips.count))") }
        return model.clips[n - 1]
    }

    private func describe(_ clip: Clip) -> [String: Any] {
        var d: [String: Any] = [
            "index": (model.clips.firstIndex(of: clip) ?? -1) + 1,
            "id": clip.id.uuidString, "kind": clip.kind.rawValue, "title": clip.title,
            "pinned": clip.pinned, "size": clip.size,
            "date": ISO8601DateFormatter().string(from: clip.date),
        ]
        if let source = clip.sourceBundleID { d["source"] = source }
        if let urls = clip.fileURLs { d["paths"] = urls.map { $0.path(percentEncoded: false) } }
        return d
    }

    func quit() { NSApp.terminate(nil) }
}
