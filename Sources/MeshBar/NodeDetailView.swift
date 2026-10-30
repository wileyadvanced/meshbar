import Charts
import MeshBarCore
import SwiftUI

/// Trailing inspector for the selected node. Clients come first, then
/// collapsible sections (Overview, Backhaul, Airwaves, Hardware, Actions) that
/// show a one-line summary when collapsed and remember their state.
struct NodeDetailView: View {
    @ObservedObject var model: AppModel
    var node: MeshNode
    var snapshot: MeshSnapshot
    @State private var confirmRestart = false
    @State private var renaming = false
    @State private var showIdentifiers = false

    private var thresholds: HealthThresholds { model.settings.thresholds }
    private var quality: MeshHealth {
        node.isPrimary ? (node.isOnline ? .healthy : .offline) : HealthEvaluator.linkQuality(node, thresholds: thresholds)
    }
    private var clients: [ClientDevice] {
        snapshot.clients(of: node.id).filter(\.isOnline).sorted { ($0.rssiDbm ?? -200) > ($1.rssiDbm ?? -200) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                clientsSection
                overview
                backhaul
                AirwavesSection(model: model, node: node)
                hardware
                actions
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DashboardStyle.canvasBackground)
        .confirmationDialog("Restart \(node.name)?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart \(node.name)", role: .destructive) {
                Task { await model.restartNode(node) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This uses core/Reboot2 and restarts only \(node.name). The other nodes stay up. To reboot the whole router, use the More menu in the toolbar.")
        }
        .sheet(isPresented: $renaming) {
            RenameSheet(current: node.name) { newName in
                Task { await model.rename(id: node.id, to: newName) }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            SymbolTile(
                systemName: node.isPrimary ? "wifi.router.fill" : "dot.radiowaves.left.and.right",
                tint: node.isOnline ? (node.isPrimary ? .indigo : .teal) : .gray,
                size: 44
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Badge(text: node.isPrimary ? "Router" : "Node", tint: node.isPrimary ? .indigo : .teal)
                    HStack(spacing: 4) {
                        HealthDot(color: MeshPalette.color(quality), size: 7)
                        Text(node.isOnline ? quality == .degraded ? "Weak link" : "Online" : "Offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.thisMacNodeID == node.id {
                        Badge(text: "This Mac", tint: .accentColor)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var overview: some View {
        InspectorSection(.overview, title: "Overview", systemName: "info.circle", summary: overviewSummary) {
            InspectorRow("Status", node.isOnline ? "Online" : "Offline")
            InspectorRow("Connected to", node.isPrimary ? "Internet" : MeshSummary.nodeName(node.parentID, in: snapshot))
            InspectorRow("Uptime", node.uptimeSeconds.map(MeshFormat.uptime) ?? "—")
            InspectorRow("Clients", "\(clients.count)")
            InspectorRow("IP address", node.ipAddress ?? "—", monospaced: true)
            if let cpu = node.cpuLoadPercent {
                LoadRow(title: "CPU", percent: cpu)
            }
            if let memory = node.memoryLoadPercent {
                LoadRow(title: "Memory", percent: memory)
            }
        }
    }

    @ViewBuilder
    private var backhaul: some View {
        InspectorSection(.backhaul, title: "Backhaul", systemName: "point.3.connected.trianglepath.dotted", summary: backhaulSummary) {
            if node.isPrimary {
                InspectorRow("Uplink", snapshot.wan.map { $0.isConnected ? "Internet · \($0.wanType ?? "WAN")" : "Internet down" } ?? "—")
                Text("This is the router. Satellites connect back to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let link = node.backhaul, node.isOnline {
                InspectorRow("Type", link.medium == .wired ? "Wired (Ethernet)" : "Wireless")
                if link.medium != .wired {
                    InspectorRow("Band", BandFormat.label(link.band) ?? "—")
                    if let channel = link.channel { InspectorRow("Channel", "\(channel)") }
                }
                InspectorRow("Speed", MeshSummary.speedText(link) ?? "—", tint: link.isAwaitingSpeed ? .secondary : speedTint(link.speedMbps))
                if link.isAwaitingSpeed {
                    Text("The router hasn't measured this link since it reconnected. Refresh in a minute or two.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if link.medium != .wired {
                    HStack {
                        Text("Signal").foregroundStyle(.secondary)
                        Spacer()
                        SignalBars(rssi: link.rssiDbm)
                        Text(link.rssiDbm.map(MeshSummary.dBm) ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(rssiTint(link.rssiDbm))
                    }
                    .font(.callout)
                }
                sparkline
            } else {
                Text(node.isOnline ? "No backhaul reading yet." : "Node is offline.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        let cutoff = Date().addingTimeInterval(-model.chartRange.seconds)
        let points = model.samples.filter { $0.nodeID == node.id && $0.timestamp >= cutoff && $0.speedMbps != nil }
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speed, last \(model.chartRange.title)")
                    Spacer()
                    if let low = points.compactMap(\.speedMbps).min(), let high = points.compactMap(\.speedMbps).max() {
                        Text("\(Int(low))–\(Int(high)) Mbps").monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Chart(points) { sample in
                    AreaMark(x: .value("Time", sample.timestamp), y: .value("Mbps", sample.speedMbps ?? 0))
                        .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.timestamp), y: .value("Mbps", sample.speedMbps ?? 0))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 46)
            }
            .padding(.top, 2)
        }
    }

    private var clientsSection: some View {
        InspectorSection(.clients, title: "Clients on this node", systemName: "person.2", summary: clients.isEmpty ? "None online" : "\(clients.count) online", trailing: clients.isEmpty ? nil : "\(clients.count)") {
            if clients.isEmpty {
                Text("No devices connected here right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(clients.prefix(12)) { client in
                    Button {
                        model.showClientDetail(client.id)
                    } label: {
                    HStack(spacing: 8) {
                        Image(systemName: client.kind.symbolName)
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(client.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        if let band = BandFormat.short(client.band) {
                            Text(band)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        SignalBars(rssi: client.rssiDbm, wired: client.medium == .wired, height: 10)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help((["Show connection history"] + [client.ipAddress, client.rssiDbm.map(MeshSummary.dBm)].compactMap { $0 }).joined(separator: " · "))
                }
                if clients.count > 12 {
                    Text("+\(clients.count - 12) more in the Clients table")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var hardware: some View {
        InspectorSection(.hardware, title: "Hardware", systemName: "cpu", summary: hardwareSummary) {
            InspectorRow("Model", node.modelNumber ?? "—")
            InspectorRow("Manufacturer", node.manufacturer ?? "—")
            InspectorRow("Hardware", node.hardwareVersion ?? "—")
            InspectorRow("Firmware", node.firmwareVersion ?? "—", monospaced: true)
            DisclosureGroup(isExpanded: $showIdentifiers) {
                VStack(spacing: 6) {
                    InspectorRow("MAC", node.macAddress ?? "—", monospaced: true)
                    InspectorRow("Serial", node.serialNumber ?? "—", monospaced: true)
                }
                .padding(.top, 4)
            } label: {
                Text("Identifiers")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        InspectorSection(.actions, title: "Actions", systemName: "slider.horizontal.3", summary: "Blink · Rename · Restart") {
            HStack(spacing: 8) {
                Button {
                    Task { await model.blink(node) }
                } label: {
                    Label("Blink LED", systemImage: "lightbulb.max")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    Task { await model.stopBlinking() }
                } label: {
                    Label("Stop", systemImage: "lightbulb.slash")
                }
            }
            Button {
                renaming = true
            } label: {
                Label("Rename…", systemImage: "pencil")
                    .frame(maxWidth: .infinity)
            }
            Divider().padding(.vertical, 2)
            Button(role: .destructive) {
                confirmRestart = true
            } label: {
                Label("Restart Node…", systemImage: "restart")
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.red)
            .buttonStyle(.bordered)
            Text("Restarts only this node (core/Reboot2). The router and other nodes stay up.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .controlSize(.regular)
        .disabled(model.isActing)
    }

    // MARK: Collapsed summaries

    private var overviewSummary: String {
        guard node.isOnline else { return "Offline" }
        var parts = ["Online"]
        if let up = node.uptimeSeconds { parts.append("up \(MeshFormat.uptime(up))") }
        return parts.joined(separator: " · ")
    }

    private var backhaulSummary: String {
        if node.isPrimary {
            return snapshot.wan.map { $0.isConnected ? "Internet · \($0.wanType ?? "WAN")" : "Internet down" } ?? "Router"
        }
        guard node.isOnline else { return "Offline" }
        guard let link = node.backhaul else { return "No reading" }
        var parts: [String] = []
        if link.medium == .wired { parts.append("Wired") }
        parts.append(MeshSummary.speedText(link) ?? "—")
        if link.medium != .wired, let rssi = link.rssiDbm { parts.append(MeshSummary.dBm(rssi)) }
        return parts.joined(separator: " · ")
    }

    private var hardwareSummary: String {
        [node.modelNumber, node.firmwareVersion].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "—"
    }

    private func speedTint(_ mbps: Double?) -> Color? {
        guard let mbps else { return nil }
        return mbps < thresholds.minimumBackhaulMbps ? MeshPalette.color(.degraded) : nil
    }

    private func rssiTint(_ rssi: Int?) -> Color {
        guard let rssi else { return .secondary }
        return rssi < thresholds.minimumRSSI ? MeshPalette.color(.degraded) : .primary
    }
}

/// Inspector sections. Each remembers whether it is expanded, shared across
/// nodes and launches.
enum InspectorSectionID: String, CaseIterable {
    case clients, overview, backhaul, airwaves, hardware, actions

    /// Airwaves and Hardware are detail most people only need now and then.
    var defaultExpanded: Bool { self != .airwaves && self != .hardware }
    var storageKey: String { "inspector.section.\(rawValue).expanded" }

    static func setAll(expanded: Bool, defaults: UserDefaults = .standard) {
        for id in allCases { defaults.set(expanded, forKey: id.storageKey) }
    }
}

/// A collapsible inspector section in the style of Xcode's inspector: a
/// chevron header that toggles the content, and a one-line summary in the
/// header while collapsed.
struct InspectorSection<Content: View>: View {
    var id: InspectorSectionID
    var title: String
    var systemName: String
    var summary: String?
    var trailing: String?
    @ViewBuilder var content: Content
    @AppStorage private var expanded: Bool

    init(_ id: InspectorSectionID, title: String, systemName: String, summary: String? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.id = id
        self.title = title
        self.systemName = systemName
        self.summary = summary
        self.trailing = trailing
        self.content = content()
        _expanded = AppStorage(wrappedValue: id.defaultExpanded, id.storageKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Collapses the section" : "Expands the section")
            .contextMenu {
                Button(expanded ? "Collapse \(title)" : "Expand \(title)") {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                }
                Divider()
                Button("Expand All") { withAnimation(.snappy(duration: 0.2)) { InspectorSectionID.setAll(expanded: true) } }
                Button("Collapse All") { withAnimation(.snappy(duration: 0.2)) { InspectorSectionID.setAll(expanded: false) } }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dashboardCard(padding: 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if !expanded, let summary {
                Text(summary)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let trailing {
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct InspectorRow: View {
    var title: String
    var value: String
    var monospaced = false
    var tint: Color?

    init(_ title: String, _ value: String, monospaced: Bool = false, tint: Color? = nil) {
        self.title = title
        self.value = value
        self.monospaced = monospaced
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct LoadRow: View {
    var title: String
    var percent: Double

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Gauge(value: min(100, max(0, percent)), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(percent > 85 ? MeshPalette.color(.degraded) : .accentColor)
                .frame(width: 90)
            Text(String(format: "%.0f%%", percent))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .font(.callout)
    }
}

struct RenameSheet: View {
    var current: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(current: String, onSave: @escaping (String) -> Void) {
        self.current = current
        self.onSave = onSave
        _name = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename")
                .font(.headline)
            Text("Stored on the router as userDeviceName.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
