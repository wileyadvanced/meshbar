import Foundation

public enum NodeRole: String, Equatable {
    case primary
    case secondary
    case unknown

    public var label: String {
        switch self {
        case .primary: return "Router"
        case .secondary: return "Extender"
        case .unknown: return "Node"
        }
    }
}

public enum LinkMedium: String, Equatable {
    case wired
    case wireless
    case unknown

    public var label: String {
        switch self {
        case .wired: return "Wired"
        case .wireless: return "Wireless"
        case .unknown: return "Link"
        }
    }
}

public struct RouterIdentity: Equatable {
    public var deviceName: String?
    public var manufacturer: String?
    public var modelNumber: String?
    public var hardwareVersion: String?
    public var summary: String?
    public var serialNumber: String?
    public var firmwareVersion: String?
    public var firmwareDate: String?
}

public struct BackhaulLink: Equatable {
    public var medium: LinkMedium
    public var speedMbps: Double?
    public var rssiDbm: Int?
    public var band: String?
    public var channel: Int?
    public var parentIPAddress: String?
    /// The router reported a speed of 0: the link came up (after a channel
    /// change or a node rejoining) and has not been measured yet. Treated as
    /// unknown, never as a slow link.
    public var speedIsMeasuring: Bool = false

    /// True while the router has a link but no speed reading for it yet.
    public var isAwaitingSpeed: Bool { speedMbps == nil && speedIsMeasuring }
}

public struct MeshNode: Equatable, Identifiable {
    public var id: String
    public var name: String
    public var role: NodeRole
    public var manufacturer: String?
    public var modelNumber: String?
    public var hardwareVersion: String?
    public var summary: String?
    public var serialNumber: String?
    public var firmwareVersion: String?
    public var macAddress: String?
    public var ipAddress: String?
    public var isOnline: Bool
    public var uptimeSeconds: Int?
    public var cpuLoadPercent: Double?
    public var memoryLoadPercent: Double?
    public var parentID: String?
    public var backhaul: BackhaulLink?
    public var clientCount: Int

    public var isPrimary: Bool { role == .primary }

    public init(
        id: String,
        name: String,
        role: NodeRole,
        manufacturer: String? = nil,
        modelNumber: String? = nil,
        hardwareVersion: String? = nil,
        summary: String? = nil,
        serialNumber: String? = nil,
        firmwareVersion: String? = nil,
        macAddress: String? = nil,
        ipAddress: String? = nil,
        isOnline: Bool,
        uptimeSeconds: Int? = nil,
        cpuLoadPercent: Double? = nil,
        memoryLoadPercent: Double? = nil,
        parentID: String? = nil,
        backhaul: BackhaulLink? = nil,
        clientCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.manufacturer = manufacturer
        self.modelNumber = modelNumber
        self.hardwareVersion = hardwareVersion
        self.summary = summary
        self.serialNumber = serialNumber
        self.firmwareVersion = firmwareVersion
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.isOnline = isOnline
        self.uptimeSeconds = uptimeSeconds
        self.cpuLoadPercent = cpuLoadPercent
        self.memoryLoadPercent = memoryLoadPercent
        self.parentID = parentID
        self.backhaul = backhaul
        self.clientCount = clientCount
    }
}

public struct ClientDevice: Equatable, Identifiable {
    public var id: String
    public var name: String
    public var ipAddress: String?
    public var macAddresses: [String]
    public var parentNodeID: String?
    public var band: String?
    public var rssiDbm: Int?
    public var medium: LinkMedium
    public var isGuest: Bool
    public var isOnline: Bool
    public var negotiatedMbps: Double?
    /// Router-reported `model.deviceType`, e.g. "Phone".
    public var deviceType: String?
    public var manufacturer: String?
    public var modelNumber: String?
    public var operatingSystem: String?
    public var kind: DeviceKind

    public init(
        id: String,
        name: String,
        ipAddress: String? = nil,
        macAddresses: [String] = [],
        parentNodeID: String? = nil,
        band: String? = nil,
        rssiDbm: Int? = nil,
        medium: LinkMedium = .unknown,
        isGuest: Bool = false,
        isOnline: Bool,
        negotiatedMbps: Double? = nil,
        deviceType: String? = nil,
        manufacturer: String? = nil,
        modelNumber: String? = nil,
        operatingSystem: String? = nil,
        kind: DeviceKind? = nil
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.manufacturer = manufacturer
        self.modelNumber = modelNumber
        self.operatingSystem = operatingSystem
        self.kind = kind ?? DeviceKind.classify(
            deviceType: deviceType, modelNumber: modelNumber, operatingSystem: operatingSystem, name: name
        )
        self.ipAddress = ipAddress
        self.macAddresses = macAddresses
        self.parentNodeID = parentNodeID
        self.band = band
        self.rssiDbm = rssiDbm
        self.medium = medium
        self.isGuest = isGuest
        self.isOnline = isOnline
        self.negotiatedMbps = negotiatedMbps
    }
}

