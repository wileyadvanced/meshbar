import XCTest
@testable import MeshBarCore

final class AirwavesTests: XCTestCase {
    private let routerID = "AAAAAAAA-0000-4000-8000-000000000001"
    private let extenderID = "AAAAAAAA-0000-4000-8000-000000000002"
    private let ownMACs = ["70:11:22:33:44:F0", "70:11:22:33:55:00"]

    private func text(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func json(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func scan() throws -> AirwavesScan {
        SysinfoAirwavesParser.parse(try text("sysinfo-airwaves"), capturedAt: Date(timeIntervalSince1970: 0), heardAtNodeID: routerID, ownMACs: ownMACs)
    }

    private func plan() throws -> ChannelPlan {
        try XCTUnwrap(ChannelPlanParser.parse(selectedChannels: try json("selected-channels"), dfsSettings: try json("dfs")))
    }

    // MARK: Spectrum math

    func testCentresAndSpans() {
        XCTAssertEqual(WiFiBand.ghz24.centerMHz(channel: 1), 2412)
        XCTAssertEqual(WiFiBand.ghz24.centerMHz(channel: 14), 2484)
        XCTAssertEqual(WiFiBand.ghz5.centerMHz(channel: 36), 5180)
        XCTAssertEqual(WiFiBand.ghz6.centerMHz(channel: 1), 5955)
        XCTAssertEqual(WiFiBand.ghz5.channel(frequencyMHz: 5500), 100)
        // 2.4 GHz 40 MHz: ch 13 bonds downwards, ch 3 upwards.
        XCTAssertEqual(SpectrumMath.span(band: .ghz24, channel: 13, widthMHz: 40), 2442...2482)
        XCTAssertEqual(SpectrumMath.span(band: .ghz24, channel: 3, widthMHz: 40), 2412...2452)
        // 5 GHz 160 MHz block containing ch 44 is 36–64.
        let block = SpectrumMath.span(band: .ghz5, channel: 44, widthMHz: 160)
        XCTAssertEqual(block, 5170...5330)
        XCTAssertEqual(SpectrumMath.channelRangeLabel(band: .ghz5, span: block), "36–64")
        XCTAssertEqual(SpectrumMath.span(band: .ghz5, channel: 104, widthMHz: 80), 5490...5570)
        XCTAssertEqual(SpectrumMath.span(band: .ghz6, channel: 1, widthMHz: 320), 5945...6265)
    }

    func testOverlap() {
        let ch1 = SpectrumMath.span(band: .ghz24, channel: 1, widthMHz: 20)
        let ch6 = SpectrumMath.span(band: .ghz24, channel: 6, widthMHz: 20)
        let ch4 = SpectrumMath.span(band: .ghz24, channel: 4, widthMHz: 20)
        XCTAssertEqual(SpectrumMath.overlapMHz(ch1, ch6), 0)
        XCTAssertEqual(SpectrumMath.overlapMHz(ch1, ch4), 5)
        XCTAssertEqual(SpectrumMath.overlapMHz(ch4, ch6), 10)
    }

    func testPhyModeWidths() {
        XCTAssertEqual(SpectrumMath.width(phyMode: "IEEE80211_MODE_11AXA_HE160").width, 160)
        XCTAssertEqual(SpectrumMath.width(phyMode: "11GEHT40MINUS").width, 40)
        XCTAssertEqual(SpectrumMath.width(phyMode: "11GEHT40MINUS").secondaryBelow, true)
        XCTAssertEqual(SpectrumMath.width(phyMode: "11NGHT40PLUS").secondaryBelow, false)
        XCTAssertEqual(SpectrumMath.width(phyMode: "IEEE80211_MODE_11G").width, 20)
        XCTAssertEqual(SpectrumMath.width(phyMode: "IEEE80211_MODE_11BEA_EHT320").width, 320)
    }

    func testDFSChannels() {
        XCTAssertFalse(WiFiBand.isDFS(36, band: .ghz5))
        XCTAssertTrue(WiFiBand.isDFS(100, band: .ghz5))
        XCTAssertFalse(WiFiBand.isDFS(149, band: .ghz5))
        XCTAssertFalse(WiFiBand.isDFS(100, band: .ghz6))
    }

    // MARK: Parsing

    func testParsesSurvey() throws {
        let scan = try scan()
        XCTAssertEqual(scan.source, .routerScan)
        XCTAssertEqual(scan.scannedBands, [.ghz24, .ghz5, .ghz6])
        XCTAssertEqual(scan.networks.count, 11)
        XCTAssertEqual(scan.networks.filter { $0.band == .ghz6 }.count, 0)

        let a = try XCTUnwrap(scan.networks.first { $0.ssid == "Neighbour-A" })
        XCTAssertEqual(a.band, .ghz24)
        XCTAssertEqual(a.channel, 1)
        XCTAssertEqual(a.rssiDbm, -50)
        XCTAssertEqual(a.noiseDbm, -94)
        XCTAssertEqual(a.widthMHz, 20)
        XCTAssertEqual(a.bssid, "02:00:00:00:24:01")

        // Empty and NUL-filled ESSIDs are hidden networks.
        XCTAssertEqual(scan.networks.filter { $0.ssid == nil }.count, 3)
        XCTAssertEqual(scan.networks.first { $0.bssid == "02:00:00:00:24:02" }?.displayName, "Hidden network")

        let d = try XCTUnwrap(scan.networks.first { $0.ssid == "Neighbour-D" })
        XCTAssertEqual(d.widthMHz, 160)
    }

    func testRecognisesOwnMeshByMACFamily() throws {
        let scan = try scan()
        let own = scan.networks.filter(\.isOwnMesh)
        XCTAssertEqual(own.count, 3, "fronthaul, hidden backhaul and 5 GHz beacons share the node MAC's middle octets")
        XCTAssertTrue(own.allSatisfy { $0.bssid?.contains("11:22:33:44") == true })
        XCTAssertEqual(scan.neighbours(on: .ghz24).count, 4)
        XCTAssertEqual(scan.neighbours(on: .ghz5).count, 4)
    }

    func testParsesRadiosStatsAndRadar() throws {
        let scan = try scan()
        XCTAssertEqual(scan.scannerRadios[.ghz24]?.channel, 13)
        XCTAssertEqual(scan.scannerRadios[.ghz24]?.widthMHz, 40)
        XCTAssertEqual(scan.scannerRadios[.ghz24]?.secondaryBelow, true)
        XCTAssertEqual(scan.scannerRadios[.ghz5]?.channel, 36)
        XCTAssertEqual(scan.scannerRadios[.ghz5]?.widthMHz, 160)
        XCTAssertEqual(scan.scannerRadios[.ghz6]?.channel, 1)
        XCTAssertEqual(scan.scannerRadios[.ghz6]?.widthMHz, 320)
        XCTAssertEqual(scan.stats(for: .ghz24)?.selfUtilization, 12)
        XCTAssertEqual(scan.stats(for: .ghz24)?.otherUtilization, 9)
        XCTAssertEqual(scan.stats(for: .ghz24)?.noiseFloorDbm, -93)
        XCTAssertEqual(scan.stats(for: .ghz5)?.otherUtilization, 35)
        XCTAssertEqual(scan.radarEvents, 2)
    }

    func testParserKeepsNoSecrets() throws {
        let scan = try scan()
        let dump = String(describing: scan)
        XCTAssertFalse(dump.contains("not-a-real-key"))
    }

    func testParsesChannelPlan() throws {
        let plan = try plan()
        XCTAssertEqual(plan.isDFSEnabled, false)
        XCTAssertEqual(plan.isDFSSupported, true)
        XCTAssertEqual(plan.radios.count, 5, "channel 0 entries are skipped")
        // Router IDs come back lowercase; nodes may be uppercase.
        let router = plan.radios(of: routerID)
        XCTAssertEqual(router.map(\.band), [.ghz24, .ghz5, .ghz6])
        XCTAssertEqual(plan.radios(of: extenderID).first?.channel, 7)
    }

    func testEscapedESSID() {
        XCTAssertEqual(SysinfoAirwavesParser.decodeESSID("Caf\\xc3\\xa9"), "Café")
        XCTAssertNil(SysinfoAirwavesParser.decodeESSID("\\x00\\x00"))
        XCTAssertNil(SysinfoAirwavesParser.decodeESSID(""))
    }

    // MARK: Analysis

    private func node(_ id: String, primary: Bool, backhaul: BackhaulLink? = nil) -> MeshNode {
        MeshNode(id: id, name: primary ? "Router" : "Extender", role: primary ? .primary : .secondary, isOnline: true, backhaul: backhaul)
    }

    func testRouterReport() throws {
        let report = AirwavesAnalyzer.report(node: node(routerID, primary: true), plan: try plan(), scans: [try scan()], routerID: routerID)
        XCTAssertTrue(report.scanIsLocal)
        XCTAssertEqual(report.bands.map(\.band), [.ghz24, .ghz5, .ghz6])

        let b24 = try XCTUnwrap(report.assessment(.ghz24))
        XCTAssertEqual(b24.radio.widthMHz, 40, "router width comes from its own settings")
        // 40 MHz on ch 13 covers 9–13: hears ch 11, 12 and 13 neighbours, not ch 1.
        XCTAssertEqual(Set(b24.overlaps.map(\.network.channel)), [11, 12, 13])
        XCTAssertEqual(b24.coChannelCount, 1)

        let b5 = try XCTUnwrap(report.assessment(.ghz5))
        XCTAssertEqual(b5.overlaps.count, 3, "36, 44 and hidden 44 sit inside 36–64; ch 100 doesn't")
        XCTAssertGreaterThanOrEqual(b5.congestion, .busy, "35% neighbour airtime lifts the level")

        let b6 = try XCTUnwrap(report.assessment(.ghz6))
        XCTAssertEqual(b6.congestion, .clear)
        XCTAssertTrue(b6.verdict.contains("to itself"))

        let ids = Set(report.hints.map(\.id))
        XCTAssertTrue(ids.contains { $0.hasPrefix("offgrid-") })
        XCTAssertTrue(ids.contains { $0.hasPrefix("wide5-") })
        XCTAssertTrue(ids.contains { $0.hasPrefix("obss-") })
        XCTAssertFalse(report.hints.contains(where: \.isGeneric), "generic culprits are never mixed into findings")
    }

    func testExtenderUsesRouterScanButSaysSo() throws {
        let link = BackhaulLink(medium: .wireless, speedMbps: 90, rssiDbm: -74, band: "5GHz", channel: 36, parentIPAddress: nil)
        let report = AirwavesAnalyzer.report(node: node(extenderID, primary: false, backhaul: link), plan: try plan(), scans: [try scan()], routerID: routerID)
        XCTAssertFalse(report.scanIsLocal)
        XCTAssertEqual(report.scan?.heardAtNodeID, routerID)
        // The extender's 2.4 GHz width comes from its own beacon in the scan.
        XCTAssertEqual(report.assessment(.ghz24)?.radio.widthMHz, 20)
        XCTAssertEqual(report.assessment(.ghz5)?.radio.widthMHz, 160)
        XCTAssertTrue(report.hints.contains { $0.id.hasPrefix("backhaul-") }, "weak backhaul on a busy channel")
    }

    func testMacScanNearNodeIsLocal() throws {
        let mac = AirwavesScan(source: .thisMac, capturedAt: Date(), heardAtNodeID: extenderID, networks: [], scannedBands: [.ghz5])
        let picked = AirwavesAnalyzer.bestScan(for: extenderID, routerID: routerID, scans: [try scan(), mac])
        XCTAssertEqual(picked?.scan.source, .thisMac)
        XCTAssertEqual(picked?.isLocal, true)
    }

    func testRecommendsOneSixElevenAndNarrowing() {
        func net(_ ch: Int, _ rssi: Int) -> HeardNetwork {
            HeardNetwork(id: "n\(ch)\(rssi)", ssid: "N", bssid: nil, band: .ghz24, channel: ch, widthMHz: 20, rssiDbm: rssi)
        }
        let scan = AirwavesScan(source: .routerScan, capturedAt: Date(), heardAtNodeID: "r", networks: [net(1, -50), net(1, -55), net(4, -60), net(6, -62), net(7, -58)], scannedBands: [.ghz24])
        let radio = NodeRadio(nodeID: "r", band: .ghz24, channel: 4, widthMHz: 20)
        let a = AirwavesAnalyzer.assess(radio: radio, scan: scan, dfsEnabled: false)
        XCTAssertEqual(a.partialCount, 4)
        XCTAssertEqual(a.suggestion?.channel, 11)
        XCTAssertTrue(a.verdict.contains("ch 11"))
    }

    func testDFSSuggestionFlagged() {
        func net(_ ch: Int, _ rssi: Int) -> HeardNetwork {
            HeardNetwork(id: "n\(ch)\(rssi)", ssid: "N", bssid: nil, band: .ghz5, channel: ch, widthMHz: 80, rssiDbm: rssi)
        }
        let scan = AirwavesScan(source: .routerScan, capturedAt: Date(), heardAtNodeID: "r", networks: [net(36, -55), net(40, -58), net(44, -60), net(48, -62)], scannedBands: [.ghz5])
        let radio = NodeRadio(nodeID: "r", band: .ghz5, channel: 36, widthMHz: 80)
        let off = AirwavesAnalyzer.assess(radio: radio, scan: scan, dfsEnabled: false)
        XCTAssertEqual(off.congestion, .crowded)
        XCTAssertEqual(off.suggestion?.needsDFS, true)
        XCTAssertTrue(off.verdict.contains("needs DFS"))
        let on = AirwavesAnalyzer.assess(radio: radio, scan: scan, dfsEnabled: true)
        XCTAssertNotNil(on.suggestion)
        XCTAssertFalse(on.verdict.contains("needs DFS"))
    }

    func testUnscannedBandIsHonest() {
        let scan = AirwavesScan(source: .thisMac, capturedAt: Date(), networks: [], scannedBands: [.ghz24])
        let a = AirwavesAnalyzer.assess(radio: NodeRadio(nodeID: "r", band: .ghz6, channel: 1, widthMHz: 320), scan: scan, dfsEnabled: nil)
        XCTAssertFalse(a.wasScanned)
        XCTAssertNil(a.suggestion)
        XCTAssertTrue(a.verdict.contains("no scan"))
    }

    func testCommonCulpritsAreGeneric() {
        let list = AirwavesAnalyzer.commonCulprits(bands: [.ghz24, .ghz5])
        XCTAssertFalse(list.isEmpty)
        XCTAssertTrue(list.allSatisfy(\.isGeneric))
        XCTAssertTrue(list.contains { $0.title.contains("Microwave") })
    }

    func testDemoAirwavesAreFake() {
        let scan = DemoMesh.airwavesScan()
        XCTAssertTrue(scan.networks.allSatisfy { $0.bssid?.hasPrefix("02:00:00") == true })
        let report = AirwavesAnalyzer.report(node: DemoMesh.snapshot().nodes[0], plan: DemoMesh.channelPlan(), scans: [scan], routerID: DemoMesh.routerID)
        XCTAssertFalse(report.bands.isEmpty)
    }
}
