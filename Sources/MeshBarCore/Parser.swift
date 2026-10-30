import Foundation

/// Output objects from one poll, keyed by the action that produced them.
/// Missing pieces stay nil. A failed action does not discard the rest.
public struct ParsedActions: Equatable {
    /// True when the router refused actions inside `core/Transaction` that it
    /// answers one at a time, so later polls should skip the batch.
    public var usedSingleCalls = false
    public var deviceInfo: Data?
    public var devices: Data?
    public var backhaul: Data?
    public var wirelessConnections: Data?
    public var wan: Data?
    public var radios: Data?
    public var systemStats: Data?
    public var healthResults: Data?
    public var healthStatus: Data?
    public var topology: Data?
    /// Actions the router refused this poll, with its result code. The rest
    /// of the poll is still shown.
    public var refused: [String: String] = [:]

    public init() {}

    public mutating func store(action: String, output: Data) {
        let name = action.lowercased()
        if name.hasSuffix("/core/getdeviceinfo") {
            deviceInfo = output
        } else if name.hasSuffix("/devicelist/getdevices3") || name.hasSuffix("/devicelist/getdevices") {
            devices = output
        } else if name.hasSuffix("/nodes/diagnostics/getbackhaulinfo2") || name.hasSuffix("/nodes/diagnostics/getbackhaulinfo") {
            backhaul = output
        } else if name.contains("getnodeswirelessnetworkconnections") {
            wirelessConnections = output
        } else if name.contains("getwanstatus") {
            wan = output
        } else if name.contains("getradioinfo") {
            radios = output
        } else if name.contains("getsystemstats") {
            systemStats = output
        } else if name.hasSuffix("/healthcheck/gethealthcheckresults") {
            healthResults = output
        } else if name.hasSuffix("/healthcheck/gethealthcheckstatus") {
            healthStatus = output
        } else if name.contains("gettopologyoptimizationsettings") {
            topology = output
        }
    }
}

/// Turns JNAP JSON into a `MeshSnapshot`.
///
/// Decoding goes through `JSONValue` (Codable). Every field is optional and
/// read by name, with a few aliases (`deviceID` / `deviceUUID`, numeric
/// strings, `result` / `response`). Unknown field names are logged once.
/// A bad entry is skipped. Parsing does not throw.
public enum MeshSnapshotParser {
    public static func parse(
        _ pieces: ParsedActions,
        at date: Date = Date(),
        isDemo: Bool = false
    ) -> MeshSnapshot {
        let devices = flex(pieces.devices, context: "GetDevices3")
        let backhaul = flex(pieces.backhaul, context: "GetBackhaulInfo2")
        let wireless = flex(pieces.wirelessConnections, context: "GetNodesWirelessNetworkConnections2")
        let stats = flex(pieces.systemStats, context: "GetSystemStats2")

        let sightings = wirelessSightings(wireless)
        var drafts = nodeDrafts(from: devices)
        mergeBackhaul(backhaul, into: &drafts)
        applyStats(stats, to: &drafts)

        let nodeIDs = Set(drafts.keys)
        let nodeMACs = Set(drafts.values.compactMap(\.macAddress))
        let clients = clientDevices(from: devices, sightings: sightings, nodeIDs: nodeIDs, nodeMACs: nodeMACs)
        let counts = Dictionary(grouping: clients.filter(\.isOnline), by: { $0.parentNodeID ?? "" })
            .mapValues(\.count)

        let nodes = drafts.values.map { draft -> MeshNode in
            var node = draft.makeNode(knownIDs: nodeIDs, drafts: drafts)
            node.clientCount = counts[node.id] ?? 0
            return node
        }.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return MeshSnapshot(
            capturedAt: date,
            identity: parseIdentity(flex(pieces.deviceInfo, context: "GetDeviceInfo")),
            nodes: nodes,
            clients: clients,
            wan: parseWAN(flex(pieces.wan, context: "GetWANStatus3")),
            radios: parseRadios(flex(pieces.radios, context: "GetRadioInfo3")),
            speedTest: parseSpeedTest(status: pieces.healthStatus, results: pieces.healthResults),
            healthCheckStatus: healthStatusText(flex(pieces.healthStatus, context: "GetHealthCheckStatus")),
            topologyOptimization: parseTopology(flex(pieces.topology, context: "GetTopologyOptimizationSettings2")),
            isDemo: isDemo
        )
    }

