import XCTest
@testable import MeshBarCore

/// Opt-in check against raw JNAP captures from a real router.
///
/// Set `MESHBAR_LIVE_DIR` to a folder holding one JNAP response per file
/// (`device-info.json`, `devices.json`, `backhaul.json`, `wireless.json`,
/// `wan.json`, `radios.json`, `stats.json`, `health-status.json`,
/// `health-results.json`, `topology.json`). Each file is the full envelope
/// (`{"result": "OK", "output": {...}}`). Missing files are skipped.
/// Keep captures outside the repo: they hold MACs, serials and names.
final class LiveCaptureTests: XCTestCase {
    func testLiveCaptureParses() throws {
        guard let dir = ProcessInfo.processInfo.environment["MESHBAR_LIVE_DIR"] else {
            throw XCTSkip("Set MESHBAR_LIVE_DIR to run against real captures.")
        }
        let files: [(String, String)] = [
            ("device-info", JNAPAction.getDeviceInfo),
            ("devices", JNAPAction.getDevices),
            ("backhaul", JNAPAction.getBackhaul),
            ("wireless", JNAPAction.getWirelessConnections),
            ("wan", JNAPAction.getWANStatus),
            ("radios", JNAPAction.getRadioInfo),
            ("stats", JNAPAction.getSystemStats),
            ("health-status", JNAPAction.getHealthCheckStatus),
            ("health-results", JNAPAction.getHealthCheckResults),
            ("topology", JNAPAction.getTopologyOptimization),
        ]
        var envelopes: [String] = []
        var actions: [String] = []
        for (name, action) in files {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
            envelopes.append(text)
            actions.append(action)
        }
        let body = "{\"result\":\"OK\",\"responses\":[\(envelopes.joined(separator: ","))]}"
        let pieces = try JNAPResponseDecoder.outputs(from: Data(body.utf8), actions: actions)
        let snapshot = MeshSnapshotParser.parse(pieces)

        var lines: [String] = ["LIVE nodes=\(snapshot.nodes.count) clients=\(snapshot.clients.count)"]
        for node in snapshot.treeOrder {
            let parent = snapshot.parentName(of: node) ?? "-"
            let link = node.backhaul.map { "\($0.medium.rawValue) \($0.speedMbps.map { String(Int($0)) } ?? "?")Mbps \($0.rssiDbm.map(String.init) ?? "?")dBm \($0.band ?? "")" } ?? "none"
            lines.append("LIVE node '\(node.name)' role=\(node.role.rawValue) online=\(node.isOnline) parent='\(parent)' link=\(link) clients=\(node.clientCount) uptime=\(node.uptimeSeconds.map(String.init) ?? "?")")
        }
        if let wan = snapshot.wan {
            lines.append("LIVE wan status=\(wan.statusText) connected=\(wan.isConnected) type=\(wan.wanType ?? "?")")
        }
        lines.append("LIVE radios=\(snapshot.radios.map { "\($0.band) ch\($0.channel.map(String.init) ?? "?")" })")
        lines.append("LIVE health=\(HealthEvaluator.evaluate(snapshot).rawValue)")
        if let ip = ProcessInfo.processInfo.environment["MESHBAR_LIVE_IP"] {
            let identity = LocalIdentity(macAddresses: [], ipAddresses: [ip])
            let node = NodeLocator.node(hosting: identity, in: snapshot)
            lines.append("LIVE thisMac(\(ip)) on '\(node?.name ?? "not found")'")
        }
        let online = snapshot.clients.filter(\.isOnline)
        let opaque = snapshot.clients.filter { ClientNaming.isOpaque($0.name) || $0.name.contains("._") }
        let kinds = Dictionary(grouping: snapshot.clients, by: \.kind).map { "\($0.key.rawValue)=\($0.value.count)" }.sorted()
        lines.append("LIVE clients online=\(online.count) opaqueNames=\(opaque.count) kinds=\(kinds)")
        lines.append("LIVE radioChips=\(snapshot.radios.map { "\($0.bandLabel): \($0.chipDetail)" })")
        print(lines.joined(separator: "\n"))
        XCTAssertTrue(opaque.isEmpty, "Some client names are still raw identifiers.")
        XCTAssertFalse(snapshot.nodes.isEmpty, "No mesh nodes parsed from the capture.")
    }
}
