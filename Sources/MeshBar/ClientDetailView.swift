import Charts
import MeshBarCore
import SwiftUI

/// Which client the detail sheet shows.
struct ClientDetailRequest: Identifiable, Equatable {
    var id: String
}

/// Connection and link-rate history for one client, built from the samples
/// MeshBar records on every refresh. The router does not report per-client
/// traffic, so there is none here.
struct ClientDetailView: View {
    @ObservedObject var model: AppModel
    let clientID: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("meshbar.clientDetail.range") private var rangeRaw = ChartRange.day.rawValue
    @State private var samples: [ClientSample] = []
    @State private var now = Date()

    static let ranges: [ChartRange] = [.hour, .day, .week]
    private static let palette: [Color] = [.blue, .teal, .purple, .pink, .orange, .green, .indigo, .brown]

    private var range: ChartRange {
        let stored = ChartRange(rawValue: rangeRaw) ?? .day
        return Self.ranges.contains(stored) ? stored : .day
    }

    private var client: ClientDevice? { model.snapshot?.clients.first { $0.id == clientID } }
    private var lastSample: ClientSample? { samples.last }
    private var cutoff: Date { now.addingTimeInterval(-range.seconds) }

    var body: some View {
        let events = ClientEventDeriver.events(from: samples)
        let windowSamples = samples.filter { $0.timestamp >= cutoff }
        let points = ClientChartSeries.points(windowSamples)
        let nodeNames = Array(Set(points.map(\.nodeName))).sorted()
        let rangeStats = ClientHistoryStats.compute(samples: samples, events: events, since: cutoff)
        let dayStats = ClientHistoryStats.compute(samples: samples, events: events, since: now.addingTimeInterval(-86_400))
        let rangeEvents = events.filter { $0.timestamp >= cutoff }

        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    currentGrid
                    statsRow(rangeStats: rangeStats, dayStats: dayStats, nodeNames: nodeNames)
                    if points.count < 2 {
                        recordingNotice(count: windowSamples.count)
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            chart("Signal", unit: "dBm", points: points, nodeNames: nodeNames, events: rangeEvents, value: \.rssiDbm)
                            chart("Link rate", unit: "Mbps", points: points, nodeNames: nodeNames, events: rangeEvents, value: \.linkMbps)
                        }
                        .frame(height: 210)
                    }
                    eventLog(rangeEvents.reversed())
                }
                .padding(20)
            }
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 640, idealHeight: 760)
        .background(DashboardStyle.canvasBackground)
        .task(id: model.lastRefresh) { reload() }
    }

    private func reload() {
        now = Date()
        samples = model.clientHistory(clientID: clientID, since: now.addingTimeInterval(-ChartRange.week.seconds))
    }

    // MARK: Header

    private var displayName: String { client?.name ?? lastSample?.name ?? "Client" }
    private var isOnline: Bool { client?.isOnline ?? lastSample?.isOnline ?? false }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            SymbolTile(
                systemName: client?.kind.symbolName ?? "questionmark.square.dashed",
                tint: isOnline ? .indigo : .gray,
                size: 48
            )
            VStack(alignment: .leading, spacing: 5) {
                Text(displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Badge(text: isOnline ? "Online" : "Offline", tint: isOnline ? MeshPalette.color(.healthy) : .secondary)
                    if client?.isGuest == true { Badge(text: "Guest", tint: .purple) }
                    if isThisMac { Badge(text: "This Mac", tint: .accentColor) }
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Picker("Range", selection: $rangeRaw) {
                ForEach(Self.ranges) { range in
                    Text(range.title).tag(range.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .help("Time range for the charts, stats and log")
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var isThisMac: Bool {
        guard let snapshot = model.snapshot else { return false }
        return NodeLocator.client(matching: model.localIdentity, in: snapshot)?.id == clientID
    }

    private var subtitle: String {
        guard let client else { return "" }
        return [client.kind.label, client.manufacturer, client.modelNumber]
            .compactMap { $0 }.filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " · ")
    }

    // MARK: Current state

    private var currentGrid: some View {
        let wired = client?.medium == .wired
        let nodeName = client.flatMap { c in c.parentNodeID.flatMap { model.snapshot?.node(id: $0)?.name } } ?? lastSample?.nodeName
        return Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
            GridRow {
                field("Node", isOnline ? (nodeName ?? "—") : "Offline")
                field("Band", wired ? "Wired" : (BandFormat.label(client?.band) ?? "—"))
                VStack(alignment: .leading, spacing: 3) {
                    caption("Signal")
                    HStack(spacing: 6) {
                        SignalBars(rssi: client?.rssiDbm, wired: wired, height: 11)
                        Text(wired ? "Wired" : (client?.rssiDbm.map(MeshSummary.dBm) ?? "—"))
                            .monospacedDigit()
                    }
                }
                field("Link rate", client?.negotiatedMbps.map(MeshSummary.speed) ?? "—")
                field("IP address", client?.ipAddress ?? lastSample?.ipAddress ?? "—", mono: true)
                field("MAC address", client?.macAddresses.first ?? lastSample?.macAddress ?? "—", mono: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }

    private func field(_ title: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            caption(title)
            Text(value)
                .font(mono ? .body.monospaced() : .body)
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    // MARK: Stats

    private func statsRow(rangeStats: ClientHistoryStats, dayStats: ClientHistoryStats, nodeNames: [String]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                caption("Time on each node · \(range.title)")
                if rangeStats.nodeShares.isEmpty {
                    Text("No online time recorded yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            ForEach(rangeStats.nodeShares) { share in
                                Rectangle()
                                    .fill(color(for: share.nodeName, in: nodeNames))
                                    .frame(width: max(2, geo.size.width * share.fraction))
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 8)
                    HStack(spacing: 12) {
                        ForEach(rangeStats.nodeShares.prefix(4)) { share in
                            HStack(spacing: 5) {
                                Circle().fill(color(for: share.nodeName, in: nodeNames)).frame(width: 7, height: 7)
                                Text("\(share.nodeName) \(Int((share.fraction * 100).rounded()))%")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 52, alignment: .topLeading)
            .dashboardCard(padding: 12)
            .layoutPriority(1)
            miniStat("Roams · 24h", "\(dayStats.roams)", symbol: "arrow.triangle.swap")
            miniStat("Drop-offs · 24h", "\(dayStats.drops)", symbol: "wifi.slash", tint: dayStats.drops > 0 ? MeshPalette.color(.degraded) : nil)
            miniStat("Median signal · \(range.title)", rangeStats.medianRSSI.map(MeshSummary.dBm) ?? "—", symbol: "cellularbars")
            miniStat("Median link · \(range.title)", rangeStats.medianLinkMbps.map(MeshSummary.speed) ?? "—", symbol: "speedometer")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func miniStat(_ title: String, _ value: String, symbol: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(title)
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint ?? .secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint ?? .primary)
            }
        }
        .frame(minWidth: 104, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(padding: 12)
    }

    // MARK: Charts

    private func color(for nodeName: String, in names: [String]) -> Color {
        let index = names.firstIndex(of: nodeName) ?? (abs(nodeName.hashValue) % Self.palette.count)
        return Self.palette[index % Self.palette.count]
    }

    private func chart(
        _ title: String,
        unit: String,
        points: [ClientChartPoint],
        nodeNames: [String],
        events: [ClientEvent],
        value: KeyPath<ClientChartPoint, Double?>
    ) -> some View {
        let shown = points.filter { $0[keyPath: value] != nil }
        let roams = events.filter(\.isRoam)
        let drops = events.filter(\.isDrop)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            if shown.isEmpty {
                Text("No \(title.lowercased()) readings in this range")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(drops) { event in
                        RuleMark(x: .value("Time", event.timestamp))
                            .foregroundStyle(MeshPalette.color(.offline).opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                    ForEach(roams) { event in
                        RuleMark(x: .value("Time", event.timestamp))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    ForEach(shown) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value(unit, point[keyPath: value] ?? 0),
                            series: .value("Segment", point.segment)
                        )
                        .foregroundStyle(by: .value("Node", point.nodeName))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if shown.count < 40 {
                        ForEach(shown) { point in
                            PointMark(x: .value("Time", point.timestamp), y: .value(unit, point[keyPath: value] ?? 0))
                                .foregroundStyle(by: .value("Node", point.nodeName))
                                .symbolSize(18)
                        }
                    }
                }
                .chartForegroundStyleScale(domain: nodeNames, range: nodeNames.map { color(for: $0, in: nodeNames) })
                .chartXScale(domain: xDomain(shown))
                .chartYScale(domain: yDomain(shown.compactMap { $0[keyPath: value] }))
                .chartLegend(position: .top, alignment: .leading, spacing: 6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashboardStyle.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DashboardStyle.hairline.opacity(0.6), lineWidth: 0.5)
        )
    }

    /// The selected range, narrowed to the recorded span while history is
    /// still shorter than the range so new data is readable.
    private func xDomain(_ points: [ClientChartPoint]) -> ClosedRange<Date> {
        guard let first = points.first?.timestamp else { return cutoff...now }
        let start = max(cutoff, first.addingTimeInterval(-60))
        return start...max(now, start.addingTimeInterval(300))
    }

    /// Padded so a steady reading sits mid-chart instead of on an edge.
    private func yDomain(_ values: [Double]) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.15, abs(high) * 0.05, 3)
        return (low - pad)...(high + pad)
    }

    private func recordingNotice(count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Building history")
                    .font(.headline)
                Text("MeshBar records this device's node, band, signal and link rate on every refresh (every \(model.settings.pollIntervalClamped) s) and keeps \(model.settings.retentionDays) days. \(count) reading\(count == 1 ? "" : "s") in this range so far.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    // MARK: Event log

    private func eventLog(_ events: [ClientEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connection log")
                    .font(.headline)
                Spacer()
                Text("Changes must hold for two refreshes to count")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                if events.isEmpty {
                    Text(samples.isEmpty ? "Nothing recorded yet." : "No connection changes in the last \(range.title).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    ForEach(Array(events.prefix(200).enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider().padding(.leading, 40) }
                        HStack(spacing: 10) {
                            Image(systemName: event.symbolName)
                                .foregroundStyle(tint(for: event))
                                .frame(width: 20)
                            Text(event.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(Self.timeText(event.timestamp, now: now))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .help(event.timestamp.formatted(date: .complete, time: .standard))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                }
            }
            .background(DashboardStyle.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DashboardStyle.hairline.opacity(0.6), lineWidth: 0.5)
            )
        }
    }

    private func tint(for event: ClientEvent) -> Color {
        switch event.kind {
        case .cameOnline: return MeshPalette.color(.healthy)
        case .wentOffline: return MeshPalette.color(.offline)
        case .roamed: return .blue
        case .bandChanged: return .purple
        case .ipChanged: return .secondary
        }
    }

    /// Local time: "14:32" today, "Thu 14:32" this week, else "28 Oct 14:32".
    static func timeText(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if now.timeIntervalSince(date) < 6 * 86_400 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }
}
