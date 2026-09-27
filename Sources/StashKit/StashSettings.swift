import Foundation

/// User settings, described for MacHUD's shared settings window by `Sources/Stash/Resources/settings.json`
/// and persisted as `preferences.json` next to the history.
public struct StashSettings: Codable, Equatable, Sendable {
    /// Unpinned clips kept.
    public var historyCap: Int = 200
    /// Pasteboard poll interval in milliseconds.
    public var pollIntervalMs: Int = 250
    /// Bundle ids whose copies are never recorded.
    public var ignoreList: [String] = StashSettings.defaultIgnoreList
    /// Enter pastes into the previous app (needs Accessibility); off, Enter only copies.
    public var pasteOnEnter: Bool = true

    public init() {}

    public static let historyCapRange = 10...5000
    public static let pollIntervalRange = 50...5000

    /// Password managers and credential tools.
    public static let defaultIgnoreList = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc",
        "in.sinew.Enpass-Desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

    /// Saved values are merged over the defaults key by key: a missing key, or one whose value no
    /// longer decodes, keeps its default and the other saved values are kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StashSettings()
        historyCap = (try? c.decodeIfPresent(Int.self, forKey: .historyCap)) ?? d.historyCap
        pollIntervalMs = (try? c.decodeIfPresent(Int.self, forKey: .pollIntervalMs)) ?? d.pollIntervalMs
        ignoreList = (try? c.decodeIfPresent([String].self, forKey: .ignoreList)) ?? d.ignoreList
        pasteOnEnter = (try? c.decodeIfPresent(Bool.self, forKey: .pasteOnEnter)) ?? d.pasteOnEnter
    }

    public enum SettingsError: Error, CustomStringConvertible, Equatable {
        case invalid(String)
        public var description: String { if case .invalid(let why) = self { return why }; return "" }
    }

    public var pollInterval: TimeInterval { Double(pollIntervalMs) / 1000 }

    /// The `settings get` form, matching the schema's types (`ignoreList` is a comma-separated string).
    public var json: [String: Any] {
        ["historyCap": historyCap, "pollIntervalMs": pollIntervalMs, "ignoreList": ignoreList.joined(separator: ","),
         "pasteOnEnter": pasteOnEnter]
    }

    /// Returns a copy with string values from `settings set` applied. Validates every value
    /// before applying any. `ignoreList` is comma-separated.
    public func applying(_ values: [String: String]) throws -> StashSettings {
        var s = self
        for (key, value) in values {
            switch key {
            case "historyCap":
                guard let n = Int(value), Self.historyCapRange.contains(n) else {
                    throw SettingsError.invalid("historyCap must be an integer in \(Self.historyCapRange.lowerBound)-\(Self.historyCapRange.upperBound)")
                }
                s.historyCap = n
            case "pollIntervalMs":
                guard let n = Int(value), Self.pollIntervalRange.contains(n) else {
                    throw SettingsError.invalid("pollIntervalMs must be an integer in 50-5000")
                }
                s.pollIntervalMs = n
            case "ignoreList":
                s.ignoreList = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "pasteOnEnter":
                switch value.lowercased() {
                case "1", "true", "yes", "on": s.pasteOnEnter = true
                case "0", "false", "no", "off": s.pasteOnEnter = false
                default: throw SettingsError.invalid("pasteOnEnter must be true or false")
                }
            default:
                throw SettingsError.invalid("unknown setting \(key)")
            }
        }
        return s
    }
}

/// Loads and saves `StashSettings` as JSON.
public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(directory: URL = ClipStore.defaultDirectory) {
        fileURL = directory.appending(path: "preferences.json")
    }

    /// Defaults when there is no file; a corrupt file also falls back to defaults (and is left alone).
    public func load() -> StashSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return StashSettings() }
        do {
            return try JSONDecoder().decode(StashSettings.self, from: data)
        } catch {
            NSLog("Stash: ignoring unreadable %@: %@", fileURL.path(percentEncoded: false), error.localizedDescription)
            return StashSettings()
        }
    }

    public func save(_ settings: StashSettings) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
