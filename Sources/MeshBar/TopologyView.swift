import MeshBarCore
import SwiftUI

/// Left-to-right mesh map: Internet → router → satellites by depth.
/// Positions are computed for the space available, so the map fills the
/// card and stays sharp instead of being scaled.
struct TopologyView: View {
    @ObservedObject var model: AppModel
    var snapshot: MeshSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
            GeometryReader { proxy in
                let fitted = TopologyLayout.fitted(
                    snapshot: snapshot,
                    thresholds: model.settings.thresholds,
                    available: proxy.size
                )
                let layout = fitted.layout
                let scale = fitted.scale
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    canvas(layout)
                        .frame(width: layout.size.width, height: layout.size.height)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
                }
                .scrollDisabled(layout.size.width * scale <= proxy.size.width + 1 && layout.size.height * scale <= proxy.size.height + 1)
            }
            .background(GridBackground())
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 10)
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .background(DashboardStyle.cardBackground, in: RoundedRectangle(cornerRadius: DashboardStyle.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DashboardStyle.cardRadius, style: .continuous)
                .strokeBorder(DashboardStyle.hairline.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Mesh topology")
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let ssid = snapshot.radios.compactMap(\.ssid).first(where: { !$0.isEmpty }) {
                Label(ssid, systemImage: "wifi")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .help("Wi-Fi network name")
            }
        }
    }

    private var subtitle: String {
        var parts = ["\(snapshot.nodes.count) node\(snapshot.nodes.count == 1 ? "" : "s")"]
        if let steering = snapshot.topologyOptimization?.isNodeSteeringEnabled {
            parts.append(steering ? "Node steering on" : "Node steering off")
        }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 14) {
            LegendSwatch(color: MeshPalette.color(.healthy), text: "Strong")
            LegendSwatch(color: MeshPalette.color(.degraded), text: "Weak")
            LegendSwatch(color: MeshPalette.color(.offline), text: "Offline")
            LegendSwatch(color: .secondary, text: "Wired", dashed: true)
            Spacer(minLength: 12)
            ForEach(snapshot.radios) { radio in
                RadioChip(radio: radio)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func canvas(_ layout: TopologyLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.edges) { edge in
                EdgeCurve(from: edge.from, to: edge.to)
                    .stroke(
                        edge.color,
                        style: StrokeStyle(lineWidth: edge.width, lineCap: .round, dash: edge.dashed ? [6, 5] : [])
                    )
                Circle().fill(edge.color).frame(width: 7, height: 7).position(edge.from)
                Circle().fill(edge.color).frame(width: 7, height: 7).position(edge.to)
            }
            ForEach(layout.edges) { edge in
                EdgePill(text: edge.label, color: edge.color)
                    .position(edge.labelPoint)
            }
            InternetBubble(wan: snapshot.wan)
                .position(layout.internetCenter)
            ForEach(layout.cards) { card in
                NodeCard(
                    node: card.node,
                    snapshot: snapshot,
                    selected: model.selectedNode?.id == card.node.id,
                    hostsThisMac: model.thisMacNodeID == card.node.id,
                    thresholds: model.settings.thresholds,
                    airwaves: model.airwavesReport(for: card.node),
                    openSpectrum: {
                        model.selectedNodeID = card.node.id
                        withAnimation(.easeInOut(duration: 0.2)) { model.mainView = .spectrum }
                    }
                )
                .frame(width: card.frame.width, height: card.frame.height)
                .position(x: card.frame.midX, y: card.frame.midY)
                .onTapGesture { model.selectedNodeID = card.node.id }
            }
        }
    }
}

struct TopologyLayout {
    struct Card: Identifiable {
        var node: MeshNode
        var frame: CGRect
        var id: String { node.id }
    }

    struct Edge: Identifiable {
        var id: String
        var from: CGPoint
        var to: CGPoint
        var label: String
        var color: Color
        var width: CGFloat
        var dashed: Bool

        /// Point on the curve close to the child, so sibling labels sit at
        /// their own heights instead of piling up near the parent.
        var labelPoint: CGPoint {
            EdgeCurve.point(from: from, to: to, t: 0.6)
        }
    }

    static let cardSize = CGSize(width: 214, height: 134)
    static let internetWidth: CGFloat = 84
    static let minimumScale: CGFloat = 0.72

