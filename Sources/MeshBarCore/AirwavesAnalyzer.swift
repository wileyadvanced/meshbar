import Foundation

public enum Congestion: Int, Comparable, Sendable, CaseIterable {
    case clear, light, busy, crowded

    public init(score: Double) {
        switch score {
        case ..<0.5: self = .clear
        case ..<1.5: self = .light
        case ..<3: self = .busy
        default: self = .crowded
        }
    }

    public var label: String {
        switch self {
        case .clear: return "Clear"
        case .light: return "Light"
        case .busy: return "Busy"
        case .crowded: return "Crowded"
        }
    }

    public static func < (lhs: Congestion, rhs: Congestion) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct NeighbourOverlap: Identifiable, Equatable, Sendable {
    public var network: HeardNetwork
    public var overlapMHz: Double
    /// Same primary channel: radios take turns politely.
    public var isCoChannel: Bool
    /// Partly overlapping on 2.4 GHz: radios can't decode each other, so it's noise.
    public var isPartial: Bool
    public var id: String { network.id }
}

public struct ChannelSuggestion: Equatable, Sendable {
    public var channel: Int
    public var widthMHz: Int
    public var score: Double
    public var needsDFS: Bool

    public func label(band: WiFiBand) -> String {
        let span = SpectrumMath.span(band: band, channel: channel, widthMHz: widthMHz)
        let range = widthMHz > 20 && band != .ghz24 ? " (\(SpectrumMath.channelRangeLabel(band: band, span: span)))" : ""
        return "ch \(channel) at \(widthMHz) MHz\(range)"
    }
}

public struct BandAssessment: Identifiable, Equatable, Sendable {
    public var radio: NodeRadio
    public var overlaps: [NeighbourOverlap]
    public var score: Double
    public var congestion: Congestion
    public var stats: RadioAirStats?
    public var suggestion: ChannelSuggestion?
    public var verdict: String
    /// False when the scan didn't cover this band.
    public var wasScanned: Bool

    public var id: String { radio.id }
    public var band: WiFiBand { radio.band }
    public var coChannelCount: Int { overlaps.filter(\.isCoChannel).count }
    public var partialCount: Int { overlaps.filter(\.isPartial).count }
    public var strongCount: Int { overlaps.filter { $0.network.strength >= .moderate }.count }
}

public struct AirwavesHint: Identifiable, Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case info, notice, warning
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String
    public var severity: Severity
    public var symbol: String
    public var title: String
    public var detail: String
    /// Generic advice about things a router can't see. Never claimed as detected.
    public var isGeneric: Bool

    public init(id: String, severity: Severity, symbol: String, title: String, detail: String, isGeneric: Bool = false) {
        self.id = id
        self.severity = severity
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.isGeneric = isGeneric
    }
}

public struct NodeAirwavesReport: Equatable, Sendable {
    public var nodeID: String
    public var radios: [NodeRadio]
    public var scan: AirwavesScan?
    /// True when the scan was heard at (or right next to) this node.
    public var scanIsLocal: Bool
    public var bands: [BandAssessment]
    public var hints: [AirwavesHint]

    public var worst: Congestion? { bands.filter(\.wasScanned).map(\.congestion).max() }
    public func assessment(_ band: WiFiBand) -> BandAssessment? { bands.first { $0.band == band } }
}

public enum AirwavesAnalyzer {
    public static let nonOverlapping24 = [1, 6, 11]

