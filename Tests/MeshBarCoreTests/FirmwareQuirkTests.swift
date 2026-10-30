import XCTest
@testable import MeshBarCore

/// Shapes seen on a real Pinnacle 2.2 (M62CF-EU, firmware 1.2.4) mesh.
/// IDs, MACs and addresses here are made up; only the structure is real.
final class FirmwareQuirkTests: XCTestCase {
    /// GetDevices3 reports 0.0.0.0 for some extenders. Their mesh address is in
    /// GetBackhaulInfo2, and a daisy-chained child names its parent by that address.
    func testDaisyChainResolvesThroughBackhaulAddress() {
        let devices = #"""
        {"revision": 1, "devices": [
          {"deviceID": "demo-root", "nodeType": "Master", "isAuthority": true, "friendlyName": "Root",
           "connections": [{"ipAddress": "192.168.1.1"}], "knownInterfaces": [{"macAddress": "02:00:00:00:00:01", "interfaceType": "Unknown"}]},
          {"deviceID": "demo-middle", "nodeType": "Slave", "isAuthority": false, "friendlyName": "Middle",
           "connections": [{"ipAddress": "0.0.0.0"}], "knownInterfaces": [{"macAddress": "02:00:00:00:00:02", "interfaceType": "Wireless", "band": "5GHz"}]},
          {"deviceID": "demo-top", "nodeType": "Slave", "isAuthority": false, "friendlyName": "Top",
           "connections": [{"ipAddress": "192.168.1.30"}], "knownInterfaces": [{"macAddress": "02:00:00:00:00:03", "interfaceType": "Wireless", "band": "5GHz"}]}
        ]}
        """#
        let backhaul = #"""
        {"backhaulDevices": [
          {"deviceUUID": "demo-top", "ipAddress": "192.168.1.30", "parentIPAddress": "192.168.1.20",
           "connectionType": "Wireless", "speedMbps": "174.513",
           "wirelessConnectionInfo": {"radioID": "5GL", "channel": 36, "apRSSI": -42, "stationRSSI": -55,
             "txRate": 648500, "rxRate": 967380, "isMultiLinkOperation": false}},
          {"deviceUUID": "demo-middle", "ipAddress": "192.168.1.20", "parentIPAddress": "192.168.1.1",
           "connectionType": "Wireless", "speedMbps": "185.113",
           "wirelessConnectionInfo": {"radioID": "5GL", "channel": 36, "apRSSI": -71, "stationRSSI": -38}}
        ]}
        """#
        var pieces = ParsedActions()
        pieces.devices = Data(devices.utf8)
        pieces.backhaul = Data(backhaul.utf8)
        let snapshot = MeshSnapshotParser.parse(pieces)

        XCTAssertEqual(snapshot.node(id: "demo-middle")?.parentID, "demo-root")
        XCTAssertEqual(snapshot.node(id: "demo-middle")?.ipAddress, "192.168.1.20")
        XCTAssertEqual(snapshot.node(id: "demo-top")?.parentID, "demo-middle")
        XCTAssertEqual(snapshot.node(id: "demo-top")?.backhaul?.speedMbps ?? 0, 174.513, accuracy: 0.001)
        XCTAssertEqual(snapshot.node(id: "demo-top")?.backhaul?.rssiDbm, -55)
        XCTAssertEqual(snapshot.treeOrder.map(\.id), ["demo-root", "demo-middle", "demo-top"])
    }

    func testNegotiatedRateInKilobitsIsConverted() {
        XCTAssertEqual(linkRateMbps(1_201_000), 1201)
        XCTAssertEqual(linkRateMbps(780), 780)
        XCTAssertNil(linkRateMbps(0))
        XCTAssertNil(linkRateMbps(nil))
    }

    /// One refused child aborts the whole batch: top-level "Error", the real
    /// error on that child, and `_ErrorAbortedAction` on the rest.
    func testAbortedTransactionReportsTheRefusedChild() {
        let json = Data(#"""
        {"result": "Error", "responses": [
          {"result": "_ErrorAbortedAction"},
          {"result": "_ErrorInvalidInput", "error": "bad field"},
          {"result": "_ErrorAbortedAction"}
        ]}
        """#.utf8)
        XCTAssertThrowsError(try JNAPResponseDecoder.outputs(from: json, actions: ["a", "b", "c"])) { error in
            XCTAssertEqual(error as? JNAPError, .transactionRejected(failedIndices: [1]))
        }
    }

    func testAbortedTransactionWithUnauthorizedChildIsReportedPerChild() {
        let json = Data(#"""
        {"result": "Error", "responses": [
          {"result": "OK", "output": {}},
          {"result": "_ErrorUnauthorized", "error": "Invalid authorization credentials"},
          {"result": "_ErrorAbortedAction"}
        ]}
        """#.utf8)
        XCTAssertThrowsError(try JNAPResponseDecoder.outputs(from: json, actions: ["a", "b", "c"])) { error in
            XCTAssertEqual(error as? JNAPError, .transactionChildUnauthorized(failedIndices: [1], codes: ["_ErrorUnauthorized"]))
        }
    }

    func testClientRetriesWithoutTheRefusedAction() async throws {
        let transport = SequencedTransport(responses: [
            Data(#"{"result":"Error","responses":[{"result":"_ErrorAbortedAction"},{"result":"_ErrorInvalidInput"}]}"#.utf8),
            Data(#"{"result":"OK","responses":[{"result":"OK","output":{"wanStatus":"Connected"}}]}"#.utf8),
        ])
        let endpoint = try XCTUnwrap(RouterEndpoint(rawHost: "192.168.1.1", useHTTPS: true))
        let client = JNAPClient(
            configuration: .init(endpoint: endpoint, username: "admin", password: "example-password", trustSelfSignedCertificate: false),
            transport: transport
        )
        let parsed = try await client.transaction([
            JNAPCall(action: JNAPAction.getWANStatus),
            MeshCommands.healthResults(last: 1),
        ])
        XCTAssertNotNil(parsed.wan)
        XCTAssertNil(parsed.healthResults)
        XCTAssertEqual(transport.bodies.count, 2)
        let retried = try JSONDecoder().decode(JSONValue.self, from: transport.bodies[1])
        XCTAssertEqual(retried.arrayValue?.count, 1)
    }
}

final class SequencedTransport: JNAPTransport {
    var responses: [Data]
    var bodies: [Data] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func post(url: URL, headers: [String: String], body: Data) async throws -> Data {
        bodies.append(body)
        return responses.isEmpty ? Data(#"{"result":"OK","responses":[]}"#.utf8) : responses.removeFirst()
    }
}
