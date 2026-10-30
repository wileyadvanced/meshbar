import XCTest
@testable import MeshBarCore

/// Right after a channel change or a node rejoining, the router reports
/// `speedMbps: "0.000"` until it re-measures. That must read as "measuring",
/// never as a slow link.
final class MeasuringBackhaulTests: XCTestCase {
    private func snapshot(speed: String, rssi: Int = -48) -> MeshSnapshot {
        let devices = Data("""
        {"devices":[
          {"deviceID":"router","nodeType":"Master","connections":[{"ipAddress":"192.168.1.1"}],"properties":[{"name":"userDeviceName","value":"Router"}]},
          {"deviceID":"ext","nodeType":"Slave","connections":[{"isGuest":false}],"properties":[{"name":"userDeviceName","value":"Upstairs"}]}
        ]}
        """.utf8)
        let backhaul = Data("""
        {"backhaulDevices":[
          {"deviceUUID":"ext","parentDeviceUUID":"router","connectionType":"Wireless","speedMbps":"\(speed)",
           "wirelessConnectionInfo":{"radioID":"5GH","channel":100,"apRSSI":-50,"stationRSSI":\(rssi)}}
        ]}
        """.utf8)
        var pieces = ParsedActions()
        pieces.devices = devices
        pieces.backhaul = backhaul
        return MeshSnapshotParser.parse(pieces)
    }

    func testZeroSpeedIsMeasuringNotWeak() throws {
        let snap = snapshot(speed: "0.000")
        let ext = try XCTUnwrap(snap.node(id: "ext"))
        let link = try XCTUnwrap(ext.backhaul)
        XCTAssertNil(link.speedMbps)
        XCTAssertTrue(link.speedIsMeasuring)
        XCTAssertTrue(link.isAwaitingSpeed)
        XCTAssertFalse(HealthEvaluator.backhaulIsDegraded(ext))
        XCTAssertEqual(HealthEvaluator.linkQuality(ext), .healthy)
        XCTAssertEqual(HealthEvaluator.evaluate(snap), .healthy)
    }

    func testMeasuredSpeedClearsTheFlag() throws {
        let link = try XCTUnwrap(snapshot(speed: "173.628").node(id: "ext")?.backhaul)
        XCTAssertEqual(link.speedMbps ?? 0, 173.628, accuracy: 0.001)
        XCTAssertFalse(link.speedIsMeasuring)
        XCTAssertFalse(link.isAwaitingSpeed)
    }

    func testSlowMeasuredSpeedIsStillWeak() throws {
        let ext = try XCTUnwrap(snapshot(speed: "40").node(id: "ext"))
        XCTAssertTrue(HealthEvaluator.backhaulIsDegraded(ext))
    }

    func testMeasuringWithWeakSignalIsStillJudgedOnSignal() throws {
        let ext = try XCTUnwrap(snapshot(speed: "0", rssi: -80).node(id: "ext"))
        XCTAssertTrue(ext.backhaul?.isAwaitingSpeed ?? false)
        XCTAssertTrue(HealthEvaluator.backhaulIsDegraded(ext))
    }
}
