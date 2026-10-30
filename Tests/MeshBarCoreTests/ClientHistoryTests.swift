import Foundation
import SQLite3
import XCTest
@testable import MeshBarCore

/// Event derivation, stats and storage for per-client history. All data is
/// made up: placeholder IDs, documentation-range addresses, invented names.
final class ClientHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// One reading per minute. Each step is (online, node, band, rssi, ip).
    private func samples(
        _ steps: [(Bool, String?, String?, Int?, String?)],
        every interval: TimeInterval = 60,
        from origin: Date? = nil
    ) -> [ClientSample] {
        let origin = origin ?? start
        let names = ["node-a": "Node A", "node-b": "Node B", "node-c": "Node C"]
        return steps.enumerated().map { index, step in
            ClientSample(
                timestamp: origin.addingTimeInterval(Double(index) * interval),
                clientID: "client-1",
                macAddress: "02:00:00:00:00:01",
                name: "Test Laptop",
                nodeID: step.0 ? step.1 : nil,
                nodeName: step.0 ? step.1.flatMap { names[$0] } : nil,
                band: step.0 ? step.2 : nil,
                medium: "wireless",
                rssiDbm: step.0 ? step.3 : nil,
                linkMbps: step.0 ? 400 : nil,
                isOnline: step.0,
                ipAddress: step.4
            )
        }
    }

    private let ip = "192.0.2.10"

    func testSteadyClientHasNoEvents() {
        let steady = samples(Array(repeating: (true, "node-a", "5GHz", -50, ip), count: 10))
        XCTAssertEqual(ClientEventDeriver.events(from: steady), [])
    }

    func testRoamIsOneEventWithBandFolded() {
        var steps = Array(repeating: (true, "node-a" as String?, "5GHz" as String?, -50 as Int?, ip as String?), count: 4)
        steps += Array(repeating: (true, "node-b", "2.4GHz", -60, ip), count: 4)
        let events = ClientEventDeriver.events(from: samples(steps))
        XCTAssertEqual(events.count, 1)
        let roam = try? XCTUnwrap(events.first)
        XCTAssertEqual(roam?.timestamp, start.addingTimeInterval(4 * 60), "event time is when the new node was first seen")
        XCTAssertEqual(roam?.kind, .roamed(fromNodeID: "node-a", fromName: "Node A", toNodeID: "node-b", toName: "Node B", band: "2.4 GHz"))
        XCTAssertEqual(roam?.title, "Roamed Node A → Node B · 2.4 GHz")
        XCTAssertTrue(roam?.isRoam == true)
    }

    func testOfflineAndBackOnline() {
        var steps = Array(repeating: (true, "node-a" as String?, "5GHz" as String?, -50 as Int?, ip as String?), count: 3)
        steps += Array(repeating: (false, nil, nil, nil, ip), count: 5)
        steps += Array(repeating: (true, "node-c", "5GHz", -55, ip), count: 3)
        let events = ClientEventDeriver.events(from: samples(steps))
        XCTAssertEqual(events.map(\.kind), [
            .wentOffline(lastNodeName: "Node A"),
            .cameOnline(nodeName: "Node C", band: "5 GHz"),
        ])
        XCTAssertEqual(events[0].timestamp, start.addingTimeInterval(3 * 60))
        XCTAssertEqual(events[1].timestamp, start.addingTimeInterval(8 * 60))
        XCTAssertTrue(events[0].isDrop)
    }

    func testBandChangeOnSameNode() {
        var steps = Array(repeating: (true, "node-a" as String?, "5GHz" as String?, -50 as Int?, ip as String?), count: 3)
        steps += Array(repeating: (true, "node-a", "2.4GHz", -58, ip), count: 3)
        let events = ClientEventDeriver.events(from: samples(steps))
        XCTAssertEqual(events.map(\.kind), [.bandChanged(from: "5 GHz", to: "2.4 GHz")])
    }

    func testOnePollBlipsAreDebounced() {
        let a = (true, "node-a" as String?, "5GHz" as String?, -50 as Int?, ip as String?)
        let steps = [
            a, a,
            (true, "node-b", "5GHz", -70, ip), // one-poll roam blip
            a, a,
            (false, nil, nil, nil, ip), // one-poll offline blip
            a, a,
            (true, "node-a", "2.4GHz", -50, ip), // one-poll band blip
            a,
            (true, "node-b", "5GHz", -70, ip), // A → B → C → A flapping
            (true, "node-c", "5GHz", -70, ip),
            a, a,
        ]
        XCTAssertEqual(ClientEventDeriver.events(from: samples(steps)), [])
    }

    func testFlappingSettlesIntoOneRoam() {
        let a = (true, "node-a" as String?, "5GHz" as String?, -50 as Int?, ip as String?)
        let b = (true, "node-b" as String?, "5GHz" as String?, -60 as Int?, ip as String?)
        let steps = [a, a, b, a, b, b, b]
        let events = ClientEventDeriver.events(from: samples(steps))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.timestamp, start.addingTimeInterval(4 * 60))
    }

    func testIPChange() {
        var steps = Array(repeating: (true, "node-a" as String?, "5GHz" as String?, -50 as Int?, ip as String?), count: 3)
        steps += Array(repeating: (true, "node-a", "5GHz", -50, "192.0.2.77"), count: 3)
        let events = ClientEventDeriver.events(from: samples(steps))
        XCTAssertEqual(events.map(\.kind), [.ipChanged(from: ip, to: "192.0.2.77")])
    }

    func testGapDropsPendingChange() {
        // One reading on node B, then MeshBar stops polling for an hour and
        // comes back with the client on node A again: no roam.
        let before = samples([(true, "node-a", "5GHz", -50, ip), (true, "node-a", "5GHz", -50, ip), (true, "node-b", "5GHz", -60, ip)])
        let after = samples([(true, "node-a", "5GHz", -50, ip), (true, "node-a", "5GHz", -50, ip)], from: start.addingTimeInterval(3_600))
        XCTAssertEqual(ClientEventDeriver.events(from: before + after), [])
    }

    func testStats() {
        var steps = Array(repeating: (true, "node-a" as String?, "5GHz" as String?, -50 as Int?, ip as String?), count: 31)
        steps += Array(repeating: (true, "node-b", "5GHz", -60, ip), count: 10)
        steps += Array(repeating: (false, nil, nil, nil, ip), count: 5)
        steps += Array(repeating: (true, "node-b", "5GHz", -62, ip), count: 10)
        let history = samples(steps)
        let events = ClientEventDeriver.events(from: history)
        let stats = ClientHistoryStats.compute(samples: history, events: events, since: start)
        XCTAssertEqual(stats.roams, 1)
        XCTAssertEqual(stats.drops, 1)
        XCTAssertEqual(stats.sampleCount, 56)
        XCTAssertEqual(stats.nodeShares.map(\.nodeName), ["Node A", "Node B"])
        XCTAssertEqual(stats.nodeShares.first?.fraction ?? 0, 31.0 / 50.0, accuracy: 0.001)
        XCTAssertEqual(stats.medianRSSI, -50)
        XCTAssertEqual(stats.medianLinkMbps, 400)

        let lastHalfHour = ClientHistoryStats.compute(samples: history, events: events, since: start.addingTimeInterval(40 * 60))
        XCTAssertEqual(lastHalfHour.roams, 0)
        XCTAssertEqual(lastHalfHour.drops, 1)
    }

    func testChartSegmentsSplitOnNodeChangeAndOffline() {
        var steps = Array(repeating: (true, "node-a" as String?, "5GHz" as String?, -50 as Int?, ip as String?), count: 3)
        steps += Array(repeating: (true, "node-b", "5GHz", -60, ip), count: 3)
        steps += [(false, nil, nil, nil, ip)]
        steps += Array(repeating: (true, "node-b", "5GHz", -61, ip), count: 2)
        let points = ClientChartSeries.points(samples(steps))
        XCTAssertEqual(points.count, 8)
        XCTAssertEqual(Set(points.map(\.segment)).count, 3)
        XCTAssertEqual(points.first?.nodeName, "Node A")
    }

    func testSnapshotMakesClientSamples() {
        let snapshot = DemoMesh.snapshot(at: start)
        let made = snapshot.makeClientSamples()
        XCTAssertEqual(made.count, snapshot.clients.count)
        for (sample, client) in zip(made, snapshot.clients) {
            XCTAssertEqual(sample.clientID, client.id)
            XCTAssertEqual(sample.isOnline, client.isOnline)
            if client.isOnline {
                XCTAssertEqual(sample.nodeID, client.parentNodeID)
            } else {
                XCTAssertNil(sample.nodeID)
                XCTAssertNil(sample.rssiDbm)
            }
        }
    }

    func testDemoClientHistoryHasRoamsAndDrops() {
        let history = DemoMesh.seededClientHistory(endingAt: start)
        let byClient = Dictionary(grouping: history, by: \.clientID)
        let events = byClient.values.flatMap { ClientEventDeriver.events(from: $0) }
        XCTAssertTrue(events.contains(where: \.isRoam))
        XCTAssertTrue(events.contains(where: \.isDrop))
    }

    // MARK: Storage

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meshbar-client-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func roundTrip(_ store: HistoryStoring) throws {
        let mine = samples([(true, "node-a", "5GHz", -50, ip), (false, nil, nil, nil, ip), (true, "node-b", "2.4GHz", -66, ip)])
        var other = mine[0]
        other.clientID = "client-2"
        try store.appendClients(mine + [other])
        let loaded = try store.clientSamples(clientID: "client-1", since: .distantPast)
        XCTAssertEqual(loaded, mine)
        XCTAssertEqual(try store.clientSamples(clientID: "client-1", since: start.addingTimeInterval(90)), [mine[2]])
        try store.purge(olderThan: start.addingTimeInterval(30))
        XCTAssertEqual(try store.clientSamples(clientID: "client-1", since: .distantPast), Array(mine.dropFirst()))
        XCTAssertEqual(try store.clientSamples(clientID: "client-2", since: .distantPast), [])
        try store.removeAll()
        XCTAssertEqual(try store.clientSamples(clientID: "client-1", since: .distantPast), [])
    }

    func testSQLiteClientRoundTrip() throws {
        try roundTrip(SQLiteHistoryStore(directory: temporaryDirectory()))
    }

    func testJSONLinesClientRoundTrip() throws {
        try roundTrip(JSONLinesHistoryStore(directory: temporaryDirectory()))
    }

    func testSQLiteMigratesVersionOneDatabase() throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path
        // A round-10 database: node samples only, user_version 0.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE samples (id TEXT PRIMARY KEY, timestamp REAL NOT NULL, node_id TEXT NOT NULL, node_name TEXT NOT NULL,
            is_online INTEGER NOT NULL, parent_id TEXT, speed_mbps REAL, rssi_dbm INTEGER, connection_type TEXT,
            client_count INTEGER NOT NULL, wan_connected INTEGER, wan_type TEXT);
        INSERT INTO samples VALUES ('old-1', 1800000000, 'node-a', 'Node A', 1, NULL, 500, -55, 'Wireless', 3, NULL, NULL);
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = try SQLiteHistoryStore(directory: directory)
        XCTAssertEqual(try store.samples(since: .distantPast, nodeID: nil).count, 1, "existing node history survives")
        try store.appendClients(samples([(true, "node-a", "5GHz", -50, ip)]))
        XCTAssertEqual(try store.clientSamples(clientID: "client-1", since: .distantPast).count, 1)

        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE name = 'idx_client_samples_client'", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
        sqlite3_finalize(statement)
        sqlite3_close(db)

        // Opening again is a no-op.
        XCTAssertNoThrow(try SQLiteHistoryStore(directory: directory))
    }

    // MARK: Speed test units

    private func speedResult(download: Double, upload: Double, exitCode: String) -> SpeedTestResult? {
        let json = """
        {"healthCheckResults":[{"timestamp":"2026-01-01T12:00:00Z","healthCheckModule":"SpeedTest","resultID":3,
        "speedTestResult":{"latency":2,"downloadBandwidth":\(download),"uploadBandwidth":\(upload),"exitCode":"\(exitCode)","resultID":3}}]}
        """
        return MeshSnapshotParser.parseSpeedTest(status: nil, results: Data(json.utf8))
    }

    func testSpeedTestBandwidthIsKilobits() throws {
        // Shape of a real multi-gigabit result: kbps, so about 3.2 / 5.0 Gbps.
        let fast = try XCTUnwrap(speedResult(download: 3_171_513, upload: 5_000_814, exitCode: "Success"))
        XCTAssertEqual(fast.downloadMbps ?? 0, 3171.513, accuracy: 0.001)
        XCTAssertEqual(fast.uploadMbps ?? 0, 5000.814, accuracy: 0.001)
        XCTAssertEqual(fast.downloadRaw, 3_171_513)
        XCTAssertFalse(fast.failed)
        XCTAssertEqual(BandwidthUnits.display(fast.downloadMbps ?? 0).value, "3.17")
        XCTAssertEqual(BandwidthUnits.display(fast.downloadMbps ?? 0).unit, "Gbps")

        // A slow line under 10 Mbps was shown as thousands of Mbps by the old
        // magnitude guess.
        let slow = try XCTUnwrap(speedResult(download: 8_000, upload: 950, exitCode: "Success"))
        XCTAssertEqual(slow.downloadMbps, 8)
        XCTAssertEqual(slow.uploadMbps ?? 0, 0.95, accuracy: 0.0001)
        XCTAssertEqual(BandwidthUnits.display(8).value, "8.0")
        XCTAssertEqual(BandwidthUnits.display(940).value, "940")
    }

    func testFailedSpeedTestHasNoSpeed() throws {
        let failed = try XCTUnwrap(speedResult(download: 0, upload: 0, exitCode: "SpeedTestExecutionError"))
        XCTAssertTrue(failed.failed)
        XCTAssertNil(failed.downloadMbps)
        XCTAssertNil(failed.uploadMbps)
    }
}
