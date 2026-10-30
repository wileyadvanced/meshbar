import AppKit
import Darwin
import Foundation
import MeshBarCore
import Security
import ServiceManagement
import SwiftUI
import UserNotifications

struct AppSettings: Codable, Equatable {
    var routerHost: String
    var username: String
    var useHTTPS: Bool
    var trustSelfSignedCertificate: Bool
    var pollIntervalSeconds: Int
    var retentionDays: Int
    var minimumBackhaulMbps: Double
    var minimumRSSI: Int
    var launchAtLogin: Bool
    var demoMode: Bool

    static let `default` = AppSettings(
        routerHost: "192.168.1.1",
        username: "admin",
        useHTTPS: true,
        trustSelfSignedCertificate: false,
        pollIntervalSeconds: 60,
        retentionDays: 30,
        minimumBackhaulMbps: 100,
        minimumRSSI: -70,
        launchAtLogin: false,
        demoMode: false
    )

    var thresholds: HealthThresholds {
        HealthThresholds(minimumBackhaulMbps: minimumBackhaulMbps, minimumRSSI: minimumRSSI).clamped
    }

    var pollIntervalClamped: Int { min(3600, max(15, pollIntervalSeconds)) }
    var retentionClamped: Int { min(365, max(1, retentionDays)) }

    init(
        routerHost: String,
        username: String,
        useHTTPS: Bool,
        trustSelfSignedCertificate: Bool,
        pollIntervalSeconds: Int,
        retentionDays: Int,
        minimumBackhaulMbps: Double,
        minimumRSSI: Int,
        launchAtLogin: Bool,
        demoMode: Bool
    ) {
        self.routerHost = routerHost
        self.username = username
        self.useHTTPS = useHTTPS
        self.trustSelfSignedCertificate = trustSelfSignedCertificate
        self.pollIntervalSeconds = pollIntervalSeconds
        self.retentionDays = retentionDays
        self.minimumBackhaulMbps = minimumBackhaulMbps
        self.minimumRSSI = minimumRSSI
        self.launchAtLogin = launchAtLogin
        self.demoMode = demoMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = AppSettings.default
        routerHost = try container.decodeIfPresent(String.self, forKey: .routerHost) ?? base.routerHost
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? base.username
        useHTTPS = try container.decodeIfPresent(Bool.self, forKey: .useHTTPS) ?? base.useHTTPS
        trustSelfSignedCertificate = try container.decodeIfPresent(Bool.self, forKey: .trustSelfSignedCertificate) ?? base.trustSelfSignedCertificate
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? base.pollIntervalSeconds
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? base.retentionDays
        minimumBackhaulMbps = try container.decodeIfPresent(Double.self, forKey: .minimumBackhaulMbps) ?? base.minimumBackhaulMbps
        minimumRSSI = try container.decodeIfPresent(Int.self, forKey: .minimumRSSI) ?? base.minimumRSSI
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? base.launchAtLogin
        demoMode = try container.decodeIfPresent(Bool.self, forKey: .demoMode) ?? base.demoMode
    }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case hour
    case sixHours
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: return "1h"
        case .sixHours: return "6h"
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .hour: return 3_600
        case .sixHours: return 6 * 3_600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }
}

enum SettingsStore {
    private static let key = "meshbar.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum KeychainStore {
    static let service = "com.meshbar.app.router-password"

    static func account(username: String, host: String) -> String {
        "\(username)@\(host.lowercased())"
    }

    static func save(account: String, password: String) throws {
        try delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Last write time of the item. Reads attributes only, not the password.
    static func modificationDate(account: String) -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

struct KeychainError: Error, LocalizedError {
    var status: OSStatus
    var errorDescription: String? { "Keychain error \(status)." }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum MeshNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ alert: MeshAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// MACs and IPs of this Mac, used to mark which node it is associated to.
enum LocalNetworkIdentity {
    static func current() -> LocalIdentity {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return LocalIdentity(macAddresses: [], ipAddresses: [])
        }
        defer { freeifaddrs(first) }
        var macs: [String] = []
        var ips: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            cursor = interface.pointee.ifa_next
            if (interface.pointee.ifa_flags & numericCast(IFF_LOOPBACK)) != 0 { continue }
            guard let address = interface.pointee.ifa_addr else { continue }
            let family = address.pointee.sa_family
            if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(address.pointee.sa_len)
                if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    var ip = String(cString: host)
                    if let zone = ip.firstIndex(of: "%") {
                        ip = String(ip[..<zone])
                    }
                    if ip != "::1" && !ip.hasPrefix("fe80:") && !ip.hasPrefix("169.254.") {
                        ips.append(ip)
                    }
                }
            } else if family == UInt8(AF_LINK) {
                if let mac = macAddress(address) {
                    macs.append(mac)
                }
            }
        }
        return LocalIdentity(macAddresses: macs, ipAddresses: ips)
    }

    /// Read the hardware address out of the original `getifaddrs` buffer.
    /// Copying `sockaddr_dl` truncates long interface names.
    private static func macAddress(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        let raw = UnsafeRawPointer(address)
        let link = raw.assumingMemoryBound(to: sockaddr_dl.self).pointee
        let length = Int(link.sdl_alen)
        guard length == 6, let offset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else { return nil }
        let start = offset + Int(link.sdl_nlen)
        let bytes = (0..<6).map { raw.advanced(by: start + $0).assumingMemoryBound(to: UInt8.self).pointee }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        let text = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        return MACAddress.normalize(text)
    }
}

enum MeshFormat {
    static func uptime(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func mbps(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f Mbps", value) }
        return String(format: "%.1f Mbps", value)
    }

    static func rssi(_ value: Int) -> String { "\(value) dBm" }

    static func relative(_ date: Date) -> String {
        RefreshClock.ago(date)
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

enum MeshPalette {
    static func color(_ health: MeshHealth) -> Color {
        Color(nsColor: nsColor(health))
    }

    static func nsColor(_ health: MeshHealth) -> NSColor {
        switch health {
        case .healthy: return .systemGreen
        case .degraded: return .systemOrange
        case .offline: return .systemRed
        case .partial: return .systemYellow
        case .unknown: return .secondaryLabelColor
        }
    }
}

enum MeshLinks {
    static func label(for node: MeshNode) -> String {
        guard node.isOnline else { return "Offline" }
        guard let link = node.backhaul else { return node.isPrimary ? "Router" : "No backhaul reading" }
        var parts: [String] = [link.medium.label]
        if let speed = link.speedMbps { parts.append(MeshFormat.mbps(speed)) } else if link.isAwaitingSpeed { parts.append("Measuring…") }
        if link.medium != .wired, let rssi = link.rssiDbm {
            parts.append(MeshFormat.rssi(rssi))
        }
        if let band = link.band { parts.append(band) }
        return parts.joined(separator: " · ")
    }
}
