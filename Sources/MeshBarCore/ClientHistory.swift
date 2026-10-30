import Foundation

/// One client's state at one poll. Recorded for every known client on every
/// successful refresh, so connection and link-rate history can be rebuilt.
/// The router does not expose per-client traffic, so none is stored.
public struct ClientSample: Codable, Equatable {
    public var timestamp: Date
    /// Router device ID (stable across IP and name changes).
    public var clientID: String
    public var macAddress: String?
    public var name: String
    public var nodeID: String?
    public var nodeName: String?
    /// Raw band string from the router, e.g. "5GHz".
    public var band: String?
    /// `LinkMedium.rawValue`.
    public var medium: String?
    public var rssiDbm: Int?
    public var linkMbps: Double?
    public var isOnline: Bool
    public var ipAddress: String?

    public init(
        timestamp: Date,
        clientID: String,
        macAddress: String? = nil,
        name: String,
        nodeID: String? = nil,
        nodeName: String? = nil,
        band: String? = nil,
        medium: String? = nil,
        rssiDbm: Int? = nil,
        linkMbps: Double? = nil,
        isOnline: Bool,
        ipAddress: String? = nil
    ) {
        self.timestamp = timestamp
        self.clientID = clientID
        self.macAddress = macAddress
        self.name = name
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.band = band
        self.medium = medium
        self.rssiDbm = rssiDbm
        self.linkMbps = linkMbps
        self.isOnline = isOnline
        self.ipAddress = ipAddress
    }

    /// "2.4 GHz", "5 GHz", "6 GHz", "Wired", or nil.
    public var bandFamily: String? {
        if medium == LinkMedium.wired.rawValue { return "Wired" }
        return ClientBandFamily.family(band)
    }
}

public enum ClientBandFamily {
    /// Collapses "5GHz", "RADIO_5GHz_2", "5GL" and so on to "5 GHz".
    public static func family(_ raw: String?) -> String? {
        guard let label = BandFormat.label(raw) else { return nil }
        if label.hasPrefix("2.4") { return "2.4 GHz" }
        if label.hasPrefix("5 ") || label == "5 GHz" { return "5 GHz" }
        if label.hasPrefix("6 ") { return "6 GHz" }
        if label.hasPrefix("60") { return "60 GHz" }
        return label
    }
}

extension MeshSnapshot {
    public func makeClientSamples() -> [ClientSample] {
        clients.map { client in
            ClientSample(
                timestamp: capturedAt,
                clientID: client.id,
                macAddress: client.macAddresses.first,
                name: client.name,
                nodeID: client.isOnline ? client.parentNodeID : nil,
                nodeName: client.isOnline ? client.parentNodeID.flatMap { node(id: $0)?.name } : nil,
                band: client.isOnline ? client.band : nil,
                medium: client.medium.rawValue,
                rssiDbm: client.isOnline ? client.rssiDbm : nil,
                linkMbps: client.isOnline ? client.negotiatedMbps : nil,
                isOnline: client.isOnline,
                ipAddress: client.ipAddress
            )
        }
    }
}

// MARK: - Connection events

public struct ClientEvent: Equatable, Identifiable {
    public enum Kind: Equatable {
        case cameOnline(nodeName: String?, band: String?)
        case wentOffline(lastNodeName: String?)
        case roamed(fromNodeID: String?, fromName: String?, toNodeID: String?, toName: String?, band: String?)
        case bandChanged(from: String?, to: String?)
        case ipChanged(from: String?, to: String?)
    }

    public var timestamp: Date
    public var kind: Kind

    public init(timestamp: Date, kind: Kind) {
        self.timestamp = timestamp
        self.kind = kind
    }

    public var id: String { "\(timestamp.timeIntervalSince1970)-\(title)" }

    public var title: String {
        switch kind {
        case let .cameOnline(node, band):
            let place = [node, band].compactMap { $0 }.joined(separator: " · ")
            return place.isEmpty ? "Came online" : "Came online on \(place)"
        case let .wentOffline(node):
            return node.map { "Went offline (last on \($0))" } ?? "Went offline"
        case let .roamed(_, from, _, to, band):
            let base = "Roamed \(from ?? "?") → \(to ?? "?")"
            return band.map { "\(base) · \($0)" } ?? base
        case let .bandChanged(from, to):
            return "Band \(from ?? "?") → \(to ?? "?")"
        case let .ipChanged(from, to):
            return from == nil ? "Got IP \(to ?? "?")" : "IP changed \(from ?? "?") → \(to ?? "?")"
        }
    }

    public var symbolName: String {
        switch kind {
        case .cameOnline: return "wifi"
        case .wentOffline: return "wifi.slash"
        case .roamed: return "arrow.triangle.swap"
        case .bandChanged: return "antenna.radiowaves.left.and.right"
        case .ipChanged: return "number"
        }
    }