public struct WANStatus: Equatable {
    public var statusText: String
    public var isConnected: Bool
    public var wanType: String?
    public var ipAddress: String?
    public var gateway: String?
    public var dnsServers: [String]

    public init(
        statusText: String,
        isConnected: Bool,
        wanType: String? = nil,
        ipAddress: String? = nil,
        gateway: String? = nil,
        dnsServers: [String] = []
    ) {
        self.statusText = statusText
        self.isConnected = isConnected
        self.wanType = wanType
        self.ipAddress = ipAddress
        self.gateway = gateway
        self.dnsServers = dnsServers
    }
}

public struct RadioInfo: Equatable, Identifiable {
    public var id: String
    public var band: String
    public var isEnabled: Bool?
    public var ssid: String?
    public var channel: Int?
    public var channelWidth: String?
    public var security: String?

    public var channelLabel: String {
        guard let channel else { return "Auto" }
        return channel == 0 ? "Auto" : "\(channel)"
    }

    /// "2.4 GHz", "5 GHz Low", ...
    public var bandLabel: String { BandFormat.label(band) ?? band }

    /// Short security label: "WPA2", "WPA3", "WPA2/WPA3", "Open".
    public var securityLabel: String? {
        guard let security, !security.isEmpty else { return nil }
        let lower = security.lowercased()
        if lower == "none" || lower == "open" { return "Open" }
        let cleaned = security
            .replacingOccurrences(of: "-Personal", with: "")
            .replacingOccurrences(of: "-Enterprise", with: " Ent")
            .replacingOccurrences(of: "Mixed", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? security : cleaned
    }

    /// Chip text without the SSID, e.g. "ch 36 · 80 MHz · WPA3".
    public var chipDetail: String {
        var parts = [channel == nil || channel == 0 ? "Auto ch" : "ch \(channelLabel)"]
        if let width = channelWidth, !width.isEmpty, width.lowercased() != "auto" {
            parts.append(width.replacingOccurrences(of: "MHz", with: " MHz"))
        }
        if let securityLabel { parts.append(securityLabel) }
        return parts.joined(separator: " · ")
    }

    /// Band from the radio's `band` field when present, otherwise from its ID
    /// (`RADIO_5GHz` -> `5GHz`, `RADIO_5GHz_2` -> `5GHz_2`).
    public static func band(radioID: String, bandField: String?) -> String {
        if let bandField, !bandField.isEmpty { return bandField }
        if radioID.uppercased().hasPrefix("RADIO_") { return String(radioID.dropFirst(6)) }
        return radioID
    }
}

public struct SpeedTestResult: Equatable {
    public var resultID: Int?
    public var timestamp: Date?
    public var latencyMilliseconds: Double?
    public var downloadRaw: Double?
    public var uploadRaw: Double?
    public var downloadMbps: Double?
    public var uploadMbps: Double?
    public var exitCode: String?
    public var isComplete: Bool

    /// The router finished the run but reported an error exit code.
    public var failed: Bool {
        guard let code = exitCode?.lowercased() else { return false }
        return code.contains("error") || code.contains("fail")
    }

    public init(
        resultID: Int? = nil,
        timestamp: Date? = nil,
        latencyMilliseconds: Double? = nil,
        downloadRaw: Double? = nil,
        uploadRaw: Double? = nil,
        downloadMbps: Double? = nil,
        uploadMbps: Double? = nil,
        exitCode: String? = nil,
        isComplete: Bool
    ) {
        self.resultID = resultID
        self.timestamp = timestamp
        self.latencyMilliseconds = latencyMilliseconds
        self.downloadRaw = downloadRaw
        self.uploadRaw = uploadRaw
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.exitCode = exitCode
        self.isComplete = isComplete
    }
}

public struct TopologyOptimization: Equatable {
    public var isEnabled: Bool?
    public var isNodeSteeringEnabled: Bool?

    public init(isEnabled: Bool? = nil, isNodeSteeringEnabled: Bool? = nil) {
        self.isEnabled = isEnabled
        self.isNodeSteeringEnabled = isNodeSteeringEnabled
    }
}

public struct MeshSnapshot: Equatable {
    public var capturedAt: Date
    public var identity: RouterIdentity?
    public var nodes: [MeshNode]
    public var clients: [ClientDevice]
    public var wan: WANStatus?
    public var radios: [RadioInfo]
    public var speedTest: SpeedTestResult?
    public var healthCheckStatus: String?
    public var topologyOptimization: TopologyOptimization?
    public var isDemo: Bool

    public init(
        capturedAt: Date,
        identity: RouterIdentity? = nil,
        nodes: [MeshNode],
        clients: [ClientDevice],
        wan: WANStatus? = nil,
        radios: [RadioInfo] = [],
        speedTest: SpeedTestResult? = nil,
        healthCheckStatus: String? = nil,
        topologyOptimization: TopologyOptimization? = nil,
        isDemo: Bool = false
    ) {
        self.capturedAt = capturedAt
        self.identity = identity
        self.nodes = nodes
        self.clients = clients
        self.wan = wan
        self.radios = radios
        self.speedTest = speedTest
        self.healthCheckStatus = healthCheckStatus
        self.topologyOptimization = topologyOptimization
        self.isDemo = isDemo
    }

