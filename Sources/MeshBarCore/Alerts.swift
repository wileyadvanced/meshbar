import Foundation

public struct MeshAlert: Equatable, Identifiable {
    public enum Kind: String, Equatable {
        case nodeOffline
        case parentChanged
        case backhaulDegraded
    }

    public var id: String
    public var kind: Kind
    public var nodeID: String
    public var title: String
    public var body: String
    public var timestamp: Date
}

/// Edge-triggered alerts with a per-key debounce.
///
/// The first snapshot is silent: opening the app should not notify about a
/// condition that was already true. A flap inside `debounce` is one alert.
public final class AlertEngine {
    public var debounce: TimeInterval
    private var lastFired: [String: Date] = [:]

    public init(debounce: TimeInterval = 120) {
        self.debounce = debounce
    }

    public func evaluate(
        previous: MeshSnapshot?,
        current: MeshSnapshot,
        thresholds: HealthThresholds = HealthThresholds(),
        now: Date = Date()
    ) -> [MeshAlert] {
        guard let previous else { return [] }
        let limits = thresholds.clamped
        var prior: [String: MeshNode] = [:]
        for node in previous.nodes {
            prior[node.id] = node
        }
        var alerts: [MeshAlert] = []
        for node in current.nodes where !node.isPrimary {
            guard let old = prior[node.id] else { continue }
            if old.isOnline && !node.isOnline {
                consider(
                    &alerts,
                    key: "offline:\(node.id)",
                    kind: .nodeOffline,
                    nodeID: node.id,
                    title: "\(node.name) is offline",
                    body: "\(node.name) stopped answering the mesh.",
                    now: now
                )
            }
            if node.isOnline,
               let oldParent = old.parentID,
               let newParent = node.parentID,
               oldParent != newParent {
                let from = previous.node(id: oldParent)?.name ?? "its previous parent"
                let to = current.node(id: newParent)?.name ?? "a different node"
                consider(
                    &alerts,
                    key: "parent:\(node.id)",
                    kind: .parentChanged,
                    nodeID: node.id,
                    title: "\(node.name) changed parent",
                    body: "Backhaul moved from \(from) to \(to). MeshBar cannot pin a parent.",
                    now: now
                )
            }
            let wasDegraded = HealthEvaluator.backhaulIsDegraded(old, thresholds: limits)
            let isDegraded = HealthEvaluator.backhaulIsDegraded(node, thresholds: limits)
            if !wasDegraded && isDegraded {
                consider(
                    &alerts,
                    key: "backhaul:\(node.id)",
                    kind: .backhaulDegraded,
                    nodeID: node.id,
                    title: "\(node.name) backhaul degraded",
                    body: degradedBody(node, limits: limits),
                    now: now
                )
            }
        }
        return alerts
    }

    private func consider(
        _ alerts: inout [MeshAlert],
        key: String,
        kind: MeshAlert.Kind,
        nodeID: String,
        title: String,
        body: String,
        now: Date
    ) {
        if let last = lastFired[key], now.timeIntervalSince(last) < debounce {
            return
        }
        lastFired[key] = now
        alerts.append(
            MeshAlert(
                id: "\(key)|\(now.timeIntervalSince1970)",
                kind: kind,
                nodeID: nodeID,
                title: title,
                body: body,
                timestamp: now
            )
        )
    }

    private func degradedBody(_ node: MeshNode, limits: HealthThresholds) -> String {
        var parts: [String] = []
        if let speed = node.backhaul?.speedMbps, speed < limits.minimumBackhaulMbps {
            parts.append(String(format: "%.0f Mbps", speed))
        }
        if node.backhaul?.medium != .wired, let rssi = node.backhaul?.rssiDbm, rssi < limits.minimumRSSI {
            parts.append("\(rssi) dBm")
        }
        if parts.isEmpty {
            return "\(node.name) fell below the backhaul threshold."
        }
        return "\(node.name) is at \(parts.joined(separator: ", "))."
    }
}