    /// How loaded a span is by the given neighbours (own mesh excluded).
    public static func load(band: WiFiBand, span: ClosedRange<Double>, primary: Int?, networks: [HeardNetwork]) -> (score: Double, overlaps: [NeighbourOverlap]) {
        var score = 0.0
        var overlaps: [NeighbourOverlap] = []
        let ourWidth = span.upperBound - span.lowerBound
        for network in networks where network.band == band && !network.isOwnMesh {
            let theirs = network.span
            let overlap = SpectrumMath.overlapMHz(span, theirs)
            guard overlap > 0 else { continue }
            let fraction = overlap / max(1, min(ourWidth, theirs.upperBound - theirs.lowerBound))
            let coChannel = primary == network.channel
            let partial = band == .ghz24 && !coChannel
            // Partial 2.4 GHz overlap is worse than sharing: it's undecodable noise.
            score += network.strength.weight * fraction * (partial ? 1.2 : 1.0)
            overlaps.append(NeighbourOverlap(network: network, overlapMHz: overlap, isCoChannel: coChannel, isPartial: partial))
        }
        overlaps.sort { $0.network.rssiDbm > $1.network.rssiDbm }
        return (score, overlaps)
    }

    static func congestion(score: Double, stats: RadioAirStats?) -> Congestion {
        var level = Congestion(score: score)
        if let other = stats?.otherUtilization {
            if other >= 50 { level = max(level, .crowded) } else if other >= 30 { level = max(level, .busy) }
        }
        return level
    }

    /// Candidate primaries for a width. 5 GHz stays within 36–144 (DFS above 48).
    static func candidates(band: WiFiBand, width: Int) -> [Int] {
        switch band {
        case .ghz24:
            return nonOverlapping24
        case .ghz5:
            // Bonding blocks that fit inside 36–64 or 100–144 (UK/EU without UNII-3).
            let step = max(4, width / 5)
            return (Array(stride(from: 36, through: 64, by: step)) + Array(stride(from: 100, through: 144, by: step))).filter { start in
                let end = start + step - 4
                return (start <= 64 && end <= 64) || (start >= 100 && end <= 144)
            }
        case .ghz6:
            let step = max(4, width / 5)
            return Array(stride(from: 1, through: 233, by: step))
        }
    }

    static func suggest(radio: NodeRadio, currentScore: Double, networks: [HeardNetwork], dfsEnabled: Bool?) -> ChannelSuggestion? {
        guard currentScore >= 0.8 else { return nil }
        var widths = [radio.widthMHz ?? 20]
        var extra: [Int] = []
        if radio.band == .ghz24 {
            widths = [20]
            // Narrowing in place is always an option on 2.4 GHz.
            if (radio.widthMHz ?? 20) > 20 { extra = [radio.channel] }
        }
        if radio.band == .ghz5, let w = radio.widthMHz, w >= 160 { widths.append(80) }
        var options: [ChannelSuggestion] = []
        for width in widths {
            for channel in Array(Set(candidates(band: radio.band, width: width) + extra)).sorted() {
                let span = SpectrumMath.span(band: radio.band, channel: channel, widthMHz: width)
                let score = load(band: radio.band, span: span, primary: channel, networks: networks).score
                // A narrower channel carries less; only worth it when much quieter.
                let penalty = width < (radio.widthMHz ?? width) && radio.band != .ghz24 ? 0.4 : 0
                options.append(ChannelSuggestion(channel: channel, widthMHz: width, score: score + penalty, needsDFS: WiFiBand.isDFS(channel, band: radio.band) || (radio.band == .ghz5 && span.upperBound > 5250)))
            }
        }
        // Prefer what works today; DFS options only when clearly better still.
        let allowed = options.filter { !$0.needsDFS || dfsEnabled == true }.min { $0.score < $1.score }
        let withDFS = options.filter(\.needsDFS).min { $0.score < $1.score }
        func better(_ s: ChannelSuggestion?) -> ChannelSuggestion? {
            guard let s, s.score < currentScore * 0.65, currentScore - s.score >= 0.5 else { return nil }
            if s.channel == radio.channel && s.widthMHz == radio.widthMHz { return nil }
            return s
        }
        if let a = better(allowed) {
            if dfsEnabled != true, let d = better(withDFS), d.score < a.score * 0.5 { return d }
            return a
        }
        return dfsEnabled == true ? nil : better(withDFS)
    }

