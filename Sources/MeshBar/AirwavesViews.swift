import Charts
import MeshBarCore
import SwiftUI

enum AirwavesStyle {
    static func color(_ congestion: Congestion?) -> Color {
        switch congestion {
        case .clear?: return .green
        case .light?: return .mint
        case .busy?: return .orange
        case .crowded?: return .red
        case nil: return .secondary
        }
    }

    static func color(_ severity: AirwavesHint.Severity) -> Color {
        switch severity {
        case .warning: return .orange
        case .notice: return .teal
        case .info: return .blue
        }
    }

    static func radioLabel(_ radio: NodeRadio) -> String {
        "ch \(radio.channel)" + (radio.widthMHz.map { " · \($0) MHz" } ?? "")
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func overlapTag(_ overlap: NeighbourOverlap) -> String {
        overlap.isCoChannel ? "same ch" : (overlap.isPartial ? "partial" : "overlaps")
    }
}

// MARK: - Node card chip

/// "RF 13 · 36 · 1" with a dot for the busiest band. Unscanned bands stay grey.
struct RFChip: View {
    var report: NodeAirwavesReport?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(AirwavesStyle.color(report?.worst))
                .frame(width: 6, height: 6)
            Text("RF")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.secondary)
            Text(channels)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.8))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(AirwavesStyle.color(report?.worst).opacity(report?.worst == nil ? 0.08 : 0.14), in: Capsule())
        .help(help)
        .accessibilityLabel(help)
    }

    private var channels: String {
        guard let report, !report.radios.isEmpty else { return "—" }
        return report.radios.sorted { $0.band < $1.band }.map { "\($0.channel)" }.joined(separator: " · ")
    }

    private var help: String {
        guard let report else { return "Channels not read yet" }
        let lines = report.bands.map { band in
            "\(band.band.rawValue) ch \(band.radio.channel): \(band.wasScanned ? band.congestion.label : "not scanned yet")"
        }
        return (["Airwaves, click to open Spectrum"] + lines).joined(separator: "\n")
    }
}

// MARK: - Inspector section

struct AirwavesSection: View {
    @ObservedObject var model: AppModel
    var node: MeshNode
    @State private var expanded: Set<WiFiBand> = []
    @State private var showCulprits = false

