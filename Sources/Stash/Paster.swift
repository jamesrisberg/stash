import AppKit
import ApplicationServices
import Carbon

/// Simulated ⌘V into the frontmost app. Needs Accessibility (System Settings > Privacy &
/// Security > Accessibility); without it Stash only copies.
@MainActor
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds Stash to the Accessibility list.
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Posts ⌘V. Returns false when not permitted. `tag` goes in the events'
    /// `eventSourceUserData`, so Stash's own key tap can tell them from the user's typing.
    @discardableResult
    static func postCommandV(tag: Int64 = 0) -> Bool {
        guard isTrusted else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: tag)
        up.setIntegerValueField(.eventSourceUserData, value: tag)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
