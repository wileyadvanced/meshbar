import Foundation

/// Speed-test bandwidth units.
///
/// `healthcheck/GetHealthCheckResults` reports `downloadBandwidth` and
/// `uploadBandwidth` in kilobits per second (a Pinnacle on a 10 Gb WAN port
/// reported 3171513, i.e. about 3.2 Gbps). Older `downloadSpeed` and
/// `uploadSpeed` fields have no documented unit, so they keep a magnitude
/// heuristic: under 10_000 is Mbps, under 100_000_000 is kbps, else bps.
public enum BandwidthUnits {
    public static func megabitsPerSecond(fromKilobits kbps: Double) -> Double {
        kbps / 1_000
    }

    /// "940" + "Mbps", "3.17" + "Gbps".
    public static func display(_ mbps: Double) -> (value: String, unit: String) {
        if mbps >= 1_000 { return (String(format: "%.2f", mbps / 1_000), "Gbps") }
        if mbps >= 100 { return (String(format: "%.0f", mbps), "Mbps") }
        return (String(format: "%.1f", mbps), "Mbps")
    }

    public static func megabitsPerSecond(fromRaw raw: Double) -> Double {
        let magnitude = abs(raw)
        if magnitude >= 100_000_000 {
            return raw / 1_000_000
        }
        if magnitude >= 10_000 {
            return raw / 1_000
        }
        return raw
    }
}

public enum JNAPDate {
    public static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        if let date = basic.date(from: text) { return date }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            plain.dateFormat = format
            if let date = plain.date(from: text) { return date }
        }
        return nil
    }
}

/// What the URLSession trust delegate is allowed to do.
/// `acceptPinnedHost` is the only decision that uses the presented certificate,
/// and only after the challenged host equals the configured router host.
public enum TrustDecision: Equatable {
    case defaultHandling
    case cancel
    case acceptPinnedHost
}

public enum ServerTrustPolicy {
    public static func decision(
        trustSelfSigned: Bool,
        challengedHost: String,
        configuredHost: String,
        isServerTrustChallenge: Bool
    ) -> TrustDecision {
        guard isServerTrustChallenge else { return .defaultHandling }
        guard trustSelfSigned else { return .defaultHandling }
        guard hostsMatch(challengedHost, configuredHost) else { return .cancel }
        return .acceptPinnedHost
    }

    public static func hostsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