    var body: some View {
        let report = model.airwavesReport(for: node)
        InspectorSection(.airwaves, title: "Airwaves", systemName: "antenna.radiowaves.left.and.right", summary: Self.summary(report), trailing: report?.worst?.label) {
            if let report, !report.bands.isEmpty {
                source(report)
                ForEach(Array(report.bands.enumerated()), id: \.element.id) { index, assessment in
                    if index > 0 { Divider() }
                    bandBlock(assessment)
                }
                if !report.hints.isEmpty {
                    Divider()
                    ForEach(report.hints) { HintRow(hint: $0) }
                }
            } else {
                Text(model.settings.demoMode ? "Loading demo airwaves…" : "The router hasn't shared this node's channels yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            AirwavesScanButtons(model: model, compact: true)
            if let note = model.airwavesNote {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(isExpanded: $showCulprits) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Wi-Fi radios only hear Wi-Fi, so MeshBar can't detect these. They're common causes worth ruling out.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(AirwavesAnalyzer.commonCulprits(bands: Set(report?.radios.map(\.band) ?? []))) { HintRow(hint: $0) }
                }
                .padding(.top, 4)
            } label: {
                Text("Common culprits (not detected)").font(.caption.weight(.semibold))
            }
        }
    }

    /// One line for the collapsed header, e.g. "5 GHz ch 100 · light".
    static func summary(_ report: NodeAirwavesReport?) -> String? {
        guard let report, let a = report.assessment(.ghz5) ?? report.bands.first else { return nil }
        var text = "\(a.band.rawValue) ch \(a.radio.channel)"
        if a.wasScanned { text += " · \(a.congestion.label.lowercased())" }
        return text
    }

    @ViewBuilder
    private func source(_ report: NodeAirwavesReport) -> some View {
        if let scan = report.scan {
            Label {
                Text("\(model.heardLabel(scan)) at \(AirwavesStyle.time(scan.capturedAt))")
            } icon: {
                Image(systemName: scan.source == .thisMac ? "laptopcomputer" : "wifi.router")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !report.scanIsLocal, !node.isPrimary {
                Text(scan.source == .thisMac
                     ? "Linksys doesn't report what extenders hear. This is what this Mac heard, so it only describes \(node.name) if the Mac was nearby."
                     : "Linksys doesn't report what extenders hear, so this uses the router's survey. Neighbours near \(node.name) may differ. For a closer look, scan from this Mac while you're near it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Label("Channels from the router. No scan yet, so congestion is unknown.", systemImage: "wifi.router")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func bandBlock(_ a: BandAssessment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(a.band.rawValue).font(.callout.weight(.semibold))
                Text(AirwavesStyle.radioLabel(a.radio)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                if WiFiBand.isDFS(a.radio.channel, band: a.band) { Badge(text: "DFS", tint: .blue) }
                Spacer(minLength: 0)
                if a.wasScanned {
                    Badge(text: a.congestion.label, tint: AirwavesStyle.color(a.congestion))
                }
            }
            Text(a.verdict)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if a.wasScanned {
                HStack(spacing: 12) {
                    metric("Same channel", a.coChannelCount)
                    metric("Overlapping", a.overlaps.count)
                    metric("Strong", a.strongCount)
                }
            }
            if let stats = a.stats {
                Text(statsLine(stats))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Measured by the router's radio: airtime used by our mesh, airtime used by other networks, and the noise floor.")
            }
            if !a.overlaps.isEmpty {
                DisclosureGroup(isExpanded: binding(a.band)) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(a.overlaps.sorted { $0.network.rssiDbm > $1.network.rssiDbm }.prefix(12)) { overlap in
                            NeighbourRow(overlap: overlap)
                        }
                        if a.overlaps.count > 12 {
                            Text("+ \(a.overlaps.count - 12) fainter").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 3)
                } label: {
                    Text("\(a.overlaps.count) neighbouring network\(a.overlaps.count == 1 ? "" : "s") overlap")
                        .font(.caption)
                }
            }
        }
    }

    private func statsLine(_ stats: RadioAirStats) -> String {
        var parts: [String] = []
        if let mine = stats.selfUtilization { parts.append("Our airtime \(mine)%") }
        if let other = stats.otherUtilization { parts.append("neighbours \(other)%") }
        if let nf = stats.noiseFloorDbm { parts.append("noise \(nf) dBm") }
        return parts.joined(separator: " · ")
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func binding(_ band: WiFiBand) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(band) },
            set: { if $0 { expanded.insert(band) } else { expanded.remove(band) } }
        )
    }
}

struct NeighbourRow: View {
    var overlap: NeighbourOverlap

    var body: some View {
        let net = overlap.network
        HStack(spacing: 6) {
            SignalBars(rssi: net.rssiDbm, height: 9)
            Text(net.displayName)
                .italic(net.ssid == nil)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("ch \(net.channel)/\(net.widthMHz)")
                .foregroundStyle(.secondary)
            Text("\(net.rssiDbm)")
                .frame(width: 28, alignment: .trailing)
            Text(AirwavesStyle.overlapTag(overlap))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(overlap.isCoChannel ? Color.primary : Color.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .font(.caption)
        .monospacedDigit()
        .help("\(net.displayName): ch \(net.channel), \(net.widthMHz) MHz, \(net.rssiDbm) dBm (\(net.strength.label))")
    }
}

struct HintRow: View {
    var hint: AirwavesHint

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hint.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hint.isGeneric ? Color.secondary : AirwavesStyle.color(hint.severity))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(hint.title).font(.caption.weight(.semibold))
                Text(hint.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AirwavesScanButtons: View {
    @ObservedObject var model: AppModel
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.scanRouterAirwaves(source: "button") }
            } label: {
                if model.routerScanRunning {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Router scanning…")
                    }
                } else {
                    Label(compact ? "Scan at router" : "Scan at router (~30 s)", systemImage: "wifi.router")
                }
            }
            .disabled(model.routerScanRunning)
            .help("Asks the router for its site survey. Read-only; the radio listens for about 30 seconds. At most once a minute.")
            Button {
                Task { await model.scanFromThisMac() }
            } label: {
                if model.macScanRunning {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Scanning…")
                    }
                } else {
                    Label("Scan from this Mac", systemImage: "laptopcomputer")
                }
            }
            .disabled(model.macScanRunning)
            .help("Scans with this Mac's Wi-Fi. macOS shows network names only if MeshBar may use Location.")
        }
        .controlSize(.small)
    }
}