    public static func parseSpeedTest(status: Data?, results: Data?) -> SpeedTestResult? {
        let statusFlex = flex(status, context: "GetHealthCheckStatus")
        let resultsFlex = flex(results, context: "GetHealthCheckResults")
        var found: [SpeedTestResult] = []
        if let statusFlex, let parsed = speedTest(from: statusFlex) {
            found.append(parsed)
        }
        if let resultsFlex {
            resultsFlex.logUnknown(
                context: "GetHealthCheckResults",
                known: ["healthCheckResults", "resultID", "timestamp", "speedTestResult", "healthCheckModule"]
            )
            for entry in resultsFlex.objects("healthCheckResults", context: "GetHealthCheckResults.healthCheckResults") {
                if let parsed = speedTest(from: entry) {
                    found.append(parsed)
                }
            }
            if let direct = speedTest(from: resultsFlex) {
                found.append(direct)
            }
        }
        return found.max { lhs, rhs in
            let left = lhs.timestamp ?? .distantPast
            let right = rhs.timestamp ?? .distantPast
            if left == right {
                return (lhs.isComplete ? 1 : 0) < (rhs.isComplete ? 1 : 0)
            }
            return left < right
        }
    }

    public static func passwordAccepted(_ output: Data) -> Bool {
        guard let object = flex(output, context: "CheckAdminPassword") else { return true }
        if let valid = object.bool("isPasswordValid") {
            return valid
        }
        return true
    }

    public static func parseAdminAuthStatus(_ data: Data) -> AdminAuthStatus {
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return AdminAuthStatus(attemptsRemaining: nil, lockoutSecondsRemaining: nil)
        }
        func int(_ value: JSONValue) -> Int? {
            if case let .number(n) = value { return Int(n) }
            if case let .string(text) = value { return Int(text) }
            return nil
        }
        let attempts = object["attemptsRemaining"].flatMap(int)
        // The lockout timer key is not documented. Accept any numeric field
        // that names a delay or remaining time, in seconds.
        let seconds = object
            .filter { key, _ in
                let k = key.lowercased()
                return k != "attemptsremaining" && (k.contains("delay") || k.contains("time") || k.contains("seconds") || k.contains("lock"))
            }
            .compactMap { int($0.value) }
            .max()
        return AdminAuthStatus(attemptsRemaining: attempts, lockoutSecondsRemaining: seconds)
    }

    public static func parseIdentityData(_ data: Data) -> RouterIdentity? {
        parseIdentity(flex(data, context: "GetDeviceInfo"))
    }
}

// MARK: - Tree walking

/// A decoded JSON object. Stored by value so it outlives the decoder.
struct Flex {
    var fields: [String: JSONValue]

    func logUnknown(context: String, known: Set<String>) {
        MeshLog.unknownShape(context, keys: Array(fields.keys), known: known)
    }

    func string(_ keys: String...) -> String? {
        string(anyOf: keys)
    }

    func string(anyOf keys: [String]) -> String? {
        for key in keys {
            guard let value = fields[key], value != .null else { continue }
            if let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
            if let number = value.intValue {
                return String(number)
            }
            if let number = value.doubleValue {
                return String(number)
            }
        }
        return nil
    }

    func double(_ keys: String...) -> Double? {
        double(anyOf: keys)
    }