    /// Lays the mesh out for `available`, shrinking the whole canvas (down to
    /// `minimumScale`) when a deep daisy chain would not otherwise fit.
    static func fitted(snapshot: MeshSnapshot, thresholds: HealthThresholds, available: CGSize) -> (layout: TopologyLayout, scale: CGFloat) {
        let natural = compute(snapshot: snapshot, thresholds: thresholds, available: available)
        guard natural.size.width > available.width + 1, available.width > 0 else { return (natural, 1) }
        let scale = max(minimumScale, available.width / natural.size.width)
        let virtual = CGSize(width: available.width / scale, height: available.height / scale)
        return (compute(snapshot: snapshot, thresholds: thresholds, available: virtual), scale)
    }

    var cards: [Card]
    var edges: [Edge]
    var internetCenter: CGPoint
    var size: CGSize

    static func compute(snapshot: MeshSnapshot, thresholds: HealthThresholds, available: CGSize) -> TopologyLayout {
        let ordered = snapshot.treeOrder
        let ids = Set(ordered.map(\.id))
        var children: [String: [MeshNode]] = [:]
        var roots: [MeshNode] = []
        for node in ordered {
            if let parent = node.parentID, ids.contains(parent), !node.isPrimary {
                children[parent, default: []].append(node)
            } else {
                roots.append(node)
            }
        }
        // Satellites that report no parent hang off the router.
        if let primary = roots.first(where: \.isPrimary) {
            let orphans = roots.filter { $0.id != primary.id }
            children[primary.id, default: []].append(contentsOf: orphans)
            roots = [primary]
        }

        var depth: [String: Int] = [:]
        var leafOrder: [String: Double] = [:]
        var nextLeaf = 0.0
        var maxDepth = 0
        func walk(_ node: MeshNode, _ level: Int) {
            depth[node.id] = level
            maxDepth = max(maxDepth, level)
            let kids = children[node.id] ?? []
            if kids.isEmpty {
                leafOrder[node.id] = nextLeaf
                nextLeaf += 1
            } else {
                kids.forEach { walk($0, level + 1) }
                let slots = kids.compactMap { leafOrder[$0.id] }
                leafOrder[node.id] = slots.reduce(0, +) / Double(max(1, slots.count))
            }
        }
        roots.forEach { walk($0, 0) }

        let card = cardSize
        let columns = maxDepth + 1
        let rows = max(1.0, nextLeaf)
        let margin: CGFloat = 20
        let minGap: CGFloat = 104
        let maxGap: CGFloat = 230
        let neededWidth = margin * 2 + internetWidth + CGFloat(columns) * (card.width + minGap)
        let width = max(available.width, neededWidth)
        let gap = min(maxGap, max(minGap, (available.width - margin * 2 - internetWidth - CGFloat(columns) * card.width) / CGFloat(columns)))
        let usedWidth = internetWidth + CGFloat(columns) * (card.width + gap)
        let originX = max(margin, (width - usedWidth) / 2)

        let minRow: CGFloat = card.height + 34
        let maxRow: CGFloat = card.height + 110
        let rowHeight = min(maxRow, max(minRow, (available.height - margin * 2) / CGFloat(rows)))
        let neededHeight = margin * 2 + rowHeight * CGFloat(rows)
        let height = max(available.height, neededHeight)
        let originY = (height - rowHeight * CGFloat(rows)) / 2

        func center(for node: MeshNode) -> CGPoint {
            let level = depth[node.id] ?? 0
            let x = originX + internetWidth + gap + CGFloat(level) * (card.width + gap) + card.width / 2
            let y = originY + (CGFloat(leafOrder[node.id] ?? 0) + 0.5) * rowHeight
            return CGPoint(x: x, y: y)
        }

        var cards: [Card] = []
        var centers: [String: CGPoint] = [:]
        for node in ordered where depth[node.id] != nil {
            let c = center(for: node)
            centers[node.id] = c
            cards.append(Card(node: node, frame: CGRect(x: c.x - card.width / 2, y: c.y - card.height / 2, width: card.width, height: card.height)))
        }

        let rootCenter = roots.first.flatMap { centers[$0.id] } ?? CGPoint(x: originX + internetWidth + gap, y: height / 2)
        let internetCenter = CGPoint(x: originX + internetWidth / 2, y: rootCenter.y)

        var edges: [Edge] = []
        if let root = roots.first, let rc = centers[root.id] {
            let wanUp = snapshot.wan?.isConnected ?? true
            let color = MeshPalette.color(wanUp ? .healthy : .offline)
            var label = wanUp ? "WAN" : "WAN down"
            if wanUp, let type = snapshot.wan?.wanType { label += " · \(type)" }
            edges.append(Edge(
                id: "wan",
                from: CGPoint(x: internetCenter.x + 30, y: internetCenter.y),
                to: CGPoint(x: rc.x - card.width / 2, y: rc.y),
                label: label,
                color: color,
                width: 3,
                dashed: !wanUp
            ))
        }
        for node in ordered {
            guard let c = centers[node.id] else { continue }
            for child in children[node.id] ?? [] {
                guard let cc = centers[child.id] else { continue }
                let quality = HealthEvaluator.linkQuality(child, thresholds: thresholds)
                let wired = child.backhaul?.medium == .wired
                // An unmeasured link (speed reported as 0) is drawn at a neutral
                // width rather than the thinnest "slow" stroke.
                let speed = child.backhaul?.speedMbps ?? (child.backhaul?.isAwaitingSpeed == true ? 100 : 0)
                let width: CGFloat = wired ? 3 : (speed >= 400 ? 4 : speed >= 200 ? 3.2 : speed >= 100 ? 2.6 : 2)
                edges.append(Edge(
                    id: "\(node.id)->\(child.id)",
                    from: CGPoint(x: c.x + card.width / 2, y: c.y),
                    to: CGPoint(x: cc.x - card.width / 2, y: cc.y),
                    label: MeshSummary.edgeLabel(child),
                    color: wired && quality == .healthy ? .secondary : MeshPalette.color(quality),
                    width: width,
                    dashed: wired || !child.isOnline
                ))
            }
        }
        return TopologyLayout(cards: cards, edges: edges, internetCenter: internetCenter, size: CGSize(width: width, height: height))
    }
}

