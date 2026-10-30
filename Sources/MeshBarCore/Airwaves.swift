import Foundation

// MARK: - Bands and spectrum math

public enum WiFiBand: String, CaseIterable, Sendable, Codable, Identifiable, Comparable {
    case ghz24 = "2.4 GHz"
    case ghz5 = "5 GHz"
    case ghz6 = "6 GHz"

    public var id: String { rawValue }
    public var shortLabel: String {
        switch self {
        case .ghz24: return "2.4"
        case .ghz5: return "5"
        case .ghz6: return "6"
        }
    }

    public static func < (lhs: WiFiBand, rhs: WiFiBand) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Accepts JNAP names ("2.4GHz", "RADIO_5GHz", "5GL"), iwlist and CoreWLAN labels.
    public init?(label: String) {
        let s = label.uppercased().replacingOccurrences(of: " ", with: "")
        if s.contains("2.4") || s.contains("2G") { self = .ghz24 }
        else if s.contains("6G") || s.contains("6E") { self = .ghz6 }
        else if s.contains("5G") { self = .ghz5 }
        else { return nil }
    }

    public init?(frequencyMHz: Double) {
        switch frequencyMHz {
        case 2400..<2500: self = .ghz24
        case 5150..<5925: self = .ghz5
        case 5925..<7125: self = .ghz6
        default: return nil
        }
    }

    public func centerMHz(channel: Int) -> Double {
        switch self {
        case .ghz24: return channel == 14 ? 2484 : 2407 + 5 * Double(channel)
        case .ghz5: return 5000 + 5 * Double(channel)
        case .ghz6: return channel == 2 ? 5935 : 5950 + 5 * Double(channel)
        }
    }

    public func channel(frequencyMHz: Double) -> Int {
        switch self {
        case .ghz24: return frequencyMHz >= 2484 ? 14 : Int(((frequencyMHz - 2407) / 5).rounded())
        case .ghz5: return Int(((frequencyMHz - 5000) / 5).rounded())
        case .ghz6: return Int(((frequencyMHz - 5950) / 5).rounded())
        }
    }

    /// Channels drawn on the spectrum axis.
    public var axisChannels: ClosedRange<Int> {
        switch self {
        case .ghz24: return 1...13
        case .ghz5: return 36...165
        case .ghz6: return 1...233
        }
    }

    /// 5 GHz channels that need radar detection (DFS) in the UK/EU and US.
    public static func isDFS(_ channel: Int, band: WiFiBand) -> Bool {
        band == .ghz5 && (52...144).contains(channel)
    }
}

public enum SpectrumMath {
    /// The frequency range a network occupies. 2.4 GHz 40 MHz networks put the
    /// secondary channel above or below; when that is unknown, channels 1–7
    /// go above and 8–13 below, which is what radios do in practice. 5 and
    /// 6 GHz wide channels use the fixed bonding blocks.
    public static func span(band: WiFiBand, channel: Int, widthMHz: Int?, secondaryBelow: Bool? = nil) -> ClosedRange<Double> {
        let width = max(20, widthMHz ?? 20)
        let center = band.centerMHz(channel: channel)
        if width == 20 { return (center - 10)...(center + 10) }
        switch band {
        case .ghz24:
            let below = secondaryBelow ?? (channel >= 8)
            return below ? (center - 30)...(center + 10) : (center - 10)...(center + 30)
        case .ghz5, .ghz6:
            let base = band == .ghz6 ? 1 : (channel >= 149 ? 149 : 36)
            let step = width / 5
            let start = base + ((channel - base) / step) * step
            let lo = band.centerMHz(channel: start) - 10
            return lo...(lo + Double(width))
        }
    }