    func double(anyOf keys: [String]) -> Double? {
        for key in keys {
            if let value = fields[key]?.doubleValue { return value }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        int(anyOf: keys)
    }

    func int(anyOf keys: [String]) -> Int? {
        for key in keys {
            if let value = fields[key]?.intValue { return value }
        }
        return nil
    }

    func bool(_ keys: String...) -> Bool? {
        for key in keys {
            if let value = fields[key]?.boolValue { return value }
        }
        return nil
    }

    func date(_ keys: String...) -> Date? {
        guard let raw = string(anyOf: keys) else { return nil }
        return JNAPDate.parse(raw)
    }

    func object(_ key: String) -> Flex? {
        guard let value = fields[key]?.objectValue else { return nil }
        return Flex(fields: value)
    }

    func objects(_ key: String, context: String) -> [Flex] {
        guard let value = fields[key] else { return [] }
        guard let array = value.arrayValue else {
            MeshLog.shape("\(context) was not an array")
            return []
        }
        return array.compactMap { item in
            guard let object = item.objectValue else {
                MeshLog.shape("Skipped a non-object entry in \(context)")
                return nil
            }
            return Flex(fields: object)
        }
    }

    /// Negative dBm only. Some firmware puts a positive quality score in the same field.
    func rssi(_ keys: String...) -> Int? {
        guard let raw = int(anyOf: keys) ?? double(anyOf: keys).map({ Int($0.rounded()) }) else { return nil }
        // Zero is a common "no measurement" placeholder, not a dBm reading.
        if raw == 0 { return nil }
        guard (-120 ... -1).contains(raw) else {
            MeshLog.shape("Ignored an RSSI field that was not a negative dBm value")
            return nil
        }
        return raw
    }
}

private func flex(_ data: Data?, context: String) -> Flex? {
    guard let data, !data.isEmpty else { return nil }
    do {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let fields = value.objectValue else {
            MeshLog.shape("\(context) output was not a JSON object")
            return nil
        }
        return Flex(fields: fields)
    } catch {
        MeshLog.shape("\(context) output was not valid JSON")
        return nil
    }
}

private struct WirelessSighting {
    var nodeID: String?
    var band: String?
    var rssi: Int?
    var negotiatedMbps: Double?
    var ip: String?
}

private func wirelessSightings(_ root: Flex?) -> [String: WirelessSighting] {
    guard let root else { return [:] }
    root.logUnknown(
        context: "GetNodesWirelessNetworkConnections2",
        known: ["nodeWirelessConnections", "connections", "revision"]
    )
    var byMAC: [String: WirelessSighting] = [:]
    let groups = root.objects("nodeWirelessConnections", context: "nodeWirelessConnections")
    let entries = groups.isEmpty ? [root] : groups
    for group in entries {
        group.logUnknown(
            context: "nodeWirelessConnections.entry",
            known: ["deviceID", "deviceUUID", "connections", "macAddress", "wireless"]
        )
        let nodeID = group.string("deviceID", "deviceUUID")
        let connections = group.objects("connections", context: "nodeWirelessConnections.connections")
        let rows = connections.isEmpty && group.string("macAddress") != nil ? [group] : connections
        for row in rows {
            row.logUnknown(
                context: "wirelessConnection",
                known: [
                    "macAddress", "ipAddress", "negotiatedMbps", "timestamp", "wireless",
                    "txRate", "rxRate", "isMLOCapable", "radioID",
                ]
            )
            guard let mac = row.string("macAddress").flatMap(MACAddress.normalize) else { continue }
            let radio = row.object("wireless")
            radio?.logUnknown(
                context: "wirelessConnection.wireless",
                known: [
                    "band", "signalDecibels", "rssi", "stationRSSI", "bssid", "radioID", "channel",
                    "isGuest", "isMLOCapable", "txRate", "rxRate",
                ]
            )
            byMAC[mac] = WirelessSighting(
                nodeID: nodeID ?? byMAC[mac]?.nodeID,
                band: radio?.string("band", "radioID") ?? row.string("band"),
                rssi: radio?.rssi("signalDecibels", "stationRSSI", "rssi") ?? row.rssi("signalDecibels", "stationRSSI", "rssi"),
                negotiatedMbps: linkRateMbps(row.double("negotiatedMbps", "txRate")),
                ip: row.string("ipAddress")
            )
        }
    }
    return byMAC
}

private struct NodeDraft {
    var id: String
    var name: String
    var role: NodeRole
    var manufacturer: String?
    var modelNumber: String?
    var hardwareVersion: String?
    var summary: String?
    var serialNumber: String?
    var firmwareVersion: String?
    var macAddress: String?
    var ipAddress: String?
    var connectionParentID: String?
    var hasConnection: Bool
    var explicitOffline: Bool
    var backhaulParentID: String?
    var backhaul: BackhaulLink?
    var uptimeSeconds: Int?
    var cpuLoadPercent: Double?
    var memoryLoadPercent: Double?

    func makeNode(knownIDs: Set<String>, drafts: [String: NodeDraft]) -> MeshNode {
        let parentID = resolvedParent(knownIDs: knownIDs, drafts: drafts)
        return MeshNode(
            id: id,
            name: name,
            role: role,
            manufacturer: manufacturer,
            modelNumber: modelNumber,
            hardwareVersion: hardwareVersion,
            summary: summary,
            serialNumber: serialNumber,
            firmwareVersion: firmwareVersion,
            macAddress: macAddress,
            ipAddress: ipAddress,
            isOnline: resolvedOnline,
            uptimeSeconds: uptimeSeconds,
            cpuLoadPercent: cpuLoadPercent,
            memoryLoadPercent: memoryLoadPercent,
            parentID: parentID,
            backhaul: backhaul,
            clientCount: 0
        )
    }