struct EdgeCurve: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let (c1, c2) = Self.controls(from: from, to: to)
        path.move(to: from)
        path.addCurve(to: to, control1: c1, control2: c2)
        return path
    }

    static func controls(from: CGPoint, to: CGPoint) -> (CGPoint, CGPoint) {
        let dx = max(40, (to.x - from.x) * 0.55)
        return (CGPoint(x: from.x + dx, y: from.y), CGPoint(x: to.x - dx, y: to.y))
    }

    static func point(from: CGPoint, to: CGPoint, t: CGFloat) -> CGPoint {
        let (c1, c2) = controls(from: from, to: to)
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(
            x: a * from.x + b * c1.x + c * c2.x + d * to.x,
            y: a * from.y + b * c1.y + c * c2.y + d * to.y
        )
    }
}

private struct EdgePill: View {
    var text: String
    var color: Color

    var body: some View {
        let parts = text.components(separatedBy: " · ")
        let primary = parts.count >= 3 ? parts[1] : text
        let secondary = parts.count >= 3 ? ([parts[0]] + parts[2...]).joined(separator: " · ") : nil
        VStack(spacing: 0) {
            Text(primary)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            if let secondary {
                Text(secondary)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DashboardStyle.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(color.opacity(0.8), lineWidth: 1))
            .foregroundStyle(.primary)
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

private struct InternetBubble: View {
    var wan: WANStatus?

    var body: some View {
        let up = wan?.isConnected ?? true
        VStack(spacing: 6) {
            Circle()
                .fill((up ? Color.blue : MeshPalette.color(.offline)).gradient)
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: up ? "globe.americas.fill" : "globe").font(.system(size: 26)).foregroundStyle(.white))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            Text("Internet")
                .font(.caption.weight(.semibold))
            Text(up ? "Connected" : (wan?.statusText ?? "Down"))
                .font(.caption2)
                .foregroundStyle(up ? Color.secondary : MeshPalette.color(.offline))
        }
        .frame(width: TopologyLayout.internetWidth)
    }
}

struct NodeCard: View {
    var node: MeshNode
    var snapshot: MeshSnapshot
    var selected: Bool
    var hostsThisMac: Bool
    var thresholds: HealthThresholds
    var airwaves: NodeAirwavesReport? = nil
    var openSpectrum: () -> Void = {}

