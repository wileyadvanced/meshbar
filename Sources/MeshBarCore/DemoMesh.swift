import Foundation

/// A fixed 1+3 daisy-chain mesh used for screenshots, CI, and people who do
/// not own a Linksys. Every MAC is locally administered. Nothing here is a
/// real network.
public enum DemoMesh {
    public static let routerID = "demo-router"
    public static let hallwayID = "demo-hallway"
    public static let officeID = "demo-office"
    public static let gardenID = "demo-garden"

    /// The pretend Mac sits on the Office node.
    public static let thisMac = LocalIdentity(
        macAddresses: ["02:11:22:00:00:21"],
        ipAddresses: ["192.168.1.50"]
    )

    public static func snapshot(at date: Date = Date()) -> MeshSnapshot {
        let router = MeshNode(
            id: routerID,
            name: "Living Room",
            role: .primary,
            manufacturer: "Linksys",
            modelNumber: "M62CF-EU",
            hardwareVersion: "1",
            summary: "Pinnacle 2.2",
            serialNumber: "DEMO-M62-0001",
            firmwareVersion: "1.2.4",
            macAddress: "02:11:22:00:00:01",
            ipAddress: "192.168.1.1",
            isOnline: true,
            uptimeSeconds: 345_600,
            cpuLoadPercent: 12,
            memoryLoadPercent: 41,
            clientCount: 1
        )
        let hallway = node(
            id: hallwayID,
            name: "Hallway",
            serial: "DEMO-M60-0002",
            mac: "02:11:22:00:00:02",
            ip: "192.168.1.2",
            parent: routerID,
            speed: 1200,
            rssi: -52,
            channel: 36,
            clients: 1
        )
        let office = node(
            id: officeID,
            name: "Office",
            serial: "DEMO-M60-0003",
            mac: "02:11:22:00:00:03",
            ip: "192.168.1.3",
            parent: hallwayID,
            speed: 866,
            rssi: -61,
            channel: 44,
            clients: 1
        )
        let garden = node(
            id: gardenID,
            name: "Garden Room",
            serial: "DEMO-M60-0004",
            mac: "02:11:22:00:00:04",
            ip: "192.168.1.4",
            parent: officeID,
            speed: 240,
            rssi: -74,
            channel: 44,
            clients: 1
        )
        let clients = [
            ClientDevice(
                id: "demo-phone",
                name: "Phone",
                ipAddress: "192.168.1.51",
                macAddresses: ["02:11:22:00:00:22"],
                parentNodeID: routerID,
                band: "5GHz",
                rssiDbm: -40,
                medium: .wireless,
                isOnline: true,
                negotiatedMbps: 866
            ),
            ClientDevice(
                id: "demo-tv",
                name: "TV",
                ipAddress: "192.168.1.52",
                macAddresses: ["02:11:22:00:00:23"],
                parentNodeID: hallwayID,
                band: "5GHz",
                rssiDbm: -50,
                medium: .wireless,
                isOnline: true,
                negotiatedMbps: 540
            ),
            ClientDevice(
                id: "demo-laptop",
                name: "Study Laptop",
                ipAddress: "192.168.1.50",
                macAddresses: ["02:11:22:00:00:21"],
                parentNodeID: officeID,
                band: "5GHz",
                rssiDbm: -48,
                medium: .wireless,
                isOnline: true,
                negotiatedMbps: 780
            ),
            ClientDevice(
                id: "demo-tablet",
                name: "Tablet",
                ipAddress: "192.168.1.53",
                macAddresses: ["02:11:22:00:00:24"],
                parentNodeID: gardenID,
                band: "5GHz",
                rssiDbm: -78,
                medium: .wireless,
                isOnline: true,
                negotiatedMbps: 144
            ),
            ClientDevice(
                id: "demo-printer",
                name: "Printer",
                macAddresses: ["02:11:22:00:00:25"],
                medium: .wireless,
                isOnline: false
            ),
        ]
        return MeshSnapshot(
            capturedAt: date,
            identity: RouterIdentity(
                deviceName: "Linksys-Demo",
                manufacturer: "Linksys",
                modelNumber: "M62CF-EU",
                hardwareVersion: "1",
                summary: "Pinnacle 2.2",
                serialNumber: "DEMO-M62-0001",
                firmwareVersion: "1.2.4",
                firmwareDate: "2024-05-01T00:00:00Z"
            ),
            nodes: [router, hallway, office, garden],
            clients: clients,
            wan: WANStatus(
                statusText: "Connected",
                isConnected: true,
                wanType: "DHCP",
                ipAddress: "203.0.113.10",
                gateway: "203.0.113.1",
                dnsServers: ["203.0.113.2", "203.0.113.3"]
            ),
            radios: [
                RadioInfo(id: "RADIO_2.4GHz", band: "2.4GHz", isEnabled: true, ssid: "ExampleMesh", channel: 6, channelWidth: "20MHz", security: "WPA2/WPA3-Personal"),
                RadioInfo(id: "RADIO_5GHz", band: "5GHz", isEnabled: true, ssid: "ExampleMesh", channel: 44, channelWidth: "80MHz", security: "WPA2/WPA3-Personal"),
            ],
            speedTest: SpeedTestResult(
                resultID: 1,
                timestamp: date.addingTimeInterval(-3_600),
                latencyMilliseconds: 16,
                downloadRaw: 482_000,
                uploadRaw: 41_000,
                downloadMbps: 482,
                uploadMbps: 41,
                exitCode: "Success",
                isComplete: true
            ),
            healthCheckStatus: "Idle",
            topologyOptimization: TopologyOptimization(isEnabled: true, isNodeSteeringEnabled: true),
            isDemo: true
        )
    }

