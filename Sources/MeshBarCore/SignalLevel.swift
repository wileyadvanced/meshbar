import Foundation

/// Maps an RSSI reading to the 0...1 value SF Symbols use for variable
/// Wi-Fi bars, with steps close to the macOS Wi-Fi menu.
public enum SignalLevel {
    public static func fraction(rssi: Int?) -> Double {
        guard let rssi else { return 1 }
        switch rssi {
        case (-60)...: return 1
        case (-70)...: return 0.66
        case (-80)...: return 0.33
        default: return 0.1
        }
    }

    /// Bars for the node this Mac is on: the weaker of the Mac's own link and
    /// that node's backhaul. Wired links and the router count as full.
    public static func forThisMac(client: ClientDevice?, node: MeshNode?) -> Double {
        var level = 1.0
        if let client, client.medium != .wired, let rssi = client.rssiDbm {
            level = min(level, fraction(rssi: rssi))
        }
        if let node, !node.isPrimary, let link = node.backhaul, link.medium != .wired {
            level = min(level, fraction(rssi: link.rssiDbm))
        }
        return level
    }
}