    public static func overlapMHz(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double {
        max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
    }

    /// "36–64" for a span, using channel numbers at the 20 MHz centres.
    public static func channelRangeLabel(band: WiFiBand, span: ClosedRange<Double>) -> String {
        let first = band.channel(frequencyMHz: span.lowerBound + 10)
        let last = band.channel(frequencyMHz: span.upperBound - 10)
        return first == last ? "\(first)" : "\(first)–\(last)"
    }

    /// Width from an iwlist/Qualcomm phy mode such as `IEEE80211_MODE_11AXA_HE80`,
    /// `11GEHT40MINUS` or `IEEE80211_MODE_11G`.
    public static func width(phyMode: String) -> (width: Int, secondaryBelow: Bool?) {
        let upper = phyMode.uppercased()
        let below: Bool? = upper.hasSuffix("MINUS") ? true : (upper.hasSuffix("PLUS") ? false : nil)
        let trimmed = upper.replacingOccurrences(of: "MINUS", with: "").replacingOccurrences(of: "PLUS", with: "")
        var digits = ""
        for ch in trimmed.reversed() {
            if ch.isNumber { digits.insert(ch, at: digits.startIndex) } else { break }
        }
        let width = Int(digits) ?? 20
        return ([20, 40, 80, 160, 320].contains(width) ? width : 20, below)
    }
}

// MARK: - Models

public enum AirwavesSource: String, Sendable, Equatable {
    /// The router's own site survey (sysinfo.cgi). Heard at the router.
    case routerScan
    /// A CoreWLAN scan from this Mac. Heard wherever the Mac is.
    case thisMac
    case demo

    public var label: String {
        switch self {
        case .routerScan: return "Router site survey"
        case .thisMac: return "Scan from this Mac"
        case .demo: return "Demo data"
        }
    }
}

public struct HeardNetwork: Identifiable, Equatable, Sendable {
    public var id: String
    /// nil when the network hides its name (or macOS withholds it).
    public var ssid: String?
    public var bssid: String?
    public var band: WiFiBand
    public var channel: Int
    public var widthMHz: Int
    public var secondaryBelow: Bool?
    public var rssiDbm: Int
    public var noiseDbm: Int?
    /// One of this mesh's own radios (fronthaul or hidden backhaul).
    public var isOwnMesh: Bool

    public init(id: String, ssid: String?, bssid: String?, band: WiFiBand, channel: Int, widthMHz: Int, secondaryBelow: Bool? = nil, rssiDbm: Int, noiseDbm: Int? = nil, isOwnMesh: Bool = false) {
        self.id = id
        self.ssid = ssid
        self.bssid = bssid
        self.band = band
        self.channel = channel
        self.widthMHz = widthMHz
        self.secondaryBelow = secondaryBelow
        self.rssiDbm = rssiDbm
        self.noiseDbm = noiseDbm
        self.isOwnMesh = isOwnMesh
    }

    public var displayName: String {
        if let ssid, !ssid.isEmpty { return ssid }
        return "Hidden network"
    }

    public var span: ClosedRange<Double> {
        SpectrumMath.span(band: band, channel: channel, widthMHz: widthMHz, secondaryBelow: secondaryBelow)
    }

    public var strength: SignalStrength { SignalStrength(rssi: rssiDbm) }
}

public enum SignalStrength: Int, Comparable, Sendable {
    case faint, weak, moderate, strong

    public init(rssi: Int) {
        switch rssi {
        case (-60)...: self = .strong
        case (-70)...: self = .moderate
        case (-80)...: self = .weak
        default: self = .faint
        }
    }

    public var label: String {
        switch self {
        case .strong: return "strong"
        case .moderate: return "moderate"
        case .weak: return "weak"
        case .faint: return "faint"
        }
    }

    /// How much one network like this loads a shared channel.
    public var weight: Double {
        switch self {
        case .strong: return 1.0
        case .moderate: return 0.6
        case .weak: return 0.25
        case .faint: return 0.08
        }
    }

    public static func < (lhs: SignalStrength, rhs: SignalStrength) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What one of our radios is set to.
public struct NodeRadio: Equatable, Sendable, Identifiable {
    public var nodeID: String
    public var band: WiFiBand
    public var channel: Int
    public var widthMHz: Int?
    public var secondaryBelow: Bool?

    public var id: String { "\(nodeID)|\(band.rawValue)" }

    public init(nodeID: String, band: WiFiBand, channel: Int, widthMHz: Int? = nil, secondaryBelow: Bool? = nil) {
        self.nodeID = nodeID
        self.band = band
        self.channel = channel
        self.widthMHz = widthMHz
        self.secondaryBelow = secondaryBelow
    }

