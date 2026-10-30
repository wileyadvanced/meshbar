import Foundation

public enum MeshHealth: String, Equatable, Codable {
    /// Every checked link is inside the thresholds and WAN is up.
    case healthy
    /// A node is offline, or a backhaul link missed a threshold. WAN is still up.
    case degraded
    /// The router reports the WAN as down.
    case offline
    /// Nothing has been read yet.
    case unknown
    /// WAN is up, but the router did not share the node list, so the mesh
    /// itself cannot be judged.
    case partial

    public var label: String {
        switch self {
        case .healthy: return "Healthy"
        case .degraded: return "Needs attention"
        case .offline: return "WAN down"
        case .unknown: return "No data"
        case .partial: return "Partial data"
        }
    }
}

public struct HealthThresholds: Equatable, Codable {
    public var minimumBackhaulMbps: Double
    public var minimumRSSI: Int

    public init(minimumBackhaulMbps: Double = 100, minimumRSSI: Int = -70) {
        self.minimumBackhaulMbps = minimumBackhaulMbps
        self.minimumRSSI = minimumRSSI
    }

    /// RSSI thresholds are negative dBm. A positive value was almost certainly
    /// entered by mistake, so fall back to -70 instead of painting the mesh amber.
    public var clamped: HealthThresholds {
        HealthThresholds(
            minimumBackhaulMbps: max(0, minimumBackhaulMbps),
            minimumRSSI: minimumRSSI < 0 ? minimumRSSI : -70
        )
    }
}

public enum HealthEvaluator {
    /// WAN down is the only red state. A dead node or a weak backhaul is amber.
    /// Wired links ignore RSSI, because a cable has no signal strength.
    /// Missing speed or RSSI is "unknown", not a failure.
    public static func evaluate(_ snapshot: MeshSnapshot, thresholds: HealthThresholds = HealthThresholds()) -> MeshHealth {
        let limits = thresholds.clamped
        if snapshot.nodes.isEmpty && snapshot.wan == nil {
            return .unknown
        }
        if snapshot.wan?.isConnected == false {
            return .offline
        }
        if snapshot.nodes.isEmpty {
            return .partial
        }
        if snapshot.nodes.contains(where: { !$0.isOnline }) {
            return .degraded
        }
        if snapshot.nodes.contains(where: { backhaulIsDegraded($0, thresholds: limits) }) {
            return .degraded
        }
        return .healthy
    }

    public static func backhaulIsDegraded(_ node: MeshNode, thresholds: HealthThresholds = HealthThresholds()) -> Bool {
        let limits = thresholds.clamped
        guard !node.isPrimary, node.isOnline, let link = node.backhaul else { return false }
        if let speed = link.speedMbps, speed < limits.minimumBackhaulMbps {
            return true
        }
        if link.medium != .wired, let rssi = link.rssiDbm, rssi < limits.minimumRSSI {
            return true
        }
        return false
    }

    public static func linkQuality(_ node: MeshNode, thresholds: HealthThresholds = HealthThresholds()) -> MeshHealth {
        if !node.isOnline { return .offline }
        if backhaulIsDegraded(node, thresholds: thresholds) { return .degraded }
        return .healthy
    }
}
