import CoreGraphics
import Foundation
import HUDKit

/// The panel's last full and compact frames, kept as `frames.json` next to the history (so
/// an instance with its own `STASH_HOME` keeps its own). Launching and summoning the panel
/// put it back where the user left it.
struct PanelFrameStore {
    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appending(path: "frames.json")
    }

    /// The saved frame for `mode`; nil for `.parked`, when nothing is saved, or for a degenerate rect.
    func frame(for mode: HUDPanelMode) -> CGRect? {
        guard mode != .parked else { return nil }
        guard let values = load()[mode.rawValue], values.count == 4 else { return nil }
        return Self.valid(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
    }

    /// Remembers `frame` as the frame for `mode` (`.parked` frames are not kept).
    func save(_ frame: CGRect, for mode: HUDPanelMode) {
        guard mode != .parked, Self.valid(frame) != nil else { return }
        var all = load()
        all[mode.rawValue] = [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(all).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Stash: could not save panel frame: %@", error.localizedDescription)
        }
    }

    private func load() -> [String: [Double]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: [Double]].self, from: data)) ?? [:]
    }

    private static func valid(_ rect: CGRect) -> CGRect? { rect.width > 0 && rect.height > 0 ? rect : nil }
}
