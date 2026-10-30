import XCTest
@testable import MeshBarCore

/// Pinnacle 2.2 answers a batch that holds one admin-only action the same way
/// it answers a wrong password: `result: "Error"`, that child
/// `_ErrorUnauthorized`, every other child `_ErrorAbortedAction`.
final class PollAuthTests: XCTestCase {
    private let endpoint = RouterEndpoint(rawHost: "192.168.1.1", useHTTPS: true)!

    private func client(_ transport: JNAPTransport) -> JNAPClient {
        JNAPClient(
            configuration: .init(endpoint: endpoint, username: "admin", password: "example-password", trustSelfSignedCertificate: false),
            transport: transport
        )
    }

    private let calls = [
        JNAPCall(action: JNAPAction.getDeviceInfo),
        JNAPCall(action: JNAPAction.getDevices),
        JNAPCall(action: JNAPAction.getSystemStats),
    ]

    private let batchWithRefusedStats = Data(#"""
    {"result":"Error","responses":[
      {"result":"_ErrorAbortedAction"},
      {"result":"_ErrorAbortedAction"},
      {"result":"_ErrorUnauthorized"}
    ]}
    """#.utf8)

    func testBatchRefusalWithValidPasswordFallsBackToSingleCalls() async throws {
        let transport = SequencedTransport(responses: [
            batchWithRefusedStats,
            Data(#"{"result":"OK","output":{}}"#.utf8),
            Data(#"{"result":"OK","output":{"modelNumber":"DEMO"}}"#.utf8),
            Data(#"{"result":"OK","output":{"devices":[]}}"#.utf8),
            Data(#"{"result":"_ErrorUnauthorized"}"#.utf8),
        ])
        let parsed = try await client(transport).transaction(calls)
        XCTAssertNotNil(parsed.deviceInfo)
        XCTAssertNotNil(parsed.devices)
        XCTAssertNil(parsed.systemStats)
        XCTAssertTrue(parsed.usedSingleCalls)
        XCTAssertEqual(parsed.refused, [JNAPAction.getSystemStats: "_ErrorUnauthorized"])
        // Batch, one password check, then one request per action.
        XCTAssertEqual(transport.bodies.count, 5)
    }

    func testHealthIsPartialWhenNodesAreMissing() {
        let snapshot = MeshSnapshot(capturedAt: Date(), nodes: [], clients: [], wan: WANStatus(statusText: "Connected", isConnected: true, wanType: "DHCP"))
        XCTAssertEqual(HealthEvaluator.evaluate(snapshot), .partial)
        XCTAssertEqual(MeshHealth.partial.label, "Partial data")
    }

    func testWrongPasswordStillFailsAsPasswordError() async {
        let transport = SequencedTransport(responses: [
            batchWithRefusedStats,
            Data(#"{"result":"_ErrorUnauthorized","error":"echo"}"#.utf8),
        ])
        do {
            _ = try await client(transport).transaction(calls)
            XCTFail("Expected a password error")
        } catch {
            XCTAssertEqual(error as? JNAPError, .unauthorized(code: "_ErrorUnauthorized"))
            // No retry after the password check fails.
            XCTAssertEqual(transport.bodies.count, 2)
        }
    }

    func testTopLevelUnauthorizedIsAPasswordError() {
        let json = Data(#"{"result":"_ErrorUnauthorized"}"#.utf8)
        XCTAssertThrowsError(try JNAPResponseDecoder.outputs(from: json, actions: ["a"])) { error in
            XCTAssertEqual(error as? JNAPError, .unauthorized(code: "_ErrorUnauthorized"))
        }
    }
}