    public static func assess(radio: NodeRadio, scan: AirwavesScan?, dfsEnabled: Bool?) -> BandAssessment {
        let networks = scan?.networks ?? []
        let scanned = scan?.scannedBands.contains(radio.band) ?? false
        let stats = scan?.stats(for: radio.band)
        let result = load(band: radio.band, span: radio.span, primary: radio.channel, networks: networks)
        let level = congestion(score: result.score, stats: stats)
        let suggestion = scanned ? suggest(radio: radio, currentScore: result.score, networks: networks, dfsEnabled: dfsEnabled) : nil
        var assessment = BandAssessment(radio: radio, overlaps: result.overlaps, score: result.score, congestion: level, stats: stats, suggestion: suggestion, verdict: "", wasScanned: scanned)
        assessment.verdict = verdict(assessment, dfsEnabled: dfsEnabled)
        return assessment
    }

    static func verdict(_ a: BandAssessment, dfsEnabled: Bool?) -> String {
        let width = a.radio.widthMHz.map { " (\($0) MHz)" } ?? ""
        let head = "\(a.band.rawValue) ch \(a.radio.channel)\(width)"
        guard a.wasScanned else { return "\(head): no scan of this band yet." }
        if a.overlaps.isEmpty { return "\(head) has the air to itself. Nothing to change." }
        let n = a.overlaps.count
        var text = "\(head) shares the air with \(n) network\(n == 1 ? "" : "s")"
        let strong = a.strongCount
        text += strong > 0 ? ", \(strong) of them strong" : ", none of them strong"
        text += " — \(a.congestion.label.lowercased())."
        if let s = a.suggestion, s.channel == a.radio.channel {
            text += " Consider narrowing to \(s.widthMHz) MHz on the same channel."
        } else if let s = a.suggestion {
            text += " Consider \(s.label(band: a.band))"
            text += s.needsDFS && dfsEnabled != true ? ", which needs DFS turned on." : "."
        } else if a.congestion <= .light {
            text += " Fine as it is."
        } else {
            text += " No clearly quieter channel nearby."
        }
        return text
    }

    /// Pick the best scan for a node: one heard at the node, else the router's, else this Mac's.
    public static func bestScan(for nodeID: String, routerID: String?, scans: [AirwavesScan]) -> (scan: AirwavesScan, isLocal: Bool)? {
        if let local = scans.first(where: { $0.heardAtNodeID?.caseInsensitiveCompare(nodeID) == .orderedSame }) {
            return (local, true)
        }
        if let routerID, let router = scans.first(where: { $0.source != .thisMac && $0.heardAtNodeID?.caseInsensitiveCompare(routerID) == .orderedSame }) {
            return (router, false)
        }
        if let any = scans.first { return (any, false) }
        return nil
    }

    public static func report(node: MeshNode, plan: ChannelPlan?, scans: [AirwavesScan], routerID: String?, weakBackhaulMbps: Double = 150) -> NodeAirwavesReport {
        var radios = plan?.radios(of: node.id) ?? []
        let picked = bestScan(for: node.id, routerID: routerID, scans: scans)
        // Widths: the router's come from its own settings; an extender's from
        // its own beacon in the scan (same band and channel, our mesh); else the
        // mesh-wide 5/6 GHz width, and 20 MHz on 2.4 GHz.
        let routerScan = scans.first(where: { $0.source == .routerScan || $0.source == .demo })
        for i in radios.indices where radios[i].widthMHz == nil {
            let r = radios[i]
            if node.isPrimary, let known = routerScan?.scannerRadios[r.band], known.channel == r.channel {
                radios[i].widthMHz = known.widthMHz
                radios[i].secondaryBelow = known.secondaryBelow
            } else if let beacon = scans.flatMap(\.networks).filter({ $0.isOwnMesh && $0.band == r.band && $0.channel == r.channel }).max(by: { $0.rssiDbm < $1.rssiDbm }) {
                radios[i].widthMHz = beacon.widthMHz
                radios[i].secondaryBelow = beacon.secondaryBelow
            } else if r.band != .ghz24, let known = routerScan?.scannerRadios[r.band], known.channel == r.channel {
                radios[i].widthMHz = known.widthMHz
            } else if r.band == .ghz24 {
                radios[i].widthMHz = 20
            }
        }
        if radios.isEmpty, node.isPrimary, let routerScan = scans.first(where: { $0.source == .routerScan || $0.source == .demo }) {
            radios = routerScan.scannerRadios.values.map { NodeRadio(nodeID: node.id, band: $0.band, channel: $0.channel, widthMHz: $0.widthMHz, secondaryBelow: $0.secondaryBelow) }.sorted { $0.band < $1.band }
        }
        let bands = radios.map { assess(radio: $0, scan: picked?.scan, dfsEnabled: plan?.isDFSEnabled) }
        let hints = self.hints(node: node, bands: bands, scan: picked?.scan, plan: plan, weakBackhaulMbps: weakBackhaulMbps)
        return NodeAirwavesReport(nodeID: node.id, radios: radios, scan: picked?.scan, scanIsLocal: picked?.isLocal ?? false, bands: bands, hints: hints)
    }