    private var resolvedOnline: Bool {
        if explicitOffline { return false }
        if role == .primary { return true }
        if hasConnection { return true }
        guard let backhaul else { return false }
        if backhaul.medium == .unknown && backhaul.speedMbps == nil && backhaul.rssiDbm == nil && ipAddress == nil {
            return false
        }
        if let speed = backhaul.speedMbps, speed > 0 { return true }
        if backhaul.rssiDbm != nil { return true }
        if backhaul.medium != .unknown && ipAddress != nil { return true }
        return false
    }

    private func resolvedParent(knownIDs: Set<String>, drafts: [String: NodeDraft]) -> String? {
        if role == .primary { return nil }
        if let backhaulParentID, knownIDs.contains(backhaulParentID), backhaulParentID != id {
            return backhaulParentID
        }
        if let parentIP = backhaul?.parentIPAddress {
            if let match = drafts.first(where: { $0.value.ipAddress == parentIP && $0.key != id }) {
                return match.key
            }
        }
        if let connectionParentID, knownIDs.contains(connectionParentID), connectionParentID != id {
            return connectionParentID
        }
        return nil
    }
}

private func nodeDrafts(from root: Flex?) -> [String: NodeDraft] {
    guard let root else { return [:] }
    root.logUnknown(context: "GetDevices3", known: ["devices", "revision", "error", "sinceRevision"])
    var drafts: [String: NodeDraft] = [:]
    for device in root.objects("devices", context: "GetDevices3.devices") {
        guard let draft = nodeDraft(device) else { continue }
        drafts[draft.id] = draft
    }
    return drafts
}

private func nodeDraft(_ device: Flex) -> NodeDraft? {
    device.logUnknown(
        context: "GetDevices3.device",
        known: [
            "deviceID", "deviceUUID", "friendlyName", "nodeType", "isAuthority", "model", "unit",
            "knownInterfaces", "connections", "properties", "lastChangeRevision", "maxAllowedProperties",
            "isHomeKitSupported",
        ]
    )
    let nodeType = device.string("nodeType")?.lowercased()
    let authority = device.bool("isAuthority") ?? false
    let isNode = (nodeType?.isEmpty == false) || authority
    guard isNode else { return nil }
    guard let id = device.string("deviceID", "deviceUUID") else {
        MeshLog.shape("Skipped a node with no device id")
        return nil
    }
    let model = device.object("model")
    model?.logUnknown(
        context: "GetDevices3.model",
        known: ["deviceType", "manufacturer", "modelNumber", "hardwareVersion", "description"]
    )
    let unit = device.object("unit")
    unit?.logUnknown(
        context: "GetDevices3.unit",
        known: ["serialNumber", "firmwareVersion", "firmwareDate"]
    )
    let interfaces = device.objects("knownInterfaces", context: "knownInterfaces")
    let connections = device.objects("connections", context: "connections")
    let mac = interfaces.compactMap { $0.string("macAddress") }.compactMap(MACAddress.normalize).first
        ?? connections.compactMap { $0.string("macAddress") }.compactMap(MACAddress.normalize).first
    let connection = connections.first { $0.bool("isGuest") != true } ?? connections.first
    let role = roleFrom(nodeType: nodeType, isAuthority: authority)
    return NodeDraft(
        id: id,
        name: displayName(device, model: model, fallback: role.label),
        role: role,
        manufacturer: model?.string("manufacturer"),
        modelNumber: model?.string("modelNumber"),
        hardwareVersion: model?.string("hardwareVersion"),
        summary: model?.string("description"),
        serialNumber: unit?.string("serialNumber"),
        firmwareVersion: unit?.string("firmwareVersion"),
        macAddress: mac,
        ipAddress: usableIP(connection?.string("ipAddress", "ipv6Address")),
        connectionParentID: connection?.string("parentDeviceID", "parentDeviceUUID"),
        hasConnection: !connections.isEmpty,
        explicitOffline: false,
        backhaulParentID: nil,
        backhaul: nil,
        uptimeSeconds: nil,
        cpuLoadPercent: nil,
        memoryLoadPercent: nil
    )
}

private func roleFrom(nodeType: String?, isAuthority: Bool) -> NodeRole {
    switch nodeType {
    case "master", "primary", "root":
        return .primary
    case "slave", "secondary", "agent", "node":
        return .secondary
    default:
        return isAuthority ? .primary : .unknown
    }
}

private func displayName(_ device: Flex, model: Flex?, fallback: String) -> String {
    if let custom = propertyValue(device, name: "userDeviceName"), !custom.isEmpty {
        return custom
    }
    if let friendly = device.string("friendlyName"), !friendly.isEmpty {
        return friendly
    }
    if let summary = model?.string("description"), !summary.isEmpty {
        return summary
    }
    if let modelNumber = model?.string("modelNumber"), !modelNumber.isEmpty {
        return modelNumber
    }
    return fallback
}

private func propertyValue(_ device: Flex, name: String) -> String? {
    for property in device.objects("properties", context: "device.properties") {
        let key = property.string("name")?.lowercased()
        if key == name.lowercased() {
            return property.string("value")
        }
    }
    return nil
}

private func mergeBackhaul(_ root: Flex?, into drafts: inout [String: NodeDraft]) {
    guard let root else { return }
    root.logUnknown(
        context: "GetBackhaulInfo2",
        known: ["backhaulDevices", "devices", "timestamp", "revision"]
    )
    let rows = root.objects("backhaulDevices", context: "backhaulDevices")
    for row in rows {
        row.logUnknown(
            context: "backhaulDevice",
            known: [
                "deviceUUID", "deviceID", "ipAddress", "parentIPAddress", "parentDeviceUUID",
                "parentDeviceID", "connectionType", "speedMbps", "timestamp", "wirelessConnectionInfo",
                "stationRSSI", "rssi", "isGuest",
            ]
        )
        guard let id = row.string("deviceUUID", "deviceID") else { continue }
        var draft = drafts[id] ?? NodeDraft(
            id: id,
            name: "Node",
            role: .secondary,
            manufacturer: nil,
            modelNumber: nil,
            hardwareVersion: nil,
            summary: nil,
            serialNumber: nil,
            firmwareVersion: nil,
            macAddress: nil,
            ipAddress: nil,
            connectionParentID: nil,
            hasConnection: false,
            explicitOffline: false,
            backhaulParentID: nil,
            backhaul: nil,
            uptimeSeconds: nil,
            cpuLoadPercent: nil,
            memoryLoadPercent: nil
        )
        let wireless = row.object("wirelessConnectionInfo")
        wireless?.logUnknown(
            context: "wirelessConnectionInfo",
            known: [
                "stationRSSI", "apRSSI", "rssi", "signalDecibels", "radioID", "band", "channel",
                "apBSSID", "stationBSSID", "txRate", "rxRate", "isMultiLinkOperation",
            ]
        )
        let medium = linkMedium(row.string("connectionType"))
        let typeText = row.string("connectionType")?.lowercased() ?? ""
        if ["disconnected", "offline", "down"].contains(typeText) {
            draft.explicitOffline = true
        }
        draft.backhaulParentID = row.string("parentDeviceUUID", "parentDeviceID")
        // GetBackhaulInfo2 carries the node's mesh address. GetDevices3 often
        // reports 0.0.0.0 for extenders, and child nodes name their parent by
        // this address (`parentIPAddress`), so the backhaul value wins.
        if let backhaulIP = usableIP(row.string("ipAddress")) {
            draft.ipAddress = backhaulIP
        }
        // "0.000" means the router has not measured the link yet, which is
        // normal right after a channel change or a node rejoining.
        let rawSpeed = row.double("speedMbps", "speed", "negotiatedMbps")
        draft.backhaul = BackhaulLink(
            medium: medium,
            speedMbps: rawSpeed.flatMap { $0 > 0 ? $0 : nil },
            rssiDbm: wireless?.rssi("stationRSSI", "rssi", "signalDecibels") ?? row.rssi("stationRSSI", "rssi", "signalDecibels"),
            band: wireless?.string("band", "radioID"),
            channel: wireless?.int("channel"),
            parentIPAddress: row.string("parentIPAddress"),
            speedIsMeasuring: rawSpeed.map { $0 <= 0 } ?? false
        )
        drafts[id] = draft
    }
}

/// Pinnacle 2.2 firmware reports `negotiatedMbps` (and `txRate`) in kbit/s
/// despite the name, e.g. 1201000 for a 1201 Mbit/s link. Older firmware and
/// pyvelop captures use Mbit/s. No Wi-Fi client link reaches 10 Gbit/s, so a
/// larger value is read as kbit/s.
func linkRateMbps(_ raw: Double?) -> Double? {
    guard let raw, raw > 0 else { return nil }
    return raw >= 10_000 ? raw / 1000 : raw
}

/// Drops placeholder addresses such as `0.0.0.0` that some firmware reports
/// for nodes whose address lives elsewhere.
private func usableIP(_ raw: String?) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    if raw == "0.0.0.0" || raw == "::" { return nil }
    return raw
}