    public var span: ClosedRange<Double> {
        SpectrumMath.span(band: band, channel: channel, widthMHz: widthMHz, secondaryBelow: secondaryBelow)
    }
}

/// Per-radio counters from the router's own stats. Router only.
public struct RadioAirStats: Equatable, Sendable {
    public var band: WiFiBand
    /// Percent of airtime used by our own BSS.
    public var selfUtilization: Int?
    /// Percent of airtime used by other (overlapping) networks.
    public var otherUtilization: Int?
    /// Board-averaged noise floor in dBm.
    public var noiseFloorDbm: Int?

    public init(band: WiFiBand, selfUtilization: Int? = nil, otherUtilization: Int? = nil, noiseFloorDbm: Int? = nil) {
        self.band = band
        self.selfUtilization = selfUtilization
        self.otherUtilization = otherUtilization
        self.noiseFloorDbm = noiseFloorDbm
    }
}

/// One scan of nearby networks, from one place.
public struct AirwavesScan: Equatable, Sendable {
    public var source: AirwavesSource
    public var capturedAt: Date
    /// The node the scanner sits at or next to, when known.
    public var heardAtNodeID: String?
    public var networks: [HeardNetwork]
    public var stats: [RadioAirStats]
    /// The scanner's own radio settings (router scans only), keyed by band.
    public var scannerRadios: [WiFiBand: NodeRadio]
    public var radarEvents: Int?
    /// Bands the scanner covered. A band missing here was not scanned.
    public var scannedBands: Set<WiFiBand>

    public init(source: AirwavesSource, capturedAt: Date, heardAtNodeID: String? = nil, networks: [HeardNetwork], stats: [RadioAirStats] = [], scannerRadios: [WiFiBand: NodeRadio] = [:], radarEvents: Int? = nil, scannedBands: Set<WiFiBand> = Set(WiFiBand.allCases)) {
        self.source = source
        self.capturedAt = capturedAt
        self.heardAtNodeID = heardAtNodeID
        self.networks = networks
        self.stats = stats
        self.scannerRadios = scannerRadios
        self.radarEvents = radarEvents
        self.scannedBands = scannedBands
    }

    public func neighbours(on band: WiFiBand) -> [HeardNetwork] {
        networks.filter { $0.band == band && !$0.isOwnMesh }
    }

    public func stats(for band: WiFiBand) -> RadioAirStats? { stats.first { $0.band == band } }
}

/// Channels every node is on, from nodes/setup/GetSelectedChannels.
public struct ChannelPlan: Equatable, Sendable {
    public var radios: [NodeRadio]
    public var isDFSEnabled: Bool?
    public var isDFSSupported: Bool?

    public init(radios: [NodeRadio], isDFSEnabled: Bool? = nil, isDFSSupported: Bool? = nil) {
        self.radios = radios
        self.isDFSEnabled = isDFSEnabled
        self.isDFSSupported = isDFSSupported
    }

    public func radios(of nodeID: String) -> [NodeRadio] {
        radios.filter { $0.nodeID.caseInsensitiveCompare(nodeID) == .orderedSame }.sorted { $0.band < $1.band }
    }
}

// MARK: - Own-mesh matching

public enum OwnMeshMatcher {
    /// Linksys node radios (fronthaul, guest and hidden backhaul BSSIDs) share
    /// the middle four octets of the node MAC; the first octet flips the
    /// locally administered bit and the last one counts up. Match on those.
    public static func key(_ mac: String) -> String? {
        let parts = mac.uppercased().split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        return parts[1...4].joined(separator: ":")
    }

    public static func keys(_ macs: [String]) -> Set<String> {
        Set(macs.compactMap(key))
    }

    public static func isOwn(bssid: String?, ssid: String?, keys: Set<String>, ownSSIDs: Set<String>) -> Bool {
        if let ssid, !ssid.isEmpty, ownSSIDs.contains(ssid) { return true }
        if let bssid, let k = key(bssid), keys.contains(k) { return true }
        return false
    }
}
