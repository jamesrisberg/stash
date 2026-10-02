import Foundation

/// Which clips the desktop `clips` widget shows.
public enum ClipsWidgetSelection {
    /// The newest `limit` clips of `clips` (history order, newest first), only the pinned ones
    /// when `pinnedOnly`.
    public static func latest(_ clips: [Clip], pinnedOnly: Bool, limit: Int) -> [Clip] {
        guard limit > 0 else { return [] }
        return Array((pinnedOnly ? clips.filter(\.pinned) : clips).prefix(limit))
    }
}

extension Clip {
    /// The text on one line for a preview: non-empty lines trimmed and joined with spaces,
    /// cut to `limit` characters. Empty for a clip without text (an image).
    public func snippet(limit: Int) -> String {
        let lines = (text ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return String(lines.joined(separator: " ").prefix(limit))
    }
}
