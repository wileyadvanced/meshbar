import Foundation

/// Serialises polls. At most one poll runs at a time; any number of requests
/// made while it runs collapse into exactly one follow-up poll, so a click on
/// Refresh during an automatic poll is never dropped and a burst of clicks
/// cannot hammer the router.
public struct RefreshGate: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Start a poll now. `forceBackhaul` asks the master to re-measure
        /// satellite backhaul first.
        case start(forceBackhaul: Bool, userInitiated: Bool)
        /// A poll is already running. One more runs as soon as it ends.
        case queued
    }

    public private(set) var inFlight = false
    public private(set) var queued = false
    private var queuedForcesBackhaul = false
    private var queuedUserInitiated = false

    public init() {}

    public mutating func request(forceBackhaul: Bool = false, userInitiated: Bool = false) -> Decision {
        if inFlight {
            queued = true
            queuedForcesBackhaul = queuedForcesBackhaul || forceBackhaul
            queuedUserInitiated = queuedUserInitiated || userInitiated
            return .queued
        }
        inFlight = true
        return .start(forceBackhaul: forceBackhaul, userInitiated: userInitiated)
    }

    /// Call when the running poll ends. Returns the queued follow-up, which
    /// the caller must run next (the gate stays in flight), or nil when idle.
    public mutating func finish() -> Decision? {
        guard inFlight else { return nil }
        guard queued else {
            inFlight = false
            return nil
        }
        let next = Decision.start(forceBackhaul: queuedForcesBackhaul, userInitiated: queuedUserInitiated)
        queued = false
        queuedForcesBackhaul = false
        queuedUserInitiated = false
        return next
    }

    /// Whether to ask the master to re-measure backhaul before reading it.
    /// Automatic polls do it at most every `interval` seconds; a manual
    /// refresh always does.
    public static func shouldRefreshBackhaul(force: Bool, last: Date?, now: Date = Date(), interval: TimeInterval = 300) -> Bool {
        if force { return true }
        guard let last else { return true }
        return now.timeIntervalSince(last) > interval
    }
}

/// "just now", "12s ago", "3m ago", "2h ago". Never "in 0s": a capture time a
/// moment ahead of the clock (rounding, clock skew) reads as "just now".
public enum RefreshClock {
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case 0..<5: return "just now"
        case 5..<60: return "\(seconds)s ago"
        case 60..<3600: return "\(seconds / 60)m ago"
        case 3600..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }
}
