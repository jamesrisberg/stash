import Foundation

/// Rate limit for pushed events: at most one per `interval`, leading edge fires at once and
/// a burst collapses into one trailing event. Pure (the caller supplies the time and does the
/// scheduling), so it is testable without timers.
public struct EventThrottle: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Send now.
        case fire
        /// Send after this delay, then call `firePending(now:)`.
        case schedule(after: TimeInterval)
        /// A trailing send is already scheduled; it will carry this change.
        case coalesced
    }

    public let interval: TimeInterval
    public private(set) var lastFire: Date?
    public private(set) var hasPending = false

    public init(interval: TimeInterval) { self.interval = interval }

    public mutating func signal(now: Date) -> Decision {
        if hasPending { return .coalesced }
        if let last = lastFire, now.timeIntervalSince(last) < interval {
            hasPending = true
            return .schedule(after: interval - now.timeIntervalSince(last))
        }
        lastFire = now
        return .fire
    }

    /// Records that the scheduled trailing send happened.
    public mutating func firePending(now: Date) {
        hasPending = false
        lastFire = now
    }
}