private func linkMedium(_ raw: String?) -> LinkMedium {
    switch raw?.lowercased() {
    case "wired", "ethernet", "cable":
        return .wired
    case "wireless", "wifi", "wi-fi", "wlan":
        return .wireless
    default:
        return .unknown
    }
}

private func applyStats(_ root: Flex?, to drafts: inout [String: NodeDraft]) {
    guard let root else { return }
    root.logUnknown(
        context: "GetSystemStats2",
        known: [
            "uptimeSeconds", "uptime", "UpTime", "CPULoad", "cpuLoad", "MemoryLoad", "memoryLoad",
            "deviceUUID", "deviceID", "deviceStats", "nodes", "stats",
        ]
    )
    let rows = root.objects("deviceStats", context: "deviceStats")
        + root.objects("nodes", context: "stats.nodes")
        + root.objects("stats", context: "stats")
    if rows.isEmpty {
        guard let primaryID = drafts.first(where: { $0.value.role == .primary })?.key ?? drafts.keys.first else {
            return
        }
        apply(stats: root, to: primaryID, drafts: &drafts)
        return
    }
    for row in rows {
        guard let id = row.string("deviceUUID", "deviceID"), drafts[id] != nil else { continue }
        apply(stats: row, to: id, drafts: &drafts)
    }
}

