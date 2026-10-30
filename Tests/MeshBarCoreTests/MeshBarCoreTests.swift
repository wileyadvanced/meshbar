import XCTest
@testable import MeshBarCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }
}

final class ParsingTests: XCTestCase {
    func testPinnacleShapedFixture() throws {
        var lines: [String] = []
        let previous = MeshLog.handler
        MeshLog.resetForTests()
        MeshLog.handler = { lines.append($0) }
        defer { MeshLog.handler = previous }

        var pieces = ParsedActions()
        pieces.deviceInfo = try Fixture.data("device-info")
        pieces.devices = try Fixture.data("devices")
        pieces.backhaul = try Fixture.data("backhaul")
        pieces.wirelessConnections = try Fixture.data("wireless")
        pieces.wan = try Fixture.data("wan")
        pieces.radios = try Fixture.data("radios")
        pieces.systemStats = try Fixture.data("stats")
        pieces.healthResults = try Fixture.data("health-results")
        pieces.topology = try Fixture.data("topology")

        let captured = Date(timeIntervalSince1970: 1_750_000_000)
        let snapshot = MeshSnapshotParser.parse(pieces, at: captured, isDemo: false)

        XCTAssertEqual(snapshot.capturedAt, captured)
        XCTAssertEqual(snapshot.identity?.modelNumber, "M62CF-EU")
        XCTAssertEqual(snapshot.identity?.firmwareVersion, "1.2.4")
        XCTAssertEqual(snapshot.nodes.map(\.id), ["node-router", "node-weak", "node-hall", "node-offline"])

        let router = try XCTUnwrap(snapshot.node(id: "node-router"))
        XCTAssertEqual(router.name, "Living Room")
        XCTAssertTrue(router.isPrimary)
        XCTAssertTrue(router.isOnline)
        XCTAssertNil(router.parentID)
        XCTAssertEqual(router.ipAddress, "192.168.1.1")
        XCTAssertEqual(router.modelNumber, "M62CF-EU")
        XCTAssertEqual(router.firmwareVersion, "1.2.4")
        XCTAssertEqual(router.uptimeSeconds, 90000)
        XCTAssertEqual(router.cpuLoadPercent, 12)
        XCTAssertEqual(router.memoryLoadPercent, 41)
        XCTAssertEqual(router.clientCount, 0)

        let hall = try XCTUnwrap(snapshot.node(id: "node-hall"))
        XCTAssertEqual(hall.name, "Hallway")
        XCTAssertEqual(hall.parentID, "node-router")
        XCTAssertEqual(hall.backhaul?.medium, .wireless)
        XCTAssertEqual(hall.backhaul?.speedMbps, 866)
        XCTAssertEqual(hall.backhaul?.rssiDbm, -55)
        XCTAssertEqual(hall.backhaul?.band, "5GHz")
        XCTAssertEqual(hall.backhaul?.channel, 36)
        XCTAssertEqual(hall.clientCount, 1)
        XCTAssertTrue(hall.isOnline)

        let garden = try XCTUnwrap(snapshot.node(id: "node-weak"))
        XCTAssertEqual(garden.name, "Garden Room")
        XCTAssertEqual(garden.parentID, "node-hall")
        XCTAssertEqual(garden.backhaul?.speedMbps, 80)
        XCTAssertEqual(garden.backhaul?.rssiDbm, -74)
        XCTAssertTrue(garden.isOnline)

        let spare = try XCTUnwrap(snapshot.node(id: "node-offline"))
        XCTAssertEqual(spare.name, "Spare Room")
        XCTAssertFalse(spare.isOnline)
        XCTAssertNil(spare.backhaul)

        XCTAssertEqual(snapshot.clients.map(\.name), ["Printer", "Study Laptop"])
        let laptop = try XCTUnwrap(snapshot.clients.first { $0.id == "client-laptop" })
        XCTAssertEqual(laptop.macAddresses, ["02:11:22:00:00:21"])
        XCTAssertEqual(laptop.parentNodeID, "node-hall")
        XCTAssertEqual(laptop.band, "5GHz")
        XCTAssertEqual(laptop.rssiDbm, -48)
        XCTAssertEqual(laptop.negotiatedMbps, 780)
        XCTAssertTrue(laptop.isOnline)
        XCTAssertFalse(try XCTUnwrap(snapshot.clients.first { $0.name == "Printer" }).isOnline)

        XCTAssertEqual(snapshot.wan?.isConnected, true)
        XCTAssertEqual(snapshot.wan?.ipAddress, "203.0.113.10")
        XCTAssertEqual(snapshot.wan?.wanType, "DHCP")
        XCTAssertEqual(snapshot.radios.map(\.band), ["2.4GHz", "5GHz"])
        XCTAssertEqual(snapshot.radios.first?.ssid, "ExampleMesh")
        XCTAssertEqual(snapshot.radios.last?.channelLabel, "Auto")
        XCTAssertEqual(snapshot.speedTest?.downloadMbps, 450)
        XCTAssertEqual(snapshot.speedTest?.uploadMbps, 38)
        XCTAssertEqual(snapshot.speedTest?.latencyMilliseconds, 14)
        XCTAssertEqual(snapshot.speedTest?.isComplete, true)
        XCTAssertEqual(snapshot.topologyOptimization?.isNodeSteeringEnabled, false)
        XCTAssertEqual(HealthEvaluator.evaluate(snapshot), .degraded)

        let log = lines.joined(separator: "\n")
        XCTAssertTrue(log.contains("futureNodeField"))
        XCTAssertTrue(log.contains("wpaPersonalSettings"))
        XCTAssertTrue(log.contains("someNewCounter"))
        XCTAssertFalse(log.contains("should-not-be-stored"))
        XCTAssertFalse(log.contains("DEMO-M62-0001"))
    }

