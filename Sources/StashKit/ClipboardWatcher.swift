import AppKit

/// Polls a pasteboard's `changeCount` and reports each new copy as a `ClipPayload`.
///
/// Everything environmental is injectable so tests can use a private named pasteboard and
/// drive `poll()` by hand: the pasteboard, the clock, the frontmost app and secure input.
///
/// A change is skipped (but still consumed) when secure input is on (a password field has
/// focus), the frontmost app is on the ignore list, the contents carry an nspasteboard.org
/// concealed/transient marker, or Stash wrote them itself.
@MainActor
public final class ClipboardWatcher {
    public enum SkipReason: String, Equatable, Sendable {
        case secureInput, ignoredApp, concealed, ownWrite, unreadable, paused
    }

    public struct Event: Equatable {
        public var payload: ClipPayload
        public var sourceBundleID: String?
        public var date: Date
    }

    public let pasteboard: NSPasteboard
    public var interval: TimeInterval { didSet { if interval != oldValue, timer != nil { start() } } }
    public var ignoredBundleIDs: Set<String>
    public var isPaused = false
    public var now: () -> Date
    public var frontmostBundleID: () -> String?
    public var isSecureInputEnabled: () -> Bool

    /// Called with each recorded copy.
    public var onClip: ((Event) -> Void)?
    /// Called when a change was seen but not recorded.
    public var onSkip: ((SkipReason) -> Void)?

    public private(set) var lastChangeCount: Int
    private var timer: Timer?

    public init(pasteboard: NSPasteboard = .general,
                interval: TimeInterval = 0.25,
                ignoredBundleIDs: Set<String> = [],
                now: @escaping () -> Date = Date.init,
                frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
                isSecureInputEnabled: @escaping () -> Bool = { SecureInput.isEnabled }) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.ignoredBundleIDs = ignoredBundleIDs
        self.now = now
        self.frontmostBundleID = frontmostBundleID
        self.isSecureInputEnabled = isSecureInputEnabled
        // Whatever is on the pasteboard at launch was copied before we started watching.
        lastChangeCount = pasteboard.changeCount
    }

    public var isRunning: Bool { timer != nil }

    public func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: max(0.05, interval), repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in _ = self?.poll() }
        }
        t.tolerance = interval / 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Checks the pasteboard once. Returns the recorded event, if any.
    @discardableResult
    public func poll() -> Event? {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return nil }
        lastChangeCount = count

        if let reason = skipReason() {
            onSkip?(reason)
            return nil
        }
        guard let payload = ClipReader.read(pasteboard) else {
            onSkip?(.unreadable)
            return nil
        }
        let event = Event(payload: payload, sourceBundleID: frontmostBundleID(), date: now())
        onClip?(event)
        return event
    }

    /// Marks the current contents as seen without recording them.
    public func skipCurrent() { lastChangeCount = pasteboard.changeCount }

    private func skipReason() -> SkipReason? {
        if isPaused { return .paused }
        if isSecureInputEnabled() { return .secureInput }
        let types = pasteboard.types ?? []
        if types.contains(ClipReader.stashMarker) { return .ownWrite }
        if ClipReader.isConcealed(types) { return .concealed }
        if let app = frontmostBundleID(), ignoredBundleIDs.contains(app) { return .ignoredApp }
        return nil
    }
}