    public var isRoam: Bool { if case .roamed = kind { return true } else { return false } }
    public var isDrop: Bool { if case .wentOffline = kind { return true } else { return false } }
}

/// A value that only changes after a new reading has held for a while.
struct DebouncedValue<Value: Equatable> {
    var committed: Value
    private(set) var pending: Value?
    private(set) var pendingSince: Date?

    init(_ value: Value) { committed = value }

    /// Returns (old, new, time the new value was first seen) on commit.
    mutating func observe(_ value: Value, at time: Date, hold: TimeInterval) -> (from: Value, to: Value, at: Date)? {
        if value == committed {
            pending = nil
            pendingSince = nil
            return nil
        }
        if pending != value {
            pending = value
            pendingSince = time
        }
        guard let since = pendingSince, time.timeIntervalSince(since) >= hold else { return nil }
        let from = committed
        committed = value
        pending = nil
        pendingSince = nil
        return (from, value, since)
    }

    mutating func reset(to value: Value) {
        committed = value
        pending = nil
        pendingSince = nil
    }
}

public enum ClientEventDeriver {
    /// A change must hold for this long before it counts. At the default
    /// 60 s poll that is two polls in a row, so a one-poll blip is ignored.
    public static let defaultHold: TimeInterval = 45
    /// Gaps longer than this mean MeshBar was not polling; pending changes are
    /// dropped rather than guessed across the gap.
    public static let defaultMaximumGap: TimeInterval = 15 * 60

    /// Events oldest first.
    public static func events(
        from samples: [ClientSample],
        hold: TimeInterval = defaultHold,
        maximumGap: TimeInterval = defaultMaximumGap
    ) -> [ClientEvent] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        guard let first = sorted.first else { return [] }
        var online = DebouncedValue(first.isOnline)
        var node = DebouncedValue(first.nodeID)
        var band = DebouncedValue(first.bandFamily)
        var ip = DebouncedValue(first.ipAddress)
        var names: [String: String] = [:]
        var lastNodeName = first.nodeName
        if let id = first.nodeID, let name = first.nodeName { names[id] = name }
        var events: [ClientEvent] = []
        var previousTime = first.timestamp

        for sample in sorted.dropFirst() {
            if let id = sample.nodeID, let name = sample.nodeName { names[id] = name }
            if sample.timestamp.timeIntervalSince(previousTime) > maximumGap {
                online.reset(to: online.committed)
                node.reset(to: node.committed)
                band.reset(to: band.committed)
                ip.reset(to: ip.committed)
            }
            previousTime = sample.timestamp

            if let change = online.observe(sample.isOnline, at: sample.timestamp, hold: hold) {
                if change.to {
                    events.append(ClientEvent(timestamp: change.at, kind: .cameOnline(nodeName: sample.nodeName, band: sample.bandFamily)))
                    node.reset(to: sample.nodeID)
                    band.reset(to: sample.bandFamily)
                    if sample.ipAddress != nil && sample.ipAddress != ip.committed {
                        if ip.committed != nil {
                            events.append(ClientEvent(timestamp: change.at, kind: .ipChanged(from: ip.committed, to: sample.ipAddress)))
                        }
                        ip.reset(to: sample.ipAddress)
                    }
                    lastNodeName = sample.nodeName
                } else {
                    events.append(ClientEvent(timestamp: change.at, kind: .wentOffline(lastNodeName: lastNodeName)))
                    node.reset(to: node.committed)
                    band.reset(to: band.committed)
                }
                continue
            }
            // Node, band and IP only move while the client is (and stays) online.
            guard online.committed, sample.isOnline else { continue }
            lastNodeName = sample.nodeID.flatMap { names[$0] } ?? sample.nodeName ?? lastNodeName

            if sample.nodeID != nil, let change = node.observe(sample.nodeID, at: sample.timestamp, hold: hold) {
                // A roam usually switches band too; fold that into one event.
                let newBand = sample.bandFamily
                band.reset(to: newBand)
                events.append(ClientEvent(timestamp: change.at, kind: .roamed(
                    fromNodeID: change.from,
                    fromName: change.from.flatMap { names[$0] },
                    toNodeID: change.to,
                    toName: change.to.flatMap { names[$0] },
                    band: newBand
                )))
            } else if sample.bandFamily != nil, let change = band.observe(sample.bandFamily, at: sample.timestamp, hold: hold) {
                if change.from != nil {
                    events.append(ClientEvent(timestamp: change.at, kind: .bandChanged(from: change.from, to: change.to)))
                }
            }
            if sample.ipAddress != nil, let change = ip.observe(sample.ipAddress, at: sample.timestamp, hold: hold) {
                events.append(ClientEvent(timestamp: change.at, kind: .ipChanged(from: change.from, to: change.to)))
            }
        }
        return events
    }
}