    private var quality: MeshHealth {
        node.isPrimary ? (node.isOnline ? .healthy : .offline) : HealthEvaluator.linkQuality(node, thresholds: thresholds)
    }

    private var ringFraction: Double {
        guard node.isOnline else { return 0.02 }
        if node.isPrimary { return 1 }
        guard let link = node.backhaul else { return 0.5 }
        if link.medium == .wired { return 1 }
        let signal = SignalLevel.fraction(rssi: link.rssiDbm)
        // Not measured yet: judge the ring on signal alone.
        guard let mbps = link.speedMbps else { return max(0.08, signal) }
        let speed = min(1, mbps / max(1, thresholds.minimumBackhaulMbps * 3))
        return max(0.08, (speed + signal) / 2)
    }

    private var clientCount: Int {
        let online = snapshot.clients(of: node.id).filter(\.isOnline).count
        return max(online, node.clientCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                SymbolTile(
                    systemName: node.isPrimary ? "wifi.router.fill" : "dot.radiowaves.left.and.right",
                    tint: node.isOnline ? (node.isPrimary ? .indigo : .teal) : .gray,
                    size: 32
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .help(node.name)
                    HStack(spacing: 5) {
                        Badge(text: node.isPrimary ? "Router" : "Node", tint: node.isPrimary ? .indigo : .teal)
                            .fixedSize()
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
                HealthRing(fraction: ringFraction, tint: MeshPalette.color(quality), lineWidth: 3.5, size: 26)
                    .help(quality.label)
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                stat("Clients", "\(clientCount)")
                stat(node.isPrimary ? "Uplink" : "Backhaul", backhaulValue)
                stat("Uptime", node.uptimeSeconds.map(MeshFormat.uptime) ?? "—")
            }
            HStack(spacing: 6) {
                if node.isOnline {
                    RFChip(report: airwaves)
                        .onTapGesture { openSpectrum() }
                }
                Spacer(minLength: 0)
                if !node.isOnline {
                    Badge(text: "Offline", tint: MeshPalette.color(.offline), filled: true)
                }
                if hostsThisMac {
                    Label("This Mac", systemImage: "laptopcomputer")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DashboardStyle.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : DashboardStyle.hairline, lineWidth: selected ? 2 : 0.75)
        )
        .shadow(color: .black.opacity(selected ? 0.16 : 0.08), radius: selected ? 8 : 4, y: 2)
        .opacity(node.isOnline ? 1 : 0.7)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let model = node.modelNumber { parts.append(model) }
        if let ip = node.ipAddress { parts.append(ip) }
        return parts.isEmpty ? node.role.label : parts.joined(separator: " · ")
    }

    private var backhaulValue: String {
        if node.isPrimary { return snapshot.wan?.isConnected == false ? "Down" : (snapshot.wan?.wanType ?? "WAN") }
        guard node.isOnline else { return "—" }
        guard let link = node.backhaul else { return "—" }
        if let speed = MeshSummary.speedText(link) { return speed }
        return link.medium.label
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LegendSwatch: View {
    var color: Color
    var text: String
    var dashed = false

    var body: some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 18, y: 4))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: dashed ? [4, 3] : []))
            .frame(width: 18, height: 8)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

struct RadioChip: View {
    var radio: RadioInfo

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(radio.isEnabled == false ? Color.secondary.opacity(0.5) : MeshPalette.color(.healthy))
                .frame(width: 6, height: 6)
            Text(radio.bandLabel)
                .fontWeight(.semibold)
            Text(radio.isEnabled == false ? "Off" : radio.chipDetail)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.10), in: Capsule())
        .help(radio.ssid.map { "Network \($0)" } ?? radio.bandLabel)
    }
}

/// Faint dot grid behind the topology, like a canvas.
struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 18
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.6, height: 1.6))
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    context.fill(dot.offsetBy(dx: x, dy: y), with: .color(.primary.opacity(0.09)))
                    x += spacing
                }
                y += spacing
            }
        }
        .background(DashboardStyle.canvasBackground.opacity(0.55))
    }
}
