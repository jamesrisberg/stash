import AppKit
import StashKit

/// Watches typing for snippet keywords: a session event tap on key presses and mouse clicks,
/// plus app switches. It only reads (every event passes through unchanged) and runs only while
/// snippet expansion is on. Creating it needs the Accessibility permission Stash already asks
/// for pasting; until that is granted it retries every few seconds.
@MainActor
final class SnippetKeyTap {
    /// `eventSourceUserData` on every event Stash posts itself ("STSH"), which the tap skips.
    nonisolated static let eventTag: Int64 = 0x5354_5348

    /// A key press, with the frontmost app and secure input as they are now.
    var onKey: ((KeyInput, SnippetExpansionEngine.Context) -> Void)?
    /// A click or an app switch: whatever was typed no longer ends at the cursor.
    var onReset: (() -> Void)?
    /// The tap came or went.
    var onActiveChange: ((Bool) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?
    private var appObserver: NSObjectProtocol?
    private var frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    private(set) var isEnabled = false

    var isActive: Bool { tap != nil }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        if on {
            install()
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    self?.frontmostBundleID = app?.bundleIdentifier
                    self?.onReset?()
                }
            }
        } else {
            uninstall()
            if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
            appObserver = nil
        }
    }

    private func install() {
        guard tap == nil else { return }
        if Paster.isTrusted, let created = createTap() {
            tap = created
            source = CFMachPortCreateRunLoopSource(nil, created, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            retry?.invalidate()
            retry = nil
            frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            onActiveChange?(true)
            return
        }
        // No Accessibility yet: try again once it is granted.
        guard retry == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.isEnabled, self.tap == nil else { return }
                self.install()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retry = timer
    }

    private func uninstall() {
        retry?.invalidate()
        retry = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        onActiveChange?(false)
    }

    private func createTap() -> CFMachPort? {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let owner = Unmanaged<SnippetKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { owner.handle(type: type, event: event) }
            }
            return Unmanaged.passUnretained(event)
        }
        // A filtering tap (`.defaultTap`) is what Accessibility allows; it never changes or
        // drops an event. A listen-only tap would need the separate Input Monitoring permission.
        return CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                 eventsOfInterest: mask, callback: callback,
                                 userInfo: Unmanaged.passUnretained(self).toOpaque())
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap, isEnabled { CGEvent.tapEnable(tap: tap, enable: true) }
            onReset?()
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onReset?()
        case .keyDown:
            guard event.getIntegerValueField(.eventSourceUserData) != Self.eventTag else { return }
            onKey?(Self.keyInput(event), SnippetExpansionEngine.Context(secureInput: SecureInput.isEnabled,
                                                                       frontmostBundleID: frontmostBundleID))
        default:
            break
        }
    }

    static func keyInput(_ event: CGEvent) -> KeyInput {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        let flags = event.flags
        var modifiers: KeyInput.Modifiers = []
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        // Delete, Return and the like type control characters, function keys private-use ones:
        // neither is text a keyword can contain.
        let text = String(utf16CodeUnits: chars, count: length).filter { character in
            !character.unicodeScalars.contains { [.control, .privateUse].contains($0.properties.generalCategory) }
        }
        return KeyInput(keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                        characters: text, modifiers: modifiers)
    }
}