private func apply(stats: Flex, to id: String, drafts: inout [String: NodeDraft]) {
    guard var draft = drafts[id] else { return }
    draft.uptimeSeconds = stats.int("uptimeSeconds", "uptime", "UpTime")
    draft.cpuLoadPercent = stats.double("CPULoad", "cpuLoad")
    draft.memoryLoadPercent = stats.double("MemoryLoad", "memoryLoad")
    drafts[id] = draft
}

private func clientDevices(
    from root: Flex?,
    sightings: [String: WirelessSighting],
    nodeIDs: Set<String>,
    nodeMACs: Set<String>
) -> [ClientDevice] {
    guard let root else { return [] }
    var clients: [ClientDevice] = []
    for device in root.objects("devices", context: "GetDevices3.devices") {
        let nodeType = device.string("nodeType")?.lowercased()
        let authority = device.bool("isAuthority") ?? false
        if nodeType?.isEmpty == false || authority { continue }
        guard let client = makeClient(device, sightings: sightings, nodeIDs: nodeIDs, nodeMACs: nodeMACs) else {
            continue
        }
        clients.append(client)
    }
    return clients.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

private func makeClient(
    _ device: Flex,
    sightings: [String: WirelessSighting],
    nodeIDs: Set<String>,
    nodeMACs: Set<String>
) -> ClientDevice? {
    let model = device.object("model")
    let interfaces = device.objects("knownInterfaces", context: "knownInterfaces")
    let connections = device.objects("connections", context: "connections")
    var macs = (interfaces + connections).compactMap { $0.string("macAddress") }.compactMap(MACAddress.normalize)
    var seen = Set<String>()
    macs = macs.filter { seen.insert($0).inserted }
    if macs.contains(where: { nodeMACs.contains($0) }) { return nil }
    let id = device.string("deviceID", "deviceUUID") ?? macs.first
    guard let id, !nodeIDs.contains(id) else { return nil }
    let sighting = macs.compactMap { sightings[$0] }.first
    let connection = connections.first { $0.bool("isGuest") != true } ?? connections.first
    let interfaceBand = interfaces.compactMap { $0.string("band") }.first
    let medium: LinkMedium = {
        if sighting != nil || interfaceBand != nil { return .wireless }
        return linkMedium(interfaces.first?.string("interfaceType") ?? connection?.string("interfaceType"))
    }()
    var parent = connection?.string("parentDeviceID", "parentDeviceUUID")
    if parent == nil || !nodeIDs.contains(parent ?? "") {
        if let sightingParent = sighting?.nodeID, nodeIDs.contains(sightingParent) {
            parent = sightingParent
        }
    }
    let online = !connections.isEmpty || sighting != nil
    let unit = device.object("unit")
    let deviceType = model?.string("deviceType")
    let manufacturer = model?.string("manufacturer")
    let modelNumber = model?.string("modelNumber")
    let operatingSystem = unit?.string("operatingSystem")
    let hostName = device.string("hostName", "hostname") ?? connection?.string("hostName", "hostname")
    let friendly = device.string("friendlyName")
    let kind = DeviceKind.classify(
        deviceType: deviceType,
        modelNumber: modelNumber,
        operatingSystem: operatingSystem,
        name: ClientNaming.cleanHost(friendly) ?? ClientNaming.cleanHost(hostName)
    )
    let name = ClientNaming.displayName(
        userDeviceName: propertyValue(device, name: "userDeviceName"),
        friendlyName: friendly,
        hostName: hostName,
        modelNumber: modelNumber ?? model?.string("description"),
        manufacturer: manufacturer,
        kind: kind,
        macAddresses: macs
    )
    return ClientDevice(
        id: id,
        name: name,
        ipAddress: connection?.string("ipAddress", "ipv6Address") ?? sighting?.ip,
        macAddresses: macs,
        parentNodeID: parent,
        band: sighting?.band ?? interfaceBand,
        rssiDbm: sighting?.rssi,
        medium: medium,
        isGuest: connection?.bool("isGuest") ?? false,
        isOnline: online,
        negotiatedMbps: sighting?.negotiatedMbps,
        deviceType: deviceType,
        manufacturer: manufacturer,
        modelNumber: modelNumber,
        operatingSystem: operatingSystem,
        kind: kind
    )
}

private func parseIdentity(_ root: Flex?) -> RouterIdentity? {
    guard let root else { return nil }
    root.logUnknown(
        context: "GetDeviceInfo",
        known: [
            "deviceName", "manufacturer", "modelNumber", "hardwareVersion", "description",
            "serialNumber", "firmwareVersion", "firmwareDate", "services",
        ]
    )
    let identity = RouterIdentity(
        deviceName: root.string("deviceName"),
        manufacturer: root.string("manufacturer"),
        modelNumber: root.string("modelNumber"),
        hardwareVersion: root.string("hardwareVersion"),
        summary: root.string("description"),
        serialNumber: root.string("serialNumber"),
        firmwareVersion: root.string("firmwareVersion"),
        firmwareDate: root.string("firmwareDate")
    )
    let empty = identity.modelNumber == nil && identity.firmwareVersion == nil && identity.deviceName == nil
    return empty ? nil : identity
}

private func parseWAN(_ root: Flex?) -> WANStatus? {
    guard let root else { return nil }
    root.logUnknown(
        context: "GetWANStatus3",
        known: [
            "wanStatus", "wanConnection", "macAddress", "detectedWANType", "linkLocalIPv6Address",
            "supportedWANTypes", "supportedIPv6WANTypes", "supportedWANCombinations",
            "isDetectingWANType", "wanIPv6Connection", "wanIPv6Status",
        ]
    )
    let status = root.string("wanStatus") ?? "Unknown"
    let connection = root.object("wanConnection")
    connection?.logUnknown(
        context: "wanConnection",
        known: [
            "wanType", "ipAddress", "gateway", "dnsServer1", "dnsServer2", "dnsServer3",
            "mtu", "networkPrefixLength", "leaseMinutes", "dhcpLeaseMinutes",
        ]
    )
    var dns: [String] = []
    for key in ["dnsServer1", "dnsServer2", "dnsServer3"] {
        if let value = connection?.string(key), !value.isEmpty { dns.append(value) }
    }
    return WANStatus(
        statusText: status,
        isConnected: status.lowercased() == "connected",
        wanType: connection?.string("wanType") ?? root.string("detectedWANType"),
        ipAddress: connection?.string("ipAddress"),
        gateway: connection?.string("gateway"),
        dnsServers: dns
    )
}

private func parseRadios(_ root: Flex?) -> [RadioInfo] {
    guard let root else { return [] }
    root.logUnknown(context: "GetRadioInfo3", known: ["radios", "isGuestNetworkEnabled", "isBandSteeringSupported"])
    return root.objects("radios", context: "radios").map { radio in
        radio.logUnknown(
            context: "radio",
            known: [
                "radioID", "physicalRadioID", "bssid", "settings", "isEnabled", "ssid", "channel", "channelWidth", "security",
                "band", "defaultMixedMode", "maxRADIUSSharedKeyLength", "supportedChannelsForChannelWidths",
                "supportedModes", "supportedSecurityTypes",
            ]
        )
        let settings = radio.object("settings")
        // Known security objects can carry a passphrase. Only the mode string is kept.
        settings?.logUnknown(
            context: "radio.settings",
            known: [
                "isEnabled", "ssid", "broadcastSSID", "channel", "channelWidth", "wirelessMode",
                "security", "mode",
            ]
        )
        let radioID = radio.string("radioID", "physicalRadioID") ?? "radio"
        let band = RadioInfo.band(radioID: radioID, bandField: radio.string("band"))
        return RadioInfo(
            id: radioID,
            band: band,
            isEnabled: settings?.bool("isEnabled") ?? radio.bool("isEnabled"),
            ssid: settings?.string("ssid") ?? radio.string("ssid"),
            channel: settings?.int("channel") ?? radio.int("channel"),
            channelWidth: settings?.string("channelWidth") ?? radio.string("channelWidth"),
            security: settings?.string("security") ?? radio.string("security")
        )
    }
}

private func parseTopology(_ root: Flex?) -> TopologyOptimization? {
    guard let root else { return nil }
    root.logUnknown(
        context: "GetTopologyOptimizationSettings2",
        known: ["isEnabled", "isNodeSteeringEnabled"]
    )
    return TopologyOptimization(
        isEnabled: root.bool("isEnabled"),
        isNodeSteeringEnabled: root.bool("isNodeSteeringEnabled")
    )
}

private func healthStatusText(_ root: Flex?) -> String? {
    guard let root else { return nil }
    root.logUnknown(
        context: "GetHealthCheckStatus",
        known: [
            "healthCheckStatus", "currentModule", "progressPercent", "speedTestResult",
            "resultID", "timestamp", "exitCode",
        ]
    )
    return root.string("healthCheckStatus", "currentModule")
}

private func speedTest(from object: Flex) -> SpeedTestResult? {
    let payload = object.object("speedTestResult") ?? object
    let exitCode = payload.string("exitCode")
    let downloadKbps = payload.double("downloadBandwidth")
    let uploadKbps = payload.double("uploadBandwidth")
    let downloadLegacy = payload.double("downloadSpeed")
    let uploadLegacy = payload.double("uploadSpeed")
    let download = downloadKbps ?? downloadLegacy
    let upload = uploadKbps ?? uploadLegacy
    let latency = payload.double("latency", "latencyMs")
    let resultID = payload.int("resultID", "resultId") ?? object.int("resultID")
    let timestamp = object.date("timestamp") ?? payload.date("timestamp")
    if exitCode == nil && download == nil && upload == nil && latency == nil && resultID == nil {
        return nil
    }
    let normalized = exitCode?.lowercased()
    let complete = normalized != nil && normalized != "notavailable" && normalized != "unavailable" && normalized != "running"
    // A failed run (e.g. "SpeedTestExecutionError") reports zeros, not a speed.
    let failed = normalized.map { $0.contains("error") || $0.contains("fail") } ?? false
    func mbps(kbps: Double?, legacy: Double?) -> Double? {
        guard !failed else { return nil }
        if let kbps { return BandwidthUnits.megabitsPerSecond(fromKilobits: kbps) }
        return legacy.map(BandwidthUnits.megabitsPerSecond(fromRaw:))
    }
    return SpeedTestResult(
        resultID: resultID,
        timestamp: timestamp,
        latencyMilliseconds: latency,
        downloadRaw: download,
        uploadRaw: upload,
        downloadMbps: mbps(kbps: downloadKbps, legacy: downloadLegacy),
        uploadMbps: mbps(kbps: uploadKbps, legacy: uploadLegacy),
        exitCode: exitCode,
        isComplete: complete
    )
}

/// Output of `core/GetAdminPasswordAuthStatus`.
public struct AdminAuthStatus: Equatable {
    public var attemptsRemaining: Int?
    public var lockoutSecondsRemaining: Int?

    public init(attemptsRemaining: Int?, lockoutSecondsRemaining: Int?) {
        self.attemptsRemaining = attemptsRemaining
        self.lockoutSecondsRemaining = lockoutSecondsRemaining
    }

    public var isLockedOut: Bool {
        attemptsRemaining == 0 || (lockoutSecondsRemaining ?? 0) > 0
    }
}

/// Cleans a typed or pasted router password.
public enum PasswordInput {
    /// Trims leading and trailing spaces, tabs and newlines, which paste and
    /// password managers sometimes add. Inner spaces are kept.
    public static func normalize(_ raw: String) -> (value: String, trimmed: Bool) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value, value != raw)
    }
}
