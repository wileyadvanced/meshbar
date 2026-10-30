import AppKit
import MeshBarCore
import SwiftUI

/// Shared building blocks for the dashboard: cards, badges, rings and bars.
/// Colours come from semantic system colours so light and dark both work.
enum DashboardStyle {
    static let cardRadius: CGFloat = 12
    static var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var canvasBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var hairline: Color { Color(nsColor: .separatorColor) }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(DashboardStyle.cardBackground, in: RoundedRectangle(cornerRadius: DashboardStyle.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DashboardStyle.cardRadius, style: .continuous)
                    .strokeBorder(DashboardStyle.hairline.opacity(0.6), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

extension View {
    func dashboardCard(padding: CGFloat = 14) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// Rounded-square SF Symbol tile, like System Settings.
struct SymbolTile: View {
    var systemName: String
    var tint: Color
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

struct StatCard: View {
    var title: String
    var value: String
    var detail: String
    var systemName: String
    var tint: Color
    var accessory: AnyView? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let accessory {
                accessory
            } else {
                SymbolTile(systemName: systemName, tint: tint, size: 34)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .dashboardCard(padding: 14)
    }
}

/// Ring that fills to `fraction` in `tint`.
struct HealthRing: View {
    var fraction: Double
    var tint: Color
    var lineWidth: CGFloat = 4
    var size: CGFloat = 28
    var label: String? = nil

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let label {
                Text(label)
                    .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
    }
}

/// Four Wi-Fi-style bars for an RSSI value.
struct SignalBars: View {
    var rssi: Int?
    var wired = false
    var height: CGFloat = 11

    private var lit: Int {
        if wired { return 4 }
        guard let rssi else { return 0 }
        switch rssi {
        case (-55)...: return 4
        case (-65)...: return 3
        case (-75)...: return 2
        default: return 1
        }
    }

    private var tint: Color {
        switch lit {
        case 4, 3: return MeshPalette.color(.healthy)
        case 2: return MeshPalette.color(.degraded)
        case 1: return MeshPalette.color(.offline)
        default: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < lit ? tint : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: height * CGFloat(index + 1) / 4)
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityLabel(rssi.map { "\($0) dBm" } ?? (wired ? "Wired" : "No signal reading"))
    }
}

struct Badge: View {
    var text: String
    var tint: Color = .secondary
    var filled = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(filled ? Color.white : tint)
            .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)), in: Capsule())
    }
}

struct HealthDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(color.opacity(0.3), lineWidth: 3).blur(radius: 1))
    }
}

/// Small header used inside cards and inspector sections.
struct SectionHeader: View {
    var title: String
    var systemName: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemName {
                Image(systemName: systemName)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
        }
    }
}

/// Derived numbers the dashboard shows: score, weakest link and so on.
enum MeshSummary {
    /// 0...100. WAN down is 0. Each satellite scores 100 when its backhaul
    /// meets the thresholds, 55 when weak, 0 when offline.
    static func score(_ snapshot: MeshSnapshot, thresholds: HealthThresholds) -> Int {
        if snapshot.wan?.isConnected == false { return 0 }
        let satellites = snapshot.nodes.filter { !$0.isPrimary }
        guard !satellites.isEmpty else { return snapshot.nodes.isEmpty ? 0 : 100 }
        let total = satellites.reduce(0.0) { sum, node in
            switch HealthEvaluator.linkQuality(node, thresholds: thresholds) {
            case .healthy: return sum + 100
            case .degraded: return sum + linkPenaltyScore(node, thresholds: thresholds)
            default: return sum
            }
        }
        return Int((total / Double(satellites.count)).rounded())
    }

    private static func linkPenaltyScore(_ node: MeshNode, thresholds: HealthThresholds) -> Double {
        guard let link = node.backhaul else { return 50 }
        var score = 70.0
        if let speed = link.speedMbps, speed < thresholds.minimumBackhaulMbps {
            score -= 20 * (1 - speed / thresholds.minimumBackhaulMbps)
        }
        if let rssi = link.rssiDbm, rssi < thresholds.minimumRSSI {
            score -= Double(min(25, thresholds.minimumRSSI - rssi))
        }
        return max(30, score)
    }

    /// The online wireless satellite with the slowest (then weakest) backhaul.
    static func weakestLink(_ snapshot: MeshSnapshot) -> MeshNode? {
        snapshot.nodes
            .filter { !$0.isPrimary && $0.isOnline && $0.backhaul != nil }
            .min { lhs, rhs in
                let l = lhs.backhaul?.speedMbps ?? .infinity
                let r = rhs.backhaul?.speedMbps ?? .infinity
                if l != r { return l < r }
                return (lhs.backhaul?.rssiDbm ?? 0) < (rhs.backhaul?.rssiDbm ?? 0)
            }
    }

    static func scoreColor(_ score: Int) -> Color {
        switch score {
        case 85...: return MeshPalette.color(.healthy)
        case 60...: return MeshPalette.color(.partial)
        case 30...: return MeshPalette.color(.degraded)
        default: return MeshPalette.color(.offline)
        }
    }

    static func nodeName(_ id: String?, in snapshot: MeshSnapshot) -> String {
        id.flatMap { snapshot.node(id: $0)?.name } ?? "—"
    }

    static let measuring = "Measuring…"

    /// Speed text for a link: a value, "Measuring…" while the router has not
    /// measured it yet, or nil when nothing is known.
    static func speedText(_ link: BackhaulLink?) -> String? {
        guard let link else { return nil }
        if let mbps = link.speedMbps { return speed(mbps) }
        return link.isAwaitingSpeed ? measuring : nil
    }

    static func speed(_ mbps: Double) -> String {
        if mbps >= 1000 { return String(format: "%.1f Gbps", mbps / 1000) }
        return String(format: "%.0f Mbps", mbps)
    }

    /// "5GH · 176 Mbps · −49 dBm" or "Wired · 1.0 Gbps".
    static func edgeLabel(_ node: MeshNode) -> String {
        guard node.isOnline else { return "Offline" }
        guard let link = node.backhaul else { return "No reading" }
        var parts: [String] = []
        if link.medium == .wired {
            parts.append("Wired")
        } else if let band = BandFormat.short(link.band) {
            parts.append(band)
        }
        if let mbps = link.speedMbps { parts.append(Self.speed(mbps)) } else if link.isAwaitingSpeed { parts.append(Self.measuring) }
        if link.medium != .wired, let rssi = link.rssiDbm { parts.append("\(rssi) dBm".replacingOccurrences(of: "-", with: "−")) }
        return parts.isEmpty ? link.medium.label : parts.joined(separator: " · ")
    }

    static func dBm(_ rssi: Int) -> String {
        "\(rssi) dBm".replacingOccurrences(of: "-", with: "−")
    }
}
