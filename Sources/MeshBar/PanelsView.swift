import Charts
import MeshBarCore
import SwiftUI

/// One row of the clients table, with plain sort keys.
struct ClientTableRow: Identifiable {
    var client: ClientDevice
    var nodeName: String

    var id: String { client.id }
    var name: String { client.name }
    var band: String { client.medium == .wired ? "Wired" : (BandFormat.label(client.band) ?? "—") }
    var signalSort: Int { client.medium == .wired ? 0 : (client.rssiDbm ?? -200) }
    var ip: String { client.ipAddress ?? "" }
    /// Numeric-aware IP key so .2 sorts before .10.
    var ipSort: String {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return ip }
        return parts.map { String(repeating: "0", count: max(0, 3 - $0.count)) + $0 }.joined(separator: ".")
    }
    var mac: String { client.macAddresses.first ?? "" }
    var rateSort: Double { client.negotiatedMbps ?? -1 }
    var onlineSort: Int { client.isOnline ? 1 : 0 }
}

struct ClientsView: View {
    @ObservedObject var model: AppModel
    var snapshot: MeshSnapshot
    @State private var query = ""
    @State private var showOffline = false
    @State private var selection = Set<String>()
    @State private var renaming: ClientDevice?
    @State private var sortOrder = [KeyPathComparator(\ClientTableRow.name, comparator: .localizedStandard)]

    private var offlineCount: Int { snapshot.clients.filter { !$0.isOnline }.count }

