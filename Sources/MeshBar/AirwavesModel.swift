import Foundation
import MeshBarCore
import os

/// Airwaves: which channels the mesh uses and what else is on the air.
///
/// Sources, all read-only:
/// - `nodes/setup/GetSelectedChannels` + `wirelessap/GetDFSSettings`: channels
///   per node. Cheap; read with the poll at most every two minutes.
/// - The router's `sysinfo.cgi` page: a site survey heard at the router, plus its
///   channel widths, airtime counters and radar events. Slow (~30 s, the radio
///   actually scans), so it only runs when asked and at most once a minute. The
///   page also contains secrets: it is parsed in memory and dropped, never
///   logged or stored.
/// - CoreWLAN on this Mac: what the Mac hears near the node it's joined to.
///
/// Linksys firmware does not say what extenders hear (`GetNodeNeighborInfo`
/// comes back empty), so extenders use the router's survey or a scan from
/// this Mac, labelled as such.
extension AppModel {
    private var airLog: Logger { Logger(subsystem: "com.meshbar.app", category: "airwaves") }

    static let channelReadInterval: TimeInterval = 120
    static let routerScanInterval: TimeInterval = 60

    var primaryNodeID: String? { snapshot?.nodes.first(where: \.isPrimary)?.id }

    var airwavesScans: [AirwavesScan] {
        [routerScan, macScan].compactMap { $0 }
    }

    func airwavesReport(for node: MeshNode) -> NodeAirwavesReport? {
        guard channelPlan != nil || !airwavesScans.isEmpty else { return nil }
        return AirwavesAnalyzer.report(
            node: node,
            plan: channelPlan,
            scans: airwavesScans,
            routerID: primaryNodeID,
            weakBackhaulMbps: settings.thresholds.minimumBackhaulMbps
        )
    }

    func clearAirwaves() {
        channelPlan = nil
        routerScan = nil
        macScan = nil
        airwavesNote = nil
        lastChannelRead = nil
        lastRouterScanStart = nil
    }

    func nodeName(_ id: String?) -> String? {
        guard let id else { return nil }
        return snapshot?.nodes.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.name
    }

    /// Where a scan was heard, in words.
    func heardLabel(_ scan: AirwavesScan) -> String {
        let name = nodeName(scan.heardAtNodeID)
        switch scan.source {
        case .routerScan:
            return "Heard by \(name ?? "the router") (router site survey)"
        case .demo:
            return "Heard by \(name ?? "the router") (demo data)"
        case .thisMac:
            return name.map { "Heard by this Mac, near \($0)" } ?? "Heard by this Mac"
        }
    }

    func readChannelPlan(_ client: JNAPClient, force: Bool) async {
        if !force, let last = lastChannelRead, Date().timeIntervalSince(last) < Self.channelReadInterval { return }
        lastChannelRead = Date()
        guard let selected = try? await client.perform(JNAPCall(action: JNAPAction.getSelectedChannels)) else {
            airLog.notice("GetSelectedChannels unavailable")
            return
        }
        let dfs = try? await client.perform(JNAPCall(action: JNAPAction.getDFSSettings))
        guard !settings.demoMode, let plan = ChannelPlanParser.parse(selectedChannels: selected, dfsSettings: dfs) else { return }
        channelPlan = plan
        airLog.notice("Channel plan: \(plan.radios.count, privacy: .public) radios, DFS \(plan.isDFSEnabled.map { $0 ? "on" : "off" } ?? "unknown", privacy: .public)")
    }

    /// One router site survey. Takes about half a minute because the router
    /// really scans; throttled so repeated clicks cannot hammer it.
    func scanRouterAirwaves(source: String) async {
        if settings.demoMode {
            routerScan = DemoMesh.airwavesScan(at: Date())
            channelPlan = DemoMesh.channelPlan()
            return
        }
        guard !routerScanRunning else { return }
        if let last = lastRouterScanStart, Date().timeIntervalSince(last) < Self.routerScanInterval {
            airwavesNote = "The router scanned less than a minute ago. Try again shortly."
            return
        }
        guard let client = makeClient() else {
            airwavesNote = "Connect to the router first."
            return
        }
        routerScanRunning = true
        lastRouterScanStart = Date()
        airwavesNote = nil
        defer { routerScanRunning = false }
        let started = Date()
        airLog.notice("Router site survey started (\(source, privacy: .public))")
        if channelPlan == nil { await readChannelPlan(client, force: true) }
        do {
            let ownMACs = (snapshot?.nodes ?? []).compactMap(\.macAddress)
            let ownSSIDs = Set((snapshot?.radios ?? []).compactMap(\.ssid).filter { !$0.isEmpty })
            let routerID = primaryNodeID
            // The page holds secrets: parse it here and let it go out of scope.
            let scan = SysinfoAirwavesParser.parse(
                try await client.fetchPage(path: "sysinfo.cgi"),
                capturedAt: Date(),
                heardAtNodeID: routerID,
                ownMACs: ownMACs,
                ownSSIDs: ownSSIDs
            )
            guard !settings.demoMode else { return }
            if scan.networks.isEmpty && scan.stats.isEmpty {
                airwavesNote = "This router's status page has no site survey."
                airLog.notice("Router site survey: no survey sections")
                return
            }
            routerScan = scan
            airLog.notice("Router site survey finished in \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s: \(scan.networks.count, privacy: .public) networks, \(scan.networks.filter(\.isOwnMesh).count, privacy: .public) ours")
        } catch {
            airwavesNote = "The router scan didn't finish. Try again in a minute."
            airLog.notice("Router site survey failed after \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s")
        }
    }

    func scanFromThisMac() async {
        guard !macScanRunning else { return }
        macScanRunning = true
        defer { macScanRunning = false }
        let ownMACs = (snapshot?.nodes ?? []).compactMap(\.macAddress)
        let ownSSIDs = Set((snapshot?.radios ?? []).compactMap(\.ssid).filter { !$0.isEmpty })
        do {
            let result = try await MacWiFiScanner.scan(ownMACs: ownMACs, ownSSIDs: ownSSIDs)
            macScan = AirwavesScan(
                source: .thisMac,
                capturedAt: Date(),
                heardAtNodeID: thisMacNodeID,
                networks: result.networks,
                scannedBands: result.bands
            )
            airwavesNote = result.namesHidden
                ? "macOS hides network names until MeshBar may use Location (System Settings › Privacy & Security › Location Services). Channels and signal are still real."
                : nil
            airLog.notice("Mac scan: \(result.networks.count, privacy: .public) networks, names \(result.namesHidden ? "hidden" : "shown", privacy: .public)")
        } catch {
            airwavesNote = (error as? LocalizedError)?.errorDescription ?? "This Mac couldn't scan."
            airLog.notice("Mac scan failed")
        }
    }
}