    public func node(id: String) -> MeshNode? {
        nodes.first { $0.id == id }
    }

    public func parentName(of node: MeshNode) -> String? {
        guard let parentID = node.parentID else { return nil }
        return self.node(id: parentID)?.name
    }

    /// Roots first, then each node's children. Cycles are not followed twice.
    public var treeOrder: [MeshNode] {
        let ids = Set(nodes.map(\.id))
        let roots = nodes.filter { node in
            node.isPrimary || node.parentID == nil || !ids.contains(node.parentID ?? "")
        }
        var ordered: [MeshNode] = []
        var seen = Set<String>()
        func walk(_ node: MeshNode) {
            guard seen.insert(node.id).inserted else { return }
            ordered.append(node)
            let children = nodes
                .filter { $0.parentID == node.id && $0.id != node.id }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            children.forEach(walk)
        }
        for root in roots.sorted(by: { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }) {
            walk(root)
        }
        for node in nodes where !seen.contains(node.id) {
            ordered.append(node)
        }
        return ordered
    }

    public func clients(of nodeID: String) -> [ClientDevice] {
        clients.filter { $0.parentNodeID == nodeID }
    }
}

public struct HistorySample: Codable, Equatable, Identifiable {
    public static let wanNodeID = "__wan__"

    public var id: UUID
    public var timestamp: Date
    public var nodeID: String
    public var nodeName: String
    public var isOnline: Bool
    public var parentID: String?
    public var speedMbps: Double?
    public var rssiDbm: Int?
    public var connectionType: String?
    public var clientCount: Int
    public var wanConnected: Bool?
    public var wanType: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        nodeID: String,
        nodeName: String,
        isOnline: Bool,
        parentID: String? = nil,
        speedMbps: Double? = nil,
        rssiDbm: Int? = nil,
        connectionType: String? = nil,
        clientCount: Int,
        wanConnected: Bool? = nil,
        wanType: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.isOnline = isOnline
        self.parentID = parentID
        self.speedMbps = speedMbps
        self.rssiDbm = rssiDbm
        self.connectionType = connectionType
        self.clientCount = clientCount
        self.wanConnected = wanConnected
        self.wanType = wanType
    }
}

extension MeshSnapshot {
    public func makeHistorySamples() -> [HistorySample] {
        var samples = nodes.map { node in
            HistorySample(
                timestamp: capturedAt,
                nodeID: node.id,
                nodeName: node.name,
                isOnline: node.isOnline,
                parentID: node.parentID,
                speedMbps: node.isPrimary ? nil : node.backhaul?.speedMbps,
                rssiDbm: node.isPrimary ? nil : node.backhaul?.rssiDbm,
                connectionType: node.backhaul?.medium.rawValue,
                clientCount: node.clientCount,
                wanConnected: wan?.isConnected,
                wanType: wan?.wanType
            )
        }
        samples.append(
            HistorySample(
                timestamp: capturedAt,
                nodeID: HistorySample.wanNodeID,
                nodeName: "WAN",
                isOnline: wan?.isConnected ?? false,
                clientCount: 0,
                wanConnected: wan?.isConnected,
                wanType: wan?.wanType
            )
        )
        return samples
    }
}

/// MAC strings compared by the app are uppercase and colon-separated.
public enum MACAddress {
    public static func normalize(_ raw: String) -> String? {
        let hex = raw.uppercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return nil }
        var parts: [String] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            parts.append(String(hex[index..<next]))
            index = next
        }
        return parts.joined(separator: ":")
    }
}

public struct LocalIdentity: Equatable {
    public var macAddresses: [String]
    public var ipAddresses: [String]

    public init(macAddresses: [String], ipAddresses: [String]) {
        self.macAddresses = macAddresses.compactMap(MACAddress.normalize)
        self.ipAddresses = ipAddresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public enum NodeLocator {
    /// Prefer a MAC match. IP is the fallback because addresses get reused.
    public static func client(matching identity: LocalIdentity, in snapshot: MeshSnapshot) -> ClientDevice? {
        let macs = Set(identity.macAddresses)
        if let match = snapshot.clients.first(where: { client in
            client.macAddresses.contains { macs.contains($0) }
        }) {
            return match
        }
        let ips = Set(identity.ipAddresses)
        return snapshot.clients.first { client in
            guard let ip = client.ipAddress else { return false }
            return ips.contains(ip)
        }
    }

    public static func node(hosting identity: LocalIdentity, in snapshot: MeshSnapshot) -> MeshNode? {
        guard let client = client(matching: identity, in: snapshot),
              let parentID = client.parentNodeID else { return nil }
        return snapshot.node(id: parentID)
    }
}