    private var rows: [ClientTableRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return snapshot.clients
            .filter { showOffline || $0.isOnline }
            .map { ClientTableRow(client: $0, nodeName: MeshSummary.nodeName($0.parentNodeID, in: snapshot)) }
            .filter { row in
                guard !needle.isEmpty else { return true }
                return ([row.name, row.ip, row.nodeName, row.band, row.client.kind.label] + row.client.macAddresses)
                    .joined(separator: " ")
                    .lowercased()
                    .contains(needle)
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(rows.count) \(showOffline ? "device" : "online")\(showOffline && rows.count != 1 ? "s" : "")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Toggle(isOn: $showOffline) {
                    Text("Show offline (\(offlineCount))")
                }
                .toggleStyle(.checkbox)
                .disabled(offlineCount == 0)
                SearchField(text: $query)
                    .frame(width: 220)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if rows.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No clients online" : "No matches",
                    systemImage: query.isEmpty ? "person.2.slash" : "magnifyingglass",
                    description: Text(query.isEmpty ? "Connected devices show up here." : "Try a name, IP, MAC or node.")
                )
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                        HStack(spacing: 8) {
                            Image(systemName: row.client.kind.symbolName)
                                .foregroundStyle(row.client.isOnline ? Color.accentColor : Color.secondary)
                                .frame(width: 18)
                            Text(row.name)
                                .lineLimit(1)
                            if row.client.isGuest { Badge(text: "Guest", tint: .purple) }
                            if !row.client.isOnline { Badge(text: "Offline") }
                            Spacer(minLength: 4)
                            Button {
                                model.showClientDetail(row.id)
                            } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Connection history")
                        }
                        .help(row.client.kind.label)
                        .opacity(row.client.isOnline ? 1 : 0.6)
                    }
                    .width(min: 150, ideal: 190)
                    TableColumn("Node", value: \.nodeName, comparator: .localizedStandard) { row in
                        Text(row.nodeName).lineLimit(1)
                    }
                    .width(min: 70, ideal: 95)
                    TableColumn("Band", value: \.band) { row in
                        Text(row.band).foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 60)
                    TableColumn("Signal", value: \.signalSort) { row in
                        HStack(spacing: 6) {
                            SignalBars(rssi: row.client.rssiDbm, wired: row.client.medium == .wired, height: 10)
                            Text(row.client.medium == .wired ? "Wired" : (row.client.rssiDbm.map(MeshSummary.dBm) ?? "—"))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("IP Address", value: \.ipSort) { row in
                        Text(row.ip.isEmpty ? "—" : row.ip).monospacedDigit()
                    }
                    .width(min: 90, ideal: 105)
                    TableColumn("MAC Address", value: \.mac) { row in
                        Text(row.mac.isEmpty ? "—" : row.mac)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 110, ideal: 128)
                    TableColumn("Link Rate", value: \.rateSort) { row in
                        Text(row.client.negotiatedMbps.map(MeshSummary.speed) ?? "—")
                            .monospacedDigit()
                    }
                    .width(min: 60, ideal: 76)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let client = snapshot.clients.first(where: { $0.id == id }) {
                        Button("Show Connection History…") { model.showClientDetail(client.id) }
                        Divider()
                        Button("Rename…") { renaming = client }
                        if let ip = client.ipAddress {
                            Button("Copy IP Address") { copy(ip) }
                        }
                        if let mac = client.macAddresses.first {
                            Button("Copy MAC Address") { copy(mac) }
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { model.showClientDetail(id) }
                }
            }
        }
        .sheet(item: $renaming) { client in
            RenameSheet(current: client.name) { newName in
                Task { await model.rename(id: client.id, to: newName) }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Rounded search field with a magnifying glass.
struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct HistoryChartsView: View {
    @ObservedObject var model: AppModel
    var snapshot: MeshSnapshot

    static let ranges: [ChartRange] = [.hour, .day, .week]

    private var cutoff: Date { Date().addingTimeInterval(-model.chartRange.seconds) }

    private var nodeSamples: [HistorySample] {
        let primary = snapshot.nodes.first(where: \.isPrimary)?.id
        let cutoff = cutoff
        return model.samples.filter { sample in
            sample.timestamp >= cutoff && sample.nodeID != HistorySample.wanNodeID && sample.nodeID != primary
        }
    }

    private var wanSamples: [HistorySample] {
        let cutoff = cutoff
        return model.samples.filter { $0.nodeID == HistorySample.wanNodeID && $0.timestamp >= cutoff }
    }

    private var nodeNames: [String] {
        Array(Set(nodeSamples.map(\.nodeName))).sorted()
    }

    private static let palette: [Color] = [.blue, .teal, .purple, .pink, .orange, .green, .indigo, .brown]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                legend
                Spacer()
                Picker("Range", selection: Binding(
                    get: { Self.ranges.contains(model.chartRange) ? model.chartRange : .day },
                    set: { model.setChartRange($0) }
                )) {
                    ForEach(Self.ranges) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            if nodeSamples.isEmpty && wanSamples.isEmpty {
                ContentUnavailableView(
                    "No history for this range",
                    systemImage: "chart.xyaxis.line",
                    description: Text("MeshBar records a sample each refresh and keeps \(model.settings.retentionDays) days.")
                )
            } else {
                HStack(alignment: .top, spacing: 14) {
                    chartBox("Backhaul speed", unit: "Mbps") {
                        Chart {
                            ForEach(nodeSamples.filter { $0.speedMbps != nil }) { sample in
                                LineMark(x: .value("Time", sample.timestamp), y: .value("Mbps", sample.speedMbps ?? 0))
                                    .foregroundStyle(by: .value("Node", sample.nodeName))
                                    .interpolationMethod(.monotone)
                            }
                            RuleMark(y: .value("Minimum", model.settings.thresholds.minimumBackhaulMbps))
                                .foregroundStyle(MeshPalette.color(.degraded).opacity(0.8))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .annotation(position: .top, alignment: .leading) {
                                    Text("min").font(.caption2).foregroundStyle(.secondary)
                                }
                        }
                        .chartForegroundStyleScale(domain: nodeNames, range: Self.palette.prefix(max(1, nodeNames.count)).map { $0 })
                        .chartLegend(.hidden)
                    }
                    chartBox("Backhaul signal", unit: "dBm") {
                        Chart {
                            ForEach(nodeSamples.filter { $0.rssiDbm != nil }) { sample in
                                LineMark(x: .value("Time", sample.timestamp), y: .value("dBm", sample.rssiDbm ?? 0))
                                    .foregroundStyle(by: .value("Node", sample.nodeName))
                                    .interpolationMethod(.monotone)
                            }
                            RuleMark(y: .value("Minimum", model.settings.thresholds.minimumRSSI))
                                .foregroundStyle(MeshPalette.color(.degraded).opacity(0.8))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                        .chartForegroundStyleScale(domain: nodeNames, range: Self.palette.prefix(max(1, nodeNames.count)).map { $0 })
                        .chartLegend(.hidden)
                    }
                    chartBox("Internet", unit: "WAN") {
                        Chart {
                            ForEach(wanSamples) { sample in
                                RectangleMark(
                                    x: .value("Time", sample.timestamp),
                                    yStart: .value("Low", 0),
                                    yEnd: .value("High", 1),
                                    width: .ratio(1)
                                )
                                .foregroundStyle(MeshPalette.color(sample.wanConnected == true ? .healthy : .offline).opacity(0.7))
                            }
                        }
                        .chartYAxis(.hidden)
                        .chartYScale(domain: 0...1)
                    }
                    .frame(maxWidth: 220)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(Array(nodeNames.enumerated()), id: \.element) { index, name in
                HStack(spacing: 5) {
                    Circle()
                        .fill(Self.palette[index % Self.palette.count])
                        .frame(width: 8, height: 8)
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 5) {
                Rectangle()
                    .fill(MeshPalette.color(.degraded))
                    .frame(width: 14, height: 1.5)
                Text("Threshold")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chartBox<Content: View>(_ title: String, unit: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct SpeedTestView: View {
    @ObservedObject var model: AppModel
    var snapshot: MeshSnapshot

    private var result: SpeedTestResult? { model.speedTest ?? snapshot.speedTest }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(model.speedTestRunning ? "Running…" : "Run speed test") {
                    Task { await model.runSpeedTest() }
                }
                .disabled(model.speedTestRunning)
                if model.speedTestRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if let status = snapshot.healthCheckStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Uses healthcheck/RunHealthCheck with the SpeedTest module. The router reports bandwidth in kilobits per second; the raw counter is shown under each figure.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let result {
                HStack(spacing: 24) {
                    metric("Download", result.downloadMbps, raw: result.downloadRaw)
                    metric("Upload", result.uploadMbps, raw: result.uploadRaw)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Latency")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(result.latencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
                            .font(.system(size: 28, weight: .medium, design: .rounded))
                    }
                }
                if let exit = result.exitCode {
                    Text(result.failed ? "The last test did not finish (\(exit))" : result.isComplete ? "Result \(exit)" : "In progress (\(exit))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("No speed test yet", systemImage: "speedometer", description: Text("Run one when the WAN is up."))
            }
            Spacer()
        }
        .padding(16)
    }

    private func metric(_ title: String, _ mbps: Double?, raw: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            let figure = mbps.map(BandwidthUnits.display)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(figure?.value ?? "—")
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text(figure?.unit ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(raw.map { "raw \(Int($0)) kbps" } ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