// MARK: - Spectrum

struct SpectrumView: View {
    @ObservedObject var model: AppModel
    var snapshot: MeshSnapshot
    @AppStorage("meshbar.spectrumBand") private var bandRaw = WiFiBand.ghz24.rawValue
    @State private var listener: Listener = .best

    enum Listener: String, CaseIterable, Identifiable {
        case best = "Best available"
        case router = "Router"
        case mac = "This Mac"
        var id: String { rawValue }
    }

    private static let floor = -100
    private static let ceiling = -20

    private var band: WiFiBand { WiFiBand(rawValue: bandRaw) ?? .ghz24 }
    private var node: MeshNode? { model.selectedNode ?? snapshot.nodes.first(where: \.isPrimary) }
    private var report: NodeAirwavesReport? { node.flatMap { model.airwavesReport(for: $0) } }

    private var scan: AirwavesScan? {
        switch listener {
        case .best: return report?.scan
        case .router: return model.routerScan
        case .mac: return model.macScan
        }
    }

    private var ourRadio: NodeRadio? { report?.radios.first { $0.band == band } }

    private var assessment: BandAssessment? {
        guard let radio = ourRadio else { return nil }
        if listener == .best { return report?.assessment(band) }
        return AirwavesAnalyzer.assess(radio: radio, scan: scan, dfsEnabled: model.channelPlan?.isDFSEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let scan, scan.scannedBands.contains(band) || !scan.networks.filter({ $0.band == band }).isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    chart(scan)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .topTrailing) { scanningBadge }
                    side(scan)
                        .frame(width: 236)
                }
            } else {
                empty
            }
        }
        .dashboardCard(padding: 14)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Spectrum").font(.headline)
                Text(sourceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("Band", selection: $bandRaw) {
                ForEach(WiFiBand.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Node", selection: Binding(get: { model.selectedNodeID }, set: { model.selectedNodeID = $0 })) {
                ForEach(snapshot.treeOrder) { node in
                    Label(node.name, systemImage: node.isPrimary ? "wifi.router" : "dot.radiowaves.left.and.right")
                        .tag(Optional(node.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Whose channels to highlight")
            Picker("Heard by", selection: $listener) {
                ForEach(Listener.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Which scan to draw: the router's site survey or this Mac's own scan")
            Menu {
                Button("Scan at router (~30 s)") { Task { await model.scanRouterAirwaves(source: "spectrum") } }
                    .disabled(model.routerScanRunning)
                Button("Scan from this Mac") {
                    listener = .mac
                    Task { await model.scanFromThisMac() }
                }
                .disabled(model.macScanRunning)
            } label: {
                Label("Scan", systemImage: "dot.radiowaves.left.and.right")
            } primaryAction: {
                Task { await model.scanRouterAirwaves(source: "spectrum") }
            }
            .fixedSize()
            .disabled(model.routerScanRunning && model.macScanRunning)
            .help("Click to scan at the router (read-only, ~30 s). Hold for a scan from this Mac.")
        }
    }

    private var sourceText: String {
        guard let scan else { return "No scan yet" }
        var text = "\(model.heardLabel(scan)) at \(AirwavesStyle.time(scan.capturedAt))"
        if let node, listener == .best, report?.scanIsLocal == false, !node.isPrimary {
            text += " · not heard at \(node.name) itself"
        }
        return text
    }

    @ViewBuilder
    private var scanningBadge: some View {
        if model.routerScanRunning || model.macScanRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.routerScanRunning ? "Router is listening… about 30 s" : "This Mac is scanning…")
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
        }
    }

    // MARK: Chart

    private struct ShapePoint: Identifiable {
        var id: String
        var series: String
        var x: Double
        var y: Int
        var role: Role
    }

    enum Role: String {
        case own = "Our mesh"
        case overlapping = "Overlaps our channel"
        case other = "Elsewhere on the band"
    }

    private func role(_ net: HeardNetwork) -> Role {
        if net.isOwnMesh { return .own }
        if let span = ourRadio?.span, SpectrumMath.overlapMHz(span, net.span) > 0 { return .overlapping }
        return .other
    }

    private func points(_ nets: [HeardNetwork]) -> [ShapePoint] {
        nets.flatMap { net -> [ShapePoint] in
            let span = net.span
            let edge = min(3.0, Double(net.widthMHz) * 0.12)
            let r = role(net)
            let xs: [(Double, Int)] = [
                (span.lowerBound, Self.floor),
                (span.lowerBound + edge, net.rssiDbm),
                (span.upperBound - edge, net.rssiDbm),
                (span.upperBound, Self.floor),
            ]
            return xs.enumerated().map { i, p in
                ShapePoint(id: "\(net.id)#\(i)", series: net.id, x: p.0, y: p.1, role: r)
            }
        }
    }

    private func fill(_ role: Role) -> Color {
        switch role {
        case .own: return Color.accentColor.opacity(0.30)
        case .overlapping: return Color.orange.opacity(0.22)
        case .other: return Color.secondary.opacity(0.10)
        }
    }

    private func stroke(_ role: Role) -> Color {
        switch role {
        case .own: return Color.accentColor
        case .overlapping: return Color.orange
        case .other: return Color.secondary.opacity(0.55)
        }
    }

    private var xDomain: ClosedRange<Double> {
        switch band {
        case .ghz24: return 2399...2495
        case .ghz5: return 5165...5840
        case .ghz6: return 5940...7130
        }
    }

    private var axisChannels: [Int] {
        switch band {
        case .ghz24: return Array(1...13)
        case .ghz5: return [36, 44, 52, 60, 100, 108, 116, 124, 132, 140, 149, 157, 165]
        case .ghz6: return Array(stride(from: 1, through: 233, by: 32))
        }
    }

    private func chart(_ scan: AirwavesScan) -> some View {
        let nets = scan.networks.filter { $0.band == band }.sorted { role($0) == .own && role($1) != .own ? false : $0.rssiDbm < $1.rssiDbm }
        let pts = points(nets)
        let labelled = Array(nets.filter { !$0.isOwnMesh }.sorted { $0.rssiDbm > $1.rssiDbm }.prefix(6))
        let ownLabel = nets.filter(\.isOwnMesh).max { $0.rssiDbm < $1.rssiDbm }
        return Chart {
            if let radio = ourRadio {
                RectangleMark(
                    xStart: .value("MHz", radio.span.lowerBound),
                    xEnd: .value("MHz", radio.span.upperBound),
                    yStart: .value("dBm", Self.floor),
                    yEnd: .value("dBm", Self.ceiling)
                )
                .foregroundStyle(Color.accentColor.opacity(0.09))
                .annotation(position: .overlay, alignment: .topLeading, spacing: 0) {
                    Text("\(node?.name ?? "Our") · \(AirwavesStyle.radioLabel(radio))")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(3)
                }
            }
            if let suggestion = assessment?.suggestion {
                let span = SpectrumMath.span(band: band, channel: suggestion.channel, widthMHz: suggestion.widthMHz)
                RectangleMark(
                    xStart: .value("MHz", span.lowerBound),
                    xEnd: .value("MHz", span.upperBound),
                    yStart: .value("dBm", Self.floor),
                    yEnd: .value("dBm", Self.ceiling)
                )
                .foregroundStyle(Color.green.opacity(0.08))
                .annotation(position: .overlay, alignment: .bottomLeading, spacing: 0) {
                    Text("Try \(suggestion.label(band: band))")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(3)
                }
            }
            ForEach(pts) { p in
                AreaMark(
                    x: .value("MHz", p.x),
                    yStart: .value("Floor", Self.floor),
                    yEnd: .value("dBm", p.y),
                    series: .value("Network", p.series)
                )
                .foregroundStyle(fill(p.role))
            }
            ForEach(pts) { p in
                LineMark(
                    x: .value("MHz", p.x),
                    y: .value("dBm", p.y),
                    series: .value("Network", p.series)
                )
                .foregroundStyle(stroke(p.role))
                .lineStyle(StrokeStyle(lineWidth: p.role == .own ? 1.6 : 1))
            }
            ForEach(labelled) { net in
                PointMark(x: .value("MHz", band.centerMHz(channel: net.channel)), y: .value("dBm", net.rssiDbm))
                    .symbolSize(0)
                    .annotation(position: .top, spacing: 1) {
                        Text(String(net.displayName.prefix(16)))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                    }
            }
            if let own = ownLabel {
                PointMark(x: .value("MHz", own.span.lowerBound + (own.span.upperBound - own.span.lowerBound) / 2), y: .value("dBm", own.rssiDbm))
                    .symbolSize(0)
                    .annotation(position: .top, spacing: 1) {
                        Text("Our mesh")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: Self.floor...Self.ceiling)
        .chartXAxis {
            AxisMarks(values: axisChannels.map { band.centerMHz(channel: $0) }) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let mhz = value.as(Double.self) {
                        Text("\(band.channel(frequencyMHz: mhz))")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [-90, -80, -70, -60, -50, -40, -30]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let dbm = value.as(Int.self) { Text("\(dbm)") }
                }
            }
        }
        .chartXAxisLabel("Channel", alignment: .center)
        .chartYAxisLabel("Signal (dBm)")
        .chartLegend(.hidden)
    }

    // MARK: Side panel

    private func side(_ scan: AirwavesScan) -> some View {
        let nets = scan.networks.filter { $0.band == band }
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(node?.name ?? "Router").font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let a = assessment, a.wasScanned {
                        Badge(text: a.congestion.label, tint: AirwavesStyle.color(a.congestion))
                    }
                }
                if let radio = ourRadio {
                    Text("\(band.rawValue) · \(AirwavesStyle.radioLabel(radio))\(WiFiBand.isDFS(radio.channel, band: band) ? " · DFS" : "")")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                } else {
                    Text("No \(band.rawValue) radio reported for this node.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let a = assessment {
                    Text(a.verdict)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if a.wasScanned {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                            GridRow { Text("Same channel").foregroundStyle(.secondary); Text("\(a.coChannelCount)") }
                            GridRow { Text("Overlapping").foregroundStyle(.secondary); Text("\(a.overlaps.count)") }
                            GridRow { Text("Strong (≥ −70 dBm)").foregroundStyle(.secondary); Text("\(a.strongCount)") }
                            if let s = a.stats {
                                if let o = s.otherUtilization { GridRow { Text("Neighbours' airtime").foregroundStyle(.secondary); Text("\(o)%") } }
                                if let m = s.selfUtilization { GridRow { Text("Our airtime").foregroundStyle(.secondary); Text("\(m)%") } }
                                if let nf = s.noiseFloorDbm { GridRow { Text("Noise floor").foregroundStyle(.secondary); Text("\(nf) dBm") } }
                            }
                        }
                        .font(.caption)
                        .monospacedDigit()
                    }
                }
                Divider()
                legend(.own)
                legend(.overlapping)
                legend(.other)
                Text("\(nets.count) network\(nets.count == 1 ? "" : "s") heard on \(band.rawValue), \(nets.filter(\.isOwnMesh).count) of them ours. Height is signal strength; width is channel width.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if band == .ghz6, nets.isEmpty {
                    Text("The router's survey doesn't list 6 GHz neighbours. Few devices use 6 GHz yet, so it's usually clear.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = model.airwavesNote {
                    Text(note).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func legend(_ role: Role) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(fill(role))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(stroke(role), lineWidth: 1))
                .frame(width: 14, height: 9)
            Text(role.rawValue).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(listener == .mac ? "No scan from this Mac yet" : "No scan yet", systemImage: "waveform")
        } description: {
            Text(model.routerScanRunning
                 ? "The router is listening to the airwaves. This takes about 30 seconds."
                 : "Scan at the router to see every network it hears (read-only, about 30 seconds), or scan from this Mac to hear what's around you.")
        } actions: {
            AirwavesScanButtons(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
