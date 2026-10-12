import AppKit
import Combine
import HUDKit
import StashKit

/// Snippets: the store, the Alfred import, keyword expansion and the `snippets` socket verb
/// (see docs/CONTRACT.md). Expansion follows the `snippetExpansion` setting; the key tap and
/// the system driver are the only parts that touch the keyboard, and tests replace both.
@MainActor
final class SnippetsController: ObservableObject {
    static let command = "snippets"
    static let actions = ["list", "insert", "import-alfred", "expansion"]
    static let defaultListLimit = 50
    /// Gives the key that completed a keyword time to reach the app before it is deleted.
    static let expansionDelay: TimeInterval = 0.02
    /// Gives MacHUD's search bar time to close and hand focus back before `insert` pastes.
    static let insertDelay: TimeInterval = 0.12

    let store: SnippetStore
    let engine = SnippetExpansionEngine()
    let alfredFolder: URL
    private let model: AppModel
    private let driver: SnippetInsertionDriver

    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var collections: [String] = []
    /// Whether the key tap is running (expansion is on and Accessibility granted).
    @Published private(set) var expansionActive = false

    var isTrusted: () -> Bool = { Paster.isTrusted }
    var canSimulatePaste: () -> Bool
    var isElectronFrontmost: () -> Bool = { SystemSnippetDriver.isElectron(NSWorkspace.shared.frontmostApplication) }
    var schedule: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }
    var placeholders: SnippetPlaceholders
    /// Runs before a paste from `insert` (the app hides its panel).
    var willPaste: (() -> Void)?
    /// The keyboard watcher; nil in tests and snapshots, where nothing is watched.
    private(set) var tap: SnippetKeyTap?
    private var settingsSink: AnyCancellable?

    init(model: AppModel, driver: SnippetInsertionDriver, alfredFolder: URL = AlfredSnippetImporter.defaultFolder()) {
        self.model = model
        self.driver = driver
        self.alfredFolder = alfredFolder
        store = SnippetStore(directory: model.directory)
        canSimulatePaste = { [weak model] in model?.canSimulatePaste ?? false }
        placeholders = SnippetPlaceholders(clipboard: { [weak model] in model?.pasteboard.string(forType: .string) })
        do {
            try store.load()
        } catch {
            // Keep the unreadable file for the user (moved aside) and start empty, as the history does.
            let aside = store.fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: store.fileURL, to: aside)
            NSLog("Stash: snippets unreadable (%@); moved to %@", error.localizedDescription, aside.path(percentEncoded: false))
            model.flash("Snippets file was unreadable; kept as \(aside.lastPathComponent)", seconds: 6)
        }
        store.onChange = { [weak self] in self?.storeChanged() }
        storeChanged()
        settingsSink = model.$settings.sink { [weak self] settings in self?.apply(settings) }
    }

    /// Starts watching the keyboard when expansion is on (the app calls this; tests do not).
    func startWatching() {
        let tap = SnippetKeyTap()
        tap.onKey = { [weak self] key, context in self?.keyTyped(key, context: context) }
        tap.onReset = { [weak self] in self?.engine.reset() }
        tap.onActiveChange = { [weak self] active in self?.expansionActive = active }
        self.tap = tap
        tap.setEnabled(model.settings.snippetExpansion)
    }

    private func storeChanged() {
        snippets = store.snippets
        collections = store.sortedCollections
        engine.snippets = store.snippets
    }

    private func apply(_ settings: StashSettings) {
        engine.isEnabled = settings.snippetExpansion
        // Never in the ignored apps (password managers), nor in Stash's own windows, where a
        // keyword is being typed into the Snippets editor.
        engine.ignoredBundleIDs = Set(settings.ignoreList).union([AppModel.bundleID])
        tap?.setEnabled(settings.snippetExpansion)
    }

    // MARK: - Expansion

    /// One key press from the tap: expands a completed keyword.
    func keyTyped(_ key: KeyInput, context: SnippetExpansionEngine.Context) {
        guard let match = engine.handle(key, context: context) else { return }
        schedule(Self.expansionDelay) { [weak self] in self?.insert(match.snippet, deleting: match.deleteCount) }
    }

    @discardableResult
    private func insert(_ snippet: Snippet, deleting deleteCount: Int) -> SnippetInsertion.Method {
        let text = placeholders.expand(snippet.text)
        return SnippetInsertion.run(text: text, deleteCount: deleteCount, canPaste: canSimulatePaste(),
                                    restoreDelay: SnippetInsertion.restoreDelay(electron: isElectronFrontmost()),
                                    driver: driver)
    }

    func setExpansion(_ on: Bool) throws {
        var settings = model.settings
        settings.snippetExpansion = on
        try model.updateSettings(settings)
    }

    // MARK: - Editing (the Snippets window)

    func save(_ snippet: Snippet) throws { try store.upsert(snippet) }
    func delete(_ id: String) throws { try store.remove(id: id) }
    func addCollection(_ name: String) throws { try store.addCollection(name) }
    func removeCollection(_ name: String) throws { try store.removeCollection(name) }

    // MARK: - Import

    struct ImportResult {
        var batch: AlfredImport
        var summary: SnippetImportSummary
        var dryRun: Bool
    }

    func importFromAlfred(folder: URL? = nil, dryRun: Bool) throws -> ImportResult {
        let batch = try AlfredSnippetImporter(folder: folder ?? alfredFolder).read()
        let summary = try store.merge(batch, dryRun: dryRun)
        return ImportResult(batch: batch, summary: summary, dryRun: dryRun)
    }

    /// Imports from Alfred's folder and says what happened, for the window and the menu.
    func importFromAlfredMessage() -> String {
        do {
            let result = try importFromAlfred(dryRun: false)
            let s = result.summary
            return "Alfred: \(s.added) added, \(s.updated) updated, \(s.unchanged) unchanged"
                + (result.batch.unknownPlaceholders.isEmpty ? "" : "; some placeholders are left as typed")
        } catch {
            return "\(error)"
        }
    }

    // MARK: - Socket verb

    /// `snippets <action> [key=value ...]`; the action is the first bare word (`_`) or `action=`.
    func handle(_ args: [String: String], done: @escaping ([String: Any]) -> Void) {
        let action = args["action"] ?? args["_"] ?? ""
        do {
            switch action {
            case "list": done(list(args))
            case "insert": done(try insert(args))
            case "import-alfred": done(try importAlfred(args))
            case "expansion": done(try expansion(args))
            default:
                throw HUDControlError.invalid("snippets action must be one of \(Self.actions.joined(separator: ", "))")
            }
        } catch {
            done(["ok": false, "error": "\(error)"])
        }
    }

    /// `{snippets: [{id, name, keyword, collection, preview}]}`, best match first.
    private func list(_ args: [String: String]) -> [String: Any] {
        let query = args["query"] ?? args["q"] ?? ""
        let limit = args["limit"].flatMap(Int.init).map { max(0, $0) } ?? Self.defaultListLimit
        let rows = SnippetSearch.rank(store.snippets, query: query).prefix(limit).map { s -> [String: Any] in
            ["id": s.id, "name": s.name, "keyword": s.keyword, "collection": s.collection,
             "preview": SnippetSearch.preview(placeholders.expandForPreview(s.text))]
        }
        return ["ok": true, "snippets": Array(rows)]
    }

    /// Pastes the expanded snippet into the frontmost app: `{pasted: true}`, or the text copied
    /// only, with a `hint`, when pasting is not possible (as `action paste` does).
    private func insert(_ args: [String: String]) throws -> [String: Any] {
        guard let id = args["id"], !id.isEmpty else { throw HUDControlError.invalid("id= required") }
        guard let snippet = store.snippet(id: id) else { throw HUDControlError.invalid("no snippet \(id)") }
        let hint: String? = !canSimulatePaste() ? "private pasteboard in use; copied only"
            : !isTrusted() ? "grant Accessibility to Stash to paste; copied only" : nil
        if let hint {
            ClipReader.write(text: placeholders.expand(snippet.text), to: model.pasteboard)
            model.watcher.skipCurrent()
            return ["ok": true, "pasted": false, "hint": hint]
        }
        willPaste?()
        schedule(Self.insertDelay) { [weak self] in self?.insert(snippet, deleting: 0) }
        return ["ok": true, "pasted": true]
    }

    private func importAlfred(_ args: [String: String]) throws -> [String: Any] {
        let dryRun = StashSettings.bool(args["dry-run"] ?? args["dryRun"] ?? "0") ?? false
        let folder = args["path"].flatMap { $0.isEmpty ? nil : URL(filePath: ($0 as NSString).expandingTildeInPath) }
        let result = try importFromAlfred(folder: folder, dryRun: dryRun)
        return ["ok": true, "dryRun": dryRun,
                "snippets": result.batch.snippets.count, "collections": result.batch.collections.count,
                "byCollection": result.batch.countsByCollection,
                "added": result.summary.added, "updated": result.summary.updated, "unchanged": result.summary.unchanged,
                "skipped": result.batch.skippedFiles, "unknownPlaceholders": result.batch.unknownPlaceholders]
    }

    /// `expansion` reports; `expansion on|off` (or `state=`/`enabled=`) switches and saves it.
    private func expansion(_ args: [String: String]) throws -> [String: Any] {
        let known: Set<String> = ["_", "action", "expansion", "state", "enabled", "on", "off"]
        if let stray = args.keys.first(where: { !known.contains($0) }) {
            throw HUDControlError.invalid("snippets expansion takes on or off, not \(stray)")
        }
        let value = args["state"] ?? args["enabled"] ?? (args["on"] != nil ? "on" : args["off"] != nil ? "off" : nil)
        if let value {
            guard let on = StashSettings.bool(value) else { throw HUDControlError.invalid("snippets expansion takes on or off") }
            try setExpansion(on)
        }
        let on = model.settings.snippetExpansion
        var reply: [String: Any] = ["ok": true, "expansion": on ? "on" : "off", "active": on && (tap?.isActive ?? false)]
        if on, !isTrusted() { reply["hint"] = "grant Accessibility to Stash to expand keywords" }
        return reply
    }
}