    /// Six hours of samples so the charts are not empty the moment demo mode starts.
    /// Garden Room stays under the default RSSI threshold on purpose.
    public static func seededHistory(endingAt end: Date = Date(), step: TimeInterval = 600, count: Int = 36) -> [HistorySample] {
        let nodes: [(String, String, Double, Int)] = [
            (hallwayID, "Hallway", 1200, -52),
            (officeID, "Office", 866, -61),
            (gardenID, "Garden Room", 240, -74),
        ]
        var samples: [HistorySample] = []
        for index in 0..<count {
            let timestamp = end.addingTimeInterval(-step * Double(count - 1 - index))
            let wave = sin(Double(index) / 4)
            for (id, name, speed, rssi) in nodes {
                samples.append(
                    HistorySample(
                        timestamp: timestamp,
                        nodeID: id,
                        nodeName: name,
                        isOnline: true,
                        parentID: id == hallwayID ? routerID : (id == officeID ? hallwayID : officeID),
                        speedMbps: speed + wave * 12,
                        rssiDbm: rssi + Int((wave * 2).rounded()),
                        connectionType: LinkMedium.wireless.rawValue,
                        clientCount: 1,
                        wanConnected: index != 12,
                        wanType: "DHCP"
                    )
                )
            }
            samples.append(
                HistorySample(
                    timestamp: timestamp,
                    nodeID: routerID,
                    nodeName: "Living Room",
                    isOnline: true,
                    clientCount: 1,
                    wanConnected: index != 12,
                    wanType: "DHCP"
                )
            )
            samples.append(
                HistorySample(
                    timestamp: timestamp,
                    nodeID: HistorySample.wanNodeID,
                    nodeName: "WAN",
                    isOnline: index != 12,
                    clientCount: 0,
                    wanConnected: index != 12,
                    wanType: "DHCP"
                )
            )
        }
        return samples
    }

    /// Per-client history for the demo: the first wireless client roams
    /// between two nodes, the second drops off now and then, the third
    /// moves between 5 GHz and 2.4 GHz.
    public static func seededClientHistory(endingAt end: Date = Date(), step: TimeInterval = 300, hours: Double = 26) -> [ClientSample] {
        let snapshot = snapshot(at: end)
        let nodes = snapshot.nodes
        let count = Int(hours * 3_600 / step)
        let wireless = snapshot.clients.filter { $0.isOnline && $0.medium != .wired }
        var samples: [ClientSample] = []
        for client in snapshot.clients {
            let role = wireless.firstIndex(where: { $0.id == client.id })
            let homeIndex = nodes.firstIndex(where: { $0.id == client.parentNodeID }) ?? 0
            for index in 0..<count {
                let timestamp = end.addingTimeInterval(-step * Double(count - 1 - index))
                var online = client.isOnline
                var nodeIndex = homeIndex
                var band = client.band
                if role == 0, nodes.count > 1, (index / 40) % 2 == 1 {
                    nodeIndex = (homeIndex + 1) % nodes.count
                }
                if role == 1, index % 90 >= 70, index % 90 < 76 {
                    online = false
                }
                if role == 2, (index / 30) % 2 == 1 {
                    band = "2.4GHz"
                }
                let node = nodes[nodeIndex]
                let away = nodeIndex != homeIndex
                let slow = band == "2.4GHz" && client.band != "2.4GHz"
                let wave = sin(Double(index) / 6 + Double(client.id.count))
                let rssi = client.rssiDbm.map { $0 + Int((wave * 4).rounded()) - (away ? 9 : 0) - (slow ? 4 : 0) }
                let rate = client.negotiatedMbps.map { max(6, ($0 * (1 + wave * 0.12) * (away ? 0.6 : 1) * (slow ? 0.25 : 1)).rounded()) }
                samples.append(
                    ClientSample(
                        timestamp: timestamp,
                        clientID: client.id,
                        macAddress: client.macAddresses.first,
                        name: client.name,
                        nodeID: online ? node.id : nil,
                        nodeName: online ? node.name : nil,
                        band: online ? band : nil,
                        medium: client.medium.rawValue,
                        rssiDbm: online ? rssi : nil,
                        linkMbps: online ? rate : nil,
                        isOnline: online,
                        ipAddress: client.ipAddress
                    )
                )
            }
        }
        return samples
    }

    public static let speedTest = SpeedTestResult(
        resultID: 2,
        timestamp: Date(),
        latencyMilliseconds: 16,
        downloadRaw: 482_000,
        uploadRaw: 41_000,
        downloadMbps: 482,
        uploadMbps: 41,
        exitCode: "Success",
        isComplete: true
    )

    private static func node(
        id: String,
        name: String,
        serial: String,
        mac: String,
        ip: String,
        parent: String,
        speed: Double,
        rssi: Int,
        channel: Int,
        clients: Int
    ) -> MeshNode {
        MeshNode(
            id: id,
            name: name,
            role: .secondary,
            manufacturer: "Linksys",
            modelNumber: "M60CF-EU",
            hardwareVersion: "1",
            summary: "Pinnacle extender",
            serialNumber: serial,
            firmwareVersion: "1.2.4",
            macAddress: mac,
            ipAddress: ip,
            isOnline: true,
            uptimeSeconds: 172_800,
            parentID: parent,
            backhaul: BackhaulLink(
                medium: .wireless,
                speedMbps: speed,
                rssiDbm: rssi,
                band: "5GHz",
                channel: channel,
                parentIPAddress: nil
            ),
            clientCount: clients
        )
    }
}