    static func hints(node: MeshNode, bands: [BandAssessment], scan: AirwavesScan?, plan: ChannelPlan?, weakBackhaulMbps: Double) -> [AirwavesHint] {
        var hints: [AirwavesHint] = []
        let neighbours24 = scan?.neighbours(on: .ghz24).count ?? 0
        for a in bands where a.wasScanned {
            let r = a.radio
            if a.band == .ghz24, !nonOverlapping24.contains(r.channel), a.partialCount > 0 {
                hints.append(AirwavesHint(
                    id: "offgrid-\(r.id)", severity: .warning, symbol: "waveform.path.badge.minus",
                    title: "2.4 GHz ch \(r.channel) is off the 1 / 6 / 11 grid",
                    detail: "It partly overlaps \(a.partialCount) network\(a.partialCount == 1 ? "" : "s") on neighbouring channels. Partly overlapping radios can't decode each other, so they act as noise instead of taking turns. Channels 1, 6 and 11 don't overlap\(r.channel == 13 ? "; 13 is legal in the UK and EU, but the neighbours here use 1 / 6 / 11" : "")."
                ))
            }
            if a.band == .ghz24, (r.widthMHz ?? 20) >= 40, neighbours24 >= 6 {
                hints.append(AirwavesHint(
                    id: "wide24-\(r.id)", severity: .warning, symbol: "arrow.left.and.right",
                    title: "40 MHz on a crowded 2.4 GHz band",
                    detail: "\(neighbours24) networks are heard on 2.4 GHz. A 40 MHz channel there covers two-thirds of the band and collides with most of them; 20 MHz is usually faster in practice."
                ))
            }
            if a.band == .ghz5, (r.widthMHz ?? 0) >= 160, a.overlaps.count >= 3 {
                let range = SpectrumMath.channelRangeLabel(band: .ghz5, span: r.span)
                hints.append(AirwavesHint(
                    id: "wide5-\(r.id)", severity: .notice, symbol: "arrow.left.and.right",
                    title: "160 MHz spans ch \(range)",
                    detail: "That block overlaps \(a.overlaps.count) neighbouring networks. Any of them transmitting makes the whole channel wait. 80 MHz halves the exposure at some cost to peak speed."
                ))
            }
            if a.coChannelCount >= 3 {
                hints.append(AirwavesHint(
                    id: "cochannel-\(r.id)", severity: .notice, symbol: "person.3",
                    title: "\(a.coChannelCount) networks on exactly ch \(r.channel)",
                    detail: "They take turns with you for airtime on \(a.band.rawValue)."
                ))
            }
            if let other = a.stats?.otherUtilization, other >= 30 {
                hints.append(AirwavesHint(
                    id: "obss-\(r.id)", severity: .warning, symbol: "chart.bar.fill",
                    title: "Neighbours use \(other)% of \(a.band.rawValue) airtime",
                    detail: "Measured by the router's radio: that share of time the channel was busy with other networks' traffic."
                ))
            }
            if let s = a.suggestion, s.needsDFS, plan?.isDFSEnabled == false {
                hints.append(AirwavesHint(
                    id: "dfs-\(r.id)", severity: .info, symbol: "dot.radiowaves.up.forward",
                    title: "DFS is off, which limits 5 GHz to ch 36–48",
                    detail: "Turning on DFS in the Linksys app would open ch 52–144, which are quieter here (\(s.label(band: .ghz5)) scores best). DFS channels must go silent briefly if weather or aviation radar is detected."
                ))
            }
            if WiFiBand.isDFS(r.channel, band: r.band) {
                let radar = scan?.radarEvents.map { "\($0) radar event\($0 == 1 ? "" : "s") logged." } ?? ""
                hints.append(AirwavesHint(
                    id: "ondfs-\(r.id)", severity: .info, symbol: "dot.radiowaves.up.forward",
                    title: "On a DFS channel",
                    detail: "Ch \(r.channel) is shared with radar. If radar is detected the radio moves and clients briefly drop. \(radar)"
                ))
            }
        }
        if !node.isPrimary, let link = node.backhaul, link.medium == .wireless {
            let band = link.band.flatMap(WiFiBand.init(label:)) ?? .ghz5
            let assessment = bands.first { $0.band == band && (link.channel == nil || $0.radio.channel == link.channel || $0.radio.span.contains(band.centerMHz(channel: link.channel ?? 0))) }
            let weak = (link.speedMbps.map { $0 < weakBackhaulMbps } ?? false) || (link.rssiDbm.map { $0 < -70 } ?? false)
            if weak, let assessment, assessment.congestion >= .busy {
                hints.append(AirwavesHint(
                    id: "backhaul-\(node.id)", severity: .warning, symbol: "point.3.connected.trianglepath.dotted",
                    title: "Weak backhaul on a \(assessment.congestion.label.lowercased()) channel",
                    detail: "This node's link to the mesh is weak and its channel is shared with \(assessment.overlaps.count) networks. Moving the node closer, or a wired backhaul, helps more than a channel change."
                ))
            }
        }
        return hints.sorted { $0.severity > $1.severity }
    }