// MARK: - Summary stats

public struct ClientHistoryStats: Equatable {
    public struct NodeShare: Equatable, Identifiable {
        public var nodeID: String
        public var nodeName: String
        public var fraction: Double
        public var id: String { nodeID }
    }

    public var nodeShares: [NodeShare]
    public var roams: Int
    public var drops: Int
    public var medianRSSI: Int?
    public var medianLinkMbps: Double?
    public var sampleCount: Int

    public static func compute(
        samples: [ClientSample],
        events: [ClientEvent],
        since: Date,
        maximumGap: TimeInterval = ClientEventDeriver.defaultMaximumGap
    ) -> ClientHistoryStats {
        let window = samples.filter { $0.timestamp >= since }.sorted { $0.timestamp < $1.timestamp }
        var seconds: [String: Double] = [:]
        var names: [String: String] = [:]
        for (current, next) in zip(window, window.dropFirst()) {
            guard current.isOnline, let id = current.nodeID else { continue }
            let gap = next.timestamp.timeIntervalSince(current.timestamp)
            guard gap > 0, gap <= maximumGap else { continue }
            seconds[id, default: 0] += gap
            if let name = current.nodeName { names[id] = name }
        }
        if seconds.isEmpty, let last = window.last(where: { $0.isOnline && $0.nodeID != nil }), let id = last.nodeID {
            seconds[id] = 1
            names[id] = last.nodeName
        }
        let total = seconds.values.reduce(0, +)
        let shares = seconds
            .map { NodeShare(nodeID: $0.key, nodeName: names[$0.key] ?? "Unknown node", fraction: total > 0 ? $0.value / total : 0) }
            .sorted { $0.fraction > $1.fraction }
        let recent = events.filter { $0.timestamp >= since }
        let online = window.filter(\.isOnline)
        return ClientHistoryStats(
            nodeShares: shares,
            roams: recent.filter(\.isRoam).count,
            drops: recent.filter(\.isDrop).count,
            medianRSSI: median(online.compactMap(\.rssiDbm).map(Double.init)).map { Int($0.rounded()) },
            medianLinkMbps: median(online.compactMap(\.linkMbps)),
            sampleCount: window.count
        )
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

// MARK: - Chart points

public struct ClientChartPoint: Equatable, Identifiable {
    public var timestamp: Date
    public var nodeID: String
    public var nodeName: String
    public var rssiDbm: Double?
    public var linkMbps: Double?
    /// Changes whenever the node changes or the line should break
    /// (offline or a polling gap), so charts draw separate segments.
    public var segment: Int
    public var id: String { "\(segment)-\(timestamp.timeIntervalSince1970)" }
}

public enum ClientChartSeries {
    /// Online samples as chart points, averaged into buckets so long ranges
    /// stay light. Buckets never cross a segment boundary.
    public static func points(
        _ samples: [ClientSample],
        maximumPoints: Int = 600,
        maximumGap: TimeInterval = ClientEventDeriver.defaultMaximumGap
    ) -> [ClientChartPoint] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var raw: [ClientChartPoint] = []
        var segment = 0
        var previous: ClientSample?
        for sample in sorted {
            defer { previous = sample }
            guard sample.isOnline else { continue }
            if let previous {
                if !previous.isOnline || previous.nodeID != sample.nodeID
                    || sample.timestamp.timeIntervalSince(previous.timestamp) > maximumGap {
                    segment += 1
                }
            }
            raw.append(ClientChartPoint(
                timestamp: sample.timestamp,
                nodeID: sample.nodeID ?? "unknown",
                nodeName: sample.nodeName ?? "Unknown node",
                rssiDbm: sample.rssiDbm.map(Double.init),
                linkMbps: sample.linkMbps,
                segment: segment
            ))
        }
        let size = max(1, Int((Double(raw.count) / Double(max(1, maximumPoints))).rounded(.up)))
        guard size > 1 else { return raw }
        var out: [ClientChartPoint] = []
        var bucket: [ClientChartPoint] = []
        func flush() {
            guard let head = bucket.first else { return }
            let rssi = bucket.compactMap(\.rssiDbm)
            let rate = bucket.compactMap(\.linkMbps)
            var point = head
            point.timestamp = bucket[bucket.count / 2].timestamp
            point.rssiDbm = rssi.isEmpty ? nil : rssi.reduce(0, +) / Double(rssi.count)
            point.linkMbps = rate.isEmpty ? nil : rate.reduce(0, +) / Double(rate.count)
            out.append(point)
            bucket.removeAll(keepingCapacity: true)
        }
        for point in raw {
            if let head = bucket.first, head.segment != point.segment || bucket.count >= size { flush() }
            bucket.append(point)
        }
        flush()
        return out
    }
}
