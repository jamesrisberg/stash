import AppKit
import Carbon
import StashKit

/// Watches typing for snippet keywords: a session event tap on key presses and mouse clicks,
/// plus app switches. It only reads (every event passes through unchanged) and runs only while
/// snippet expansion is on. Creating it needs the Accessibility permission Stash already asks
/// for pasting; until that is granted it retries every few seconds.
///
/// The tap runs on its own thread's run loop and returns each event at once, handing a copy of
/// what it needs to the main thread, so typing never waits on Stash's main thread. It sits at
/// the tail of the session taps (`tailAppendEventTap`), so it sees only keys that other taps
/// let through (MacHUD's radial menu swallows digits). Each key is attributed to the process it
/// is going to (`eventTargetUnixProcessID`), which also covers non-activating panels such as
/// MacHUD's search bar and Spotlight that never become the frontmost app.
@MainActor
final class SnippetKeyTap {
    /// `eventSourceUserData` on every event Stash posts itself ("STSH"), which the tap skips.
    nonisolated static let eventTag: Int64 = 0x5354_5348

    /// A key press, with its target app, secure input and the input source as they are now.
    var onKey: ((KeyInput, SnippetExpansionEngine.Context) -> Void)?
    /// A click or an app switch: whatever was typed no longer ends at the cursor.
    var onReset: (() -> Void)?
    /// The tap came or went.
    var onActiveChange: ((Bool) -> Void)?

    /// The running tap's thread. It owns the tap and tears it down itself; main only asks it
    /// to stop.
    private var thread: TapThread?
    private var retry: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var bundleIDs: [pid_t: String] = [:]
    private var inputMethodActive = false
    private(set) var isEnabled = false

    var isActive: Bool { thread != nil }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        if on {
            install()
            let workspace = NSWorkspace.shared.notificationCenter
            observers.append((workspace, workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.onReset?() } }))
            observers.append((workspace, workspace.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { if let pid { self?.bundleIDs[pid] = nil } }
            }))
            let distributed = DistributedNotificationCenter.default()
            observers.append((distributed, distributed.addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.inputMethodActive = Self.isInputMethodSelected() } }))
            inputMethodActive = Self.isInputMethodSelected()
        } else {
            uninstall()
            for (center, observer) in observers { center.removeObserver(observer) }
            observers.removeAll()
            bundleIDs.removeAll()
        }
    }

    private func install() {
        guard thread == nil else { return }
        if Paster.isTrusted, let relay = TapRelay.make(deliver: { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(event) } }
        }) {
            let thread = TapThread(relay: relay)
            thread.start()
            self.thread = thread
            retry?.invalidate()
            retry = nil
            onActiveChange?(true)
            return
        }
        // No Accessibility yet: try again once it is granted.
        guard retry == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled, self.thread == nil else { return }
                self.install()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retry = timer
    }

    private func uninstall() {
        retry?.invalidate()
        retry = nil
        guard let thread else { return }
        thread.stop()
        self.thread = nil
        onActiveChange?(false)
    }

    private func receive(_ event: TapRelay.Event) {
        guard isEnabled else { return }
        switch event {
        case .reset:
            onReset?()
        case .key(let key, let pid):
            let target = bundleID(for: pid)
            onKey?(key, SnippetExpansionEngine.Context(secureInput: SecureInput.isEnabled, frontmostBundleID: target,
                                                       composing: inputMethodActive))
        }
    }

    private func bundleID(for pid: pid_t) -> String? {
        if pid > 0, let known = bundleIDs[pid] { return known }
        let id = Self.bundleID(forPID: pid, frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        if pid > 0, pid != getpid(), let id { bundleIDs[pid] = id }
        return id
    }

    /// The bundle id of the process a key goes to: Stash for its own windows, the frontmost
    /// app when the event names no process.
    static func bundleID(forPID pid: pid_t, frontmost: String?) -> String? {
        if pid == getpid() { return AppModel.bundleID }
        guard pid > 0 else { return frontmost }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? frontmost
    }

    /// Whether the selected input source is an input method (Japanese, Chinese, …) rather than
    /// a keyboard layout: its keys compose marked text, so they are never read as a keyword.
    static func isInputMethodSelected() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return type != (kTISTypeKeyboardLayout as String)
    }

    nonisolated static func keyInput(_ event: CGEvent) -> KeyInput {
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

/// The tap itself and what its callback hands on. The callback runs on the tap's thread: it
/// copies the key out of the event, posts it to `deliver` and returns the event untouched.
private final class TapRelay: @unchecked Sendable {
    enum Event: Sendable {
        case key(KeyInput, pid: pid_t)
        case reset
    }

    let deliver: @Sendable (Event) -> Void
    /// Set once by `make`, before the tap's thread starts; only that thread uses it afterwards.
    private(set) var port: CFMachPort?

    private init(deliver: @escaping @Sendable (Event) -> Void) { self.deliver = deliver }

    /// A relay with its tap, or nil when the tap cannot be created (no Accessibility). The tap
    /// receives nothing until `TapThread` puts its source on a run loop.
    static func make(deliver: @escaping @Sendable (Event) -> Void) -> TapRelay? {
        let relay = TapRelay(deliver: deliver)
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon { Unmanaged<TapRelay>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        // A filtering tap (`.defaultTap`) is what Accessibility allows; it never changes or
        // drops an event. A listen-only tap would need the separate Input Monitoring permission.
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                           options: .defaultTap, eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(relay).toOpaque()) else { return nil }
        relay.port = port
        return relay
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            deliver(.reset)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            deliver(.reset)
        case .keyDown:
            guard event.getIntegerValueField(.eventSourceUserData) != SnippetKeyTap.eventTag else { return }
            let pid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
            deliver(.key(SnippetKeyTap.keyInput(event), pid: pid))
        default:
            break
        }
    }
}

/// A thread whose run loop serves the tap. It holds the relay (so the tap's callback never
/// outlives it) and, when its run loop ends, disables and invalidates the tap and removes its
/// source itself; the main thread only asks it to stop.
private final class TapThread: Thread, @unchecked Sendable {
    private let relay: TapRelay
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopRequested = false

    init(relay: TapRelay) {
        self.relay = relay
        super.init()
        name = "xyz.machud.stash.snippet-tap"
        qualityOfService = .userInteractive
    }

    override func main() {
        guard let port = relay.port else { return }
        let loop = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(loop, source, .commonModes)
        lock.withLock { runLoop = loop }
        // Runs until asked to stop; the flag also catches a stop that came before the run
        // loop was running.
        while !lock.withLock({ stopRequested }) {
            CFRunLoopRunInMode(.defaultMode, 1, false)
        }
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(port)
    }

    /// Asks the thread to stop. Safe from any thread: it sets a flag under the lock and wakes
    /// the run loop with `CFRunLoopStop`.
    func stop() {
        let loop: CFRunLoop? = lock.withLock {
            stopRequested = true
            return runLoop
        }
        if let loop { CFRunLoopStop(loop) }
    }
}