    /// Things no router can see. Shown as general guidance, never as findings.
    public static func commonCulprits(bands: Set<WiFiBand>) -> [AirwavesHint] {
        var list: [AirwavesHint] = []
        if bands.contains(.ghz24) || bands.isEmpty {
            list += [
                AirwavesHint(id: "g-microwave", severity: .info, symbol: "microwave", title: "Microwave ovens", detail: "Leak around 2.45 GHz (ch 6–11) while running. Keep nodes a few metres away.", isGeneric: true),
                AirwavesHint(id: "g-bluetooth", severity: .info, symbol: "headphones", title: "Bluetooth, Zigbee and Thread", detail: "Headphones, keyboards and smart-home hubs share 2.4 GHz. Zigbee on its ch 25/26 sits above Wi-Fi ch 11.", isGeneric: true),
                AirwavesHint(id: "g-monitors", severity: .info, symbol: "video", title: "Baby monitors, cameras, video senders", detail: "Analogue 2.4 GHz monitors and AV senders transmit continuously. DECT phones don't use Wi-Fi bands.", isGeneric: true),
                AirwavesHint(id: "g-usb3", severity: .info, symbol: "externaldrive", title: "USB 3 drives and hubs", detail: "Unshielded USB 3 ports radiate noise across 2.4 GHz. Keep them away from nodes.", isGeneric: true),
            ]
        }
        list.append(AirwavesHint(id: "g-materials", severity: .info, symbol: "square.stack.3d.down.right", title: "Building materials", detail: "Metal, mirrors, foil-backed insulation, water (fish tanks, radiators) and concrete absorb 5 and 6 GHz far more than 2.4 GHz.", isGeneric: true))
        return list
    }
}