    func testWANDownIsOfflineEvenWhenNodesLookFine() throws {
        var pieces = ParsedActions()
        pieces.wan = try Fixture.data("wan-down")
        pieces.devices = try Fixture.data("devices")
        let snapshot = MeshSnapshotParser.parse(pieces)
        XCTAssertEqual(snapshot.wan?.isConnected, false)
        XCTAssertEqual(HealthEvaluator.evaluate(snapshot), .offline)
    }

    func testMalformedEntriesAreSkipped() {
        let devices = Data(#"{"devices":["nope",{"deviceID":"node-a","nodeType":"Slave","properties":[{"name":"userDeviceName","value":"Loft"}]}]}"#.utf8)
        let backhaul = Data(#"{"backhaulDevices":["bad",{"deviceUUID":"node-b","speedMbps":"fast"}]}"#.utf8)
        var pieces = ParsedActions()
        pieces.devices = devices
        pieces.backhaul = backhaul
        let snapshot = MeshSnapshotParser.parse(pieces)
        XCTAssertEqual(Set(snapshot.nodes.map(\.id)), ["node-a", "node-b"])
        XCTAssertEqual(snapshot.node(id: "node-b")?.name, "Node")
        XCTAssertNil(snapshot.node(id: "node-b")?.backhaul?.speedMbps)
        XCTAssertFalse(snapshot.node(id: "node-b")?.isOnline ?? true)
        let garbage = MeshSnapshotParser.parse(ParsedActions())
        XCTAssertTrue(garbage.nodes.isEmpty)
        var bad = ParsedActions()
        bad.devices = Data("not-json".utf8)
        XCTAssertTrue(MeshSnapshotParser.parse(bad).nodes.isEmpty)
    }

    func testParentIPMatchWhenUUIDMissing() {
        let devices = Data("""
        {"devices":[
            {"deviceID":"root","nodeType":"Master","connections":[{"ipAddress":"192.168.1.1"}]},
            {"deviceID":"ext","nodeType":"Slave","connections":[{"ipAddress":"192.168.1.9"}]}
        ]}
        """.utf8)
        let backhaul = Data("""
        {"backhaulDevices":[
            {"deviceUUID":"ext","parentIPAddress":"192.168.1.1","connectionType":"Wired","speedMbps":1000,"ipAddress":"192.168.1.9"}
        ]}
        """.utf8)
        var pieces = ParsedActions()
        pieces.devices = devices
        pieces.backhaul = backhaul
        let snapshot = MeshSnapshotParser.parse(pieces)
        XCTAssertEqual(snapshot.node(id: "ext")?.parentID, "root")
        XCTAssertEqual(snapshot.node(id: "ext")?.backhaul?.medium, .wired)
        XCTAssertFalse(HealthEvaluator.backhaulIsDegraded(snapshot.node(id: "ext")!))
    }

    func testTransactionSkipsFailedActionAndAcceptsResponseAlias() throws {
        let json = """
        {
          "result": "OK",
          "responses": [
            {"response": "OK", "output": {"wanStatus": "Connected", "wanConnection": {"ipAddress": "203.0.113.10"}}},
            {"result": "ErrorInvalidInput", "output": {}},
            {"result": "OK", "output": {"deviceName": "Linksys-Demo", "modelNumber": "WHW03", "firmwareVersion": "2.1.0"}}
          ]
        }
        """.data(using: .utf8)!
        let parsed = try JNAPResponseDecoder.outputs(
            from: json,
            actions: [JNAPAction.getWANStatus, JNAPAction.getBackhaul, JNAPAction.getDeviceInfo]
        )
        XCTAssertNotNil(parsed.wan)
        XCTAssertNil(parsed.backhaul)
        let snapshot = MeshSnapshotParser.parse(parsed)
        XCTAssertEqual(snapshot.wan?.ipAddress, "203.0.113.10")
        XCTAssertEqual(snapshot.identity?.modelNumber, "WHW03")
        XCTAssertEqual(snapshot.identity?.firmwareVersion, "2.1.0")
    }

    func testPasswordFlagAndJSONTypes() throws {
        let rejected = Data(#"{"isPasswordValid":false}"#.utf8)
        XCTAssertFalse(MeshSnapshotParser.passwordAccepted(rejected))
        XCTAssertTrue(MeshSnapshotParser.passwordAccepted(Data(#"{}"#.utf8)))

        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"n":1,"b":true,"s":"866","f":1.5}"#.utf8))
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["b"], .bool(true))
        XCTAssertEqual(object["n"]?.doubleValue, 1)
        XCTAssertEqual(object["s"]?.doubleValue, 866)
        XCTAssertEqual(object["f"]?.doubleValue, 1.5)
        XCTAssertNotEqual(object["n"], .bool(true))
    }
}

final class HealthAndAlertTests: XCTestCase {
    private let limits = HealthThresholds(minimumBackhaulMbps: 100, minimumRSSI: -70)

    func testThresholdMatrix() {
        let wanUp = WANStatus(statusText: "Connected", isConnected: true)
        XCTAssertEqual(HealthEvaluator.evaluate(snapshot([healthyNode()], wan: wanUp)), .healthy)
        XCTAssertEqual(HealthEvaluator.evaluate(snapshot([healthyNode(), offlineNode()], wan: wanUp)), .degraded)
        XCTAssertEqual(HealthEvaluator.evaluate(snapshot([healthyNode(), slowNode()], wan: wanUp)), .degraded)
        XCTAssertEqual(HealthEvaluator.evaluate(snapshot([healthyNode(), weakSignalNode()], wan: wanUp)), .degraded)
        XCTAssertEqual(
            HealthEvaluator.evaluate(snapshot([healthyNode()], wan: WANStatus(statusText: "Disconnected", isConnected: false))),
            .offline
        )
        XCTAssertEqual(HealthEvaluator.evaluate(MeshSnapshot(capturedAt: Date(), nodes: [], clients: [])), .unknown)

        let borderline = extender(id: "edge", speed: 100, rssi: -70)
        XCTAssertFalse(HealthEvaluator.backhaulIsDegraded(borderline, thresholds: limits))
        XCTAssertTrue(HealthEvaluator.backhaulIsDegraded(extender(id: "slow", speed: 99, rssi: -40), thresholds: limits))
        XCTAssertTrue(HealthEvaluator.backhaulIsDegraded(extender(id: "rssi", speed: 400, rssi: -71), thresholds: limits))

        let wired = MeshNode(
            id: "wired",
            name: "Loft",
            role: .secondary,
            isOnline: true,
            parentID: "router",
            backhaul: BackhaulLink(medium: .wired, speedMbps: 1000, rssiDbm: -80, band: nil, channel: nil, parentIPAddress: nil)
        )
        XCTAssertFalse(HealthEvaluator.backhaulIsDegraded(wired, thresholds: limits))

        let missing = MeshNode(
            id: "unknown-link",
            name: "Loft",
            role: .secondary,
            isOnline: true,
            parentID: "router",
            backhaul: BackhaulLink(medium: .wireless, speedMbps: nil, rssiDbm: nil, band: nil, channel: nil, parentIPAddress: nil)
        )
        XCTAssertFalse(HealthEvaluator.backhaulIsDegraded(missing, thresholds: limits))
        XCTAssertFalse(HealthEvaluator.backhaulIsDegraded(healthyNode(), thresholds: limits))
    }

    func testPositiveRSSIThresholdIsClamped() {
        let odd = HealthThresholds(minimumBackhaulMbps: 100, minimumRSSI: 20).clamped
        XCTAssertEqual(odd.minimumRSSI, -70)
        XCTAssertFalse(HealthEvaluator.backhaulIsDegraded(healthyNode(), thresholds: odd))
    }

    func testAlertsAreEdgeTriggeredAndDebounced() {
        let engine = AlertEngine(debounce: 120)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fine = snapshot([healthyNode(), extender(id: "ext", speed: 400, rssi: -50)])
        XCTAssertTrue(engine.evaluate(previous: nil, current: fine, thresholds: limits, now: start).isEmpty)

        let offline = snapshot([healthyNode(), offlineNode(id: "ext")])
        let first = engine.evaluate(previous: fine, current: offline, thresholds: limits, now: start)
        XCTAssertEqual(first.map(\.kind), [.nodeOffline])

        let still = engine.evaluate(previous: offline, current: offline, thresholds: limits, now: start.addingTimeInterval(10))
        XCTAssertTrue(still.isEmpty)

        let flap = engine.evaluate(previous: fine, current: offline, thresholds: limits, now: start.addingTimeInterval(30))
        XCTAssertTrue(flap.isEmpty, "A repeat inside the debounce window stays quiet")

        let later = engine.evaluate(previous: fine, current: offline, thresholds: limits, now: start.addingTimeInterval(130))
        XCTAssertEqual(later.map(\.kind), [.nodeOffline])

        let moved = snapshot([
            healthyNode(),
            extender(id: "ext", speed: 400, rssi: -50, parent: "other"),
        ])
        let parentAlerts = engine.evaluate(previous: fine, current: moved, thresholds: limits, now: start.addingTimeInterval(400))
        XCTAssertEqual(parentAlerts.map(\.kind), [.parentChanged])
        XCTAssertTrue(parentAlerts[0].body.contains("cannot pin"))

        let weak = snapshot([healthyNode(), extender(id: "ext", speed: 40, rssi: -80)])
        let degraded = engine.evaluate(previous: moved, current: weak, thresholds: limits, now: start.addingTimeInterval(500))
        XCTAssertEqual(degraded.map(\.kind), [.backhaulDegraded])
    }

    private func snapshot(_ nodes: [MeshNode], wan: WANStatus? = WANStatus(statusText: "Connected", isConnected: true)) -> MeshSnapshot {
        MeshSnapshot(capturedAt: Date(timeIntervalSince1970: 10), nodes: nodes, clients: [], wan: wan)
    }

    private func healthyNode() -> MeshNode {
        MeshNode(id: "router", name: "Living Room", role: .primary, ipAddress: "192.168.1.1", isOnline: true)
    }

    private func extender(id: String, speed: Double, rssi: Int, parent: String = "router") -> MeshNode {
        MeshNode(
            id: id,
            name: "Hallway",
            role: .secondary,
            isOnline: true,
            parentID: parent,
            backhaul: BackhaulLink(medium: .wireless, speedMbps: speed, rssiDbm: rssi, band: "5GHz", channel: 36, parentIPAddress: nil)
        )
    }

    private func slowNode() -> MeshNode { extender(id: "slow", speed: 50, rssi: -40) }
    private func weakSignalNode() -> MeshNode { extender(id: "weak", speed: 400, rssi: -75) }
    private func offlineNode(id: String = "down") -> MeshNode {
        MeshNode(id: id, name: "Spare Room", role: .secondary, isOnline: false, parentID: "router")
    }
}

final class CommandAndEndpointTests: XCTestCase {
    func testNodeRestartIsReboot2AndWholeRouterIsSeparate() throws {
        let node = MeshCommands.rebootNode(deviceUUID: "node-hall")
        XCTAssertEqual(node.action, "http://linksys.com/jnap/core/Reboot2")
        XCTAssertNotEqual(node.action, JNAPAction.rebootRouter)
        let body = try JSONDecoder().decode(JSONValue.self, from: node.request.encodedData())
        XCTAssertEqual(body.objectValue?["deviceUUID"], .string("node-hall"))

        let router = MeshCommands.rebootEntireRouter()
        XCTAssertEqual(router.action, "http://linksys.com/jnap/core/Reboot")
        XCTAssertFalse(router.action.hasSuffix("Reboot2"))

        for call in MeshCommands.statusPoll() {
            XCTAssertNotEqual(call.action, JNAPAction.rebootRouter)
            XCTAssertNotEqual(call.action, JNAPAction.rebootNode)
        }
    }

    func testOtherCommands() throws {
        let blink = MeshCommands.blink(deviceID: "node-hall")
        XCTAssertEqual(blink.action, JNAPAction.startBlinking)
        let blinkBody = try JSONDecoder().decode(JSONValue.self, from: blink.request.encodedData())
        XCTAssertEqual(blinkBody.objectValue?["deviceID"], .string("node-hall"))

        XCTAssertEqual(MeshCommands.stopBlinking().request, .object([:]))

        let rename = MeshCommands.rename(deviceID: "client-1", name: "Study Laptop")
        let renameBody = try JSONDecoder().decode(JSONValue.self, from: rename.request.encodedData())
        let property = renameBody.objectValue?["propertiesToModify"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(property?["name"], .string("userDeviceName"))
        XCTAssertEqual(property?["value"], .string("Study Laptop"))

        let speed = MeshCommands.runSpeedTest()
        XCTAssertEqual(speed.action, JNAPAction.runHealthCheck)
        let speedBody = try JSONDecoder().decode(JSONValue.self, from: speed.request.encodedData())
        XCTAssertEqual(speedBody.objectValue?["runHealthCheckModule"], .string("SpeedTest"))

        let results = MeshCommands.healthResults(last: 1)
        let resultsBody = try JSONDecoder().decode(JSONValue.self, from: results.request.encodedData())
        XCTAssertEqual(resultsBody.objectValue?["includeModuleResults"], .bool(true))
        XCTAssertEqual(resultsBody.objectValue?["healthCheckModule"], .string("SpeedTest"))

        XCTAssertEqual(MeshCommands.statusPoll().count, 10)
        let devices = MeshCommands.statusPoll()[1]
        let devicesBody = try JSONDecoder().decode(JSONValue.self, from: devices.request.encodedData())
        XCTAssertEqual(devicesBody.objectValue?["sinceRevision"], .number(0))
    }

    func testBasicAuthAndEndpoint() throws {
        let header = BasicAuthorization.headerValue(username: "admin", password: "example-password")
        let expected = Data("admin:example-password".utf8).base64EncodedString()
        XCTAssertEqual(header, "Basic \(expected)")

        let endpoint = try XCTUnwrap(RouterEndpoint(rawHost: "https://admin:example-password@192.168.1.1:8443/JNAP/", useHTTPS: true))
        XCTAssertEqual(endpoint.host, "192.168.1.1")
        XCTAssertEqual(endpoint.port, 8443)
        let url = try XCTUnwrap(endpoint.url)
        XCTAssertEqual(url.absoluteString, "https://192.168.1.1:8443/JNAP/")
        XCTAssertFalse(url.absoluteString.contains("example-password"))

        let plain = try XCTUnwrap(RouterEndpoint(rawHost: "192.168.1.1", useHTTPS: true))
        XCTAssertEqual(plain.url?.absoluteString, "https://192.168.1.1/JNAP/")
        XCTAssertNil(RouterEndpoint(rawHost: " ", useHTTPS: true))
        XCTAssertNil(RouterEndpoint(rawHost: "bad host", useHTTPS: true))
    }

    func testTrustIsPinnedToTheConfiguredHost() {
        XCTAssertEqual(
            ServerTrustPolicy.decision(trustSelfSigned: false, challengedHost: "192.168.1.1", configuredHost: "192.168.1.1", isServerTrustChallenge: true),
            .defaultHandling
        )
        XCTAssertEqual(
            ServerTrustPolicy.decision(trustSelfSigned: true, challengedHost: "10.0.0.1", configuredHost: "192.168.1.1", isServerTrustChallenge: true),
            .cancel
        )
        XCTAssertEqual(
            ServerTrustPolicy.decision(trustSelfSigned: true, challengedHost: "Linksys.local", configuredHost: "linksys.local", isServerTrustChallenge: true),
            .acceptPinnedHost
        )
        XCTAssertEqual(
            ServerTrustPolicy.decision(trustSelfSigned: true, challengedHost: "192.168.1.1", configuredHost: "192.168.1.1", isServerTrustChallenge: false),
            .defaultHandling
        )
    }

    func testBandwidthHeuristic() {
        XCTAssertEqual(BandwidthUnits.megabitsPerSecond(fromRaw: 450.5), 450.5)
        XCTAssertEqual(BandwidthUnits.megabitsPerSecond(fromRaw: 38_000), 38)
        XCTAssertEqual(BandwidthUnits.megabitsPerSecond(fromRaw: 450_000), 450)
        XCTAssertEqual(BandwidthUnits.megabitsPerSecond(fromRaw: 2_500_000), 2500)
        XCTAssertEqual(BandwidthUnits.megabitsPerSecond(fromRaw: 250_000_000), 250)
    }

    func testClientSendsAuthorizationWithoutPuttingThePasswordInTheURL() async throws {
        let transport = ScriptedTransport(response: Data(#"{"result":"OK","output":{"modelNumber":"M62CF-EU"}}"#.utf8))
        let endpoint = try XCTUnwrap(RouterEndpoint(rawHost: "192.168.1.1", useHTTPS: true))
        let client = JNAPClient(
            configuration: JNAPClient.Configuration(
                endpoint: endpoint,
                username: "admin",
                password: "example-password",
                trustSelfSignedCertificate: false
            ),
            transport: transport
        )
        let output = try await client.perform(MeshCommands.deviceInfo())
        let identity = MeshSnapshotParser.parseIdentityData(output)
        XCTAssertEqual(identity?.modelNumber, "M62CF-EU")
        XCTAssertEqual(transport.lastHeaders["X-JNAP-Action"], JNAPAction.getDeviceInfo)
        XCTAssertEqual(
            transport.lastHeaders["X-JNAP-Authorization"],
            BasicAuthorization.headerValue(username: "admin", password: "example-password")
        )
        XCTAssertEqual(transport.lastHeaders["Content-Type"], "application/json")
        XCTAssertFalse(transport.lastURL?.absoluteString.contains("example-password") ?? true)

        let batch = ScriptedTransport(response: Data(#"{"result":"OK","responses":[]}"#.utf8))
        let batchClient = JNAPClient(
            configuration: client.configuration,
            transport: batch
        )
        _ = try await batchClient.transaction([MeshCommands.deviceInfo()])
        XCTAssertEqual(batch.lastHeaders["X-JNAP-Action"], JNAPAction.transaction)
        let body = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(batch.lastBody))
        XCTAssertEqual(body.arrayValue?.first?.objectValue?["action"], .string(JNAPAction.getDeviceInfo))
        XCTAssertEqual(body.arrayValue?.first?.objectValue?["request"], .object([:]))
    }

    func testRejectedPassword() async {
        let transport = ScriptedTransport(response: Data(#"{"result":"ErrorInvalidAdminPassword","output":{"attemptsRemaining":2}}"#.utf8))
        let endpoint = RouterEndpoint(rawHost: "192.168.1.1", useHTTPS: true)!
        let client = JNAPClient(
            configuration: .init(endpoint: endpoint, username: "admin", password: "example-password", trustSelfSignedCertificate: false),
            transport: transport
        )
        do {
            _ = try await client.perform(MeshCommands.checkAdminPassword())
            XCTFail("Expected the router to reject the password")
        } catch JNAPError.unauthorized {
            XCTAssertFalse(String(describing: transport.lastBody ?? Data()).contains("logged-secret"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }
}

final class HistoryAndDemoTests: XCTestCase {
    func testSQLiteRoundTripAndRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try SQLiteHistoryStore(directory: directory)
        let old = sample(id: "00000000-0000-0000-0000-000000000001", at: Date(timeIntervalSince1970: 1_000), node: "a")
        let recent = sample(id: "00000000-0000-0000-0000-000000000002", at: Date(timeIntervalSince1970: 5_000), node: "b", rssi: -74)
        try store.append([old, recent])
        let all = try store.samples(since: .distantPast, nodeID: nil)
        XCTAssertEqual(all.map(\.id), [old.id, recent.id])
        XCTAssertEqual(all[1].rssiDbm, -74)
        XCTAssertEqual(all[1].wanConnected, true)
        let filtered = try store.samples(since: Date(timeIntervalSince1970: 2_000), nodeID: "b")
        XCTAssertEqual(filtered.map(\.nodeID), ["b"])
        try store.purge(olderThan: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(try store.samples(since: .distantPast, nodeID: nil).map(\.nodeID), ["b"])
    }

    func testJSONLinesRoundTripRetentionAndCorruptLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try JSONLinesHistoryStore(directory: directory)
        let kept = sample(id: "00000000-0000-0000-0000-000000000003", at: Date(timeIntervalSince1970: 8_000), node: "office")
        try store.append([
            sample(id: "00000000-0000-0000-0000-000000000004", at: Date(timeIntervalSince1970: 10), node: "old"),
            kept,
        ])
        let url = directory.appendingPathComponent("history.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        _ = handle.seekToEndOfFile()
        try handle.write(contentsOf: Data("this is not json\n".utf8))
        try handle.close()
        let rows = try store.samples(since: .distantPast, nodeID: nil)
        XCTAssertEqual(rows.map(\.nodeID), ["old", "office"])
        try store.purge(olderThan: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try store.samples(since: .distantPast, nodeID: nil).map(\.nodeName), ["Office"])
    }

    func testDemoMeshIsLabelledAndDaisyChained() {
        let snapshot = DemoMesh.snapshot(at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(snapshot.isDemo)
        XCTAssertEqual(snapshot.nodes.count, 4)
        XCTAssertEqual(snapshot.node(id: DemoMesh.hallwayID)?.parentID, DemoMesh.routerID)
        XCTAssertEqual(snapshot.node(id: DemoMesh.officeID)?.parentID, DemoMesh.hallwayID)
        XCTAssertEqual(snapshot.node(id: DemoMesh.gardenID)?.parentID, DemoMesh.officeID)
        XCTAssertEqual(snapshot.treeOrder.map(\.id), [DemoMesh.routerID, DemoMesh.hallwayID, DemoMesh.officeID, DemoMesh.gardenID])
        XCTAssertEqual(HealthEvaluator.evaluate(snapshot), .degraded)
        XCTAssertEqual(HealthEvaluator.linkQuality(snapshot.node(id: DemoMesh.gardenID)!), .degraded)
        XCTAssertEqual(HealthEvaluator.linkQuality(snapshot.node(id: DemoMesh.hallwayID)!), .healthy)
        XCTAssertEqual(NodeLocator.node(hosting: DemoMesh.thisMac, in: snapshot)?.id, DemoMesh.officeID)
        XCTAssertTrue(snapshot.nodes.allSatisfy { ($0.serialNumber ?? "").hasPrefix("DEMO-") })
        let history = DemoMesh.seededHistory(endingAt: Date(timeIntervalSince1970: 1_800_000_000))
        let garden = history.filter { $0.nodeID == DemoMesh.gardenID }
        XCTAssertFalse(garden.isEmpty)
        XCTAssertTrue(garden.allSatisfy { ($0.rssiDbm ?? 0) < -70 })
        XCTAssertTrue(history.contains { $0.nodeID == HistorySample.wanNodeID && $0.wanConnected == false })
    }

    func testThisMacMatchesMACBeforeIP() {
        let snapshot = DemoMesh.snapshot()
        let byMAC = LocalIdentity(macAddresses: ["02:11:22:00:00:21"], ipAddresses: ["192.168.1.51"])
        XCTAssertEqual(NodeLocator.client(matching: byMAC, in: snapshot)?.name, "Study Laptop")
        let byIP = LocalIdentity(macAddresses: [], ipAddresses: ["192.168.1.52"])
        XCTAssertEqual(NodeLocator.node(hosting: byIP, in: snapshot)?.id, DemoMesh.hallwayID)
    }

    private func sample(id: String, at date: Date, node: String, rssi: Int? = -55) -> HistorySample {
        HistorySample(
            id: UUID(uuidString: id)!,
            timestamp: date,
            nodeID: node,
            nodeName: node == "office" ? "Office" : node.capitalized,
            isOnline: true,
            parentID: "router",
            speedMbps: 866,
            rssiDbm: rssi,
            connectionType: "wireless",
            clientCount: 1,
            wanConnected: true,
            wanType: "DHCP"
        )
    }
}

final class ScriptedTransport: JNAPTransport {
    var lastURL: URL?
    var lastHeaders: [String: String] = [:]
    var lastBody: Data?
    var response: Data

    init(response: Data) {
        self.response = response
    }

    func post(url: URL, headers: [String: String], body: Data) async throws -> Data {
        lastURL = url
        lastHeaders = headers
        lastBody = body
        return response
    }
}
