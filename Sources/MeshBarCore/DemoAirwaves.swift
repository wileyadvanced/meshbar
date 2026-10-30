import Foundation

/// Made-up airwaves for demo mode and previews. Names and BSSIDs are fake.
public extension DemoMesh {
    static func channelPlan() -> ChannelPlan {
        ChannelPlan(
            radios: [
                NodeRadio(nodeID: routerID, band: .ghz24, channel: 6, widthMHz: 20),
                NodeRadio(nodeID: routerID, band: .ghz5, channel: 44, widthMHz: 80),
                NodeRadio(nodeID: hallwayID, band: .ghz24, channel: 1, widthMHz: 20),
                NodeRadio(nodeID: hallwayID, band: .ghz5, channel: 44, widthMHz: 80),
                NodeRadio(nodeID: officeID, band: .ghz24, channel: 11, widthMHz: 20),
                NodeRadio(nodeID: officeID, band: .ghz5, channel: 44, widthMHz: 80),
                NodeRadio(nodeID: gardenID, band: .ghz24, channel: 8, widthMHz: 40),
                NodeRadio(nodeID: gardenID, band: .ghz5, channel: 44, widthMHz: 80),
            ],
            isDFSEnabled: false,
            isDFSSupported: true
        )
    }

    static func airwavesScan(at date: Date = Date()) -> AirwavesScan {
        var n = 0
        func net(_ ssid: String?, _ band: WiFiBand, _ ch: Int, _ width: Int, _ rssi: Int, own: Bool = false) -> HeardNetwork {
            n += 1
            let bssid = String(format: "02:00:00:00:%02X:%02X", band == .ghz24 ? 0x24 : 0x50, n)
            return HeardNetwork(id: "demo-\(n)", ssid: ssid, bssid: bssid, band: band, channel: ch, widthMHz: width, rssiDbm: rssi, noiseDbm: -95, isOwnMesh: own)
        }
        let networks = [
            net("ExampleMesh", .ghz24, 6, 20, -38, own: true),
            net("Neighbour-Alpha", .ghz24, 1, 20, -58),
            net("Neighbour-Bravo", .ghz24, 6, 20, -66),
            net(nil, .ghz24, 6, 20, -71),
            net("Neighbour-Charlie", .ghz24, 11, 20, -74),
            net("Printer-Direct", .ghz24, 4, 20, -69),
            net("Neighbour-Delta", .ghz24, 9, 40, -79),
            net("Neighbour-Echo", .ghz24, 11, 20, -83),
            net("ExampleMesh", .ghz5, 44, 80, -35, own: true),
            net("Neighbour-Alpha-5G", .ghz5, 36, 80, -64),
            net("Neighbour-Foxtrot", .ghz5, 48, 80, -72),
            net(nil, .ghz5, 40, 40, -78),
            net("Neighbour-Golf", .ghz5, 100, 80, -86),
            net("Neighbour-Hotel", .ghz5, 149, 80, -88),
        ]
        return AirwavesScan(
            source: .demo,
            capturedAt: date,
            heardAtNodeID: routerID,
            networks: networks,
            stats: [
                RadioAirStats(band: .ghz24, selfUtilization: 9, otherUtilization: 22, noiseFloorDbm: -95),
                RadioAirStats(band: .ghz5, selfUtilization: 4, otherUtilization: 6, noiseFloorDbm: -97),
            ],
            scannerRadios: [
                .ghz24: NodeRadio(nodeID: routerID, band: .ghz24, channel: 6, widthMHz: 20),
                .ghz5: NodeRadio(nodeID: routerID, band: .ghz5, channel: 44, widthMHz: 80),
            ],
            radarEvents: 0,
            scannedBands: [.ghz24, .ghz5]
        )
    }
}
