import Foundation

/// What kind of device a client is, for icons and the friendly-name fallback.
public enum DeviceKind: String, Equatable, CaseIterable {
    case phone, tablet, laptop, desktop, watch, tv, speaker, printer, console, camera, iot, computer, unknown

    /// SF Symbol name for this kind.
    public var symbolName: String {
        switch self {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .laptop: return "laptopcomputer"
        case .desktop: return "desktopcomputer"
        case .watch: return "applewatch"
        case .tv: return "appletv"
        case .speaker: return "hifispeaker"
        case .printer: return "printer"
        case .console: return "gamecontroller"
        case .camera: return "web.camera"
        case .iot: return "lightbulb"
        case .computer: return "display"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    public var label: String {
        switch self {
        case .phone: return "Phone"
        case .tablet: return "Tablet"
        case .laptop: return "Laptop"
        case .desktop: return "Desktop"
        case .watch: return "Watch"
        case .tv: return "TV"
        case .speaker: return "Speaker"
        case .printer: return "Printer"
        case .console: return "Console"
        case .camera: return "Camera"
        case .iot: return "Smart device"
        case .computer: return "Computer"
        case .unknown: return "Device"
        }
    }

    /// Guesses the kind from the router's `model.deviceType`, model number,
    /// operating system and the cleaned name, in that order of trust.
    public static func classify(deviceType: String?, modelNumber: String?, operatingSystem: String?, name: String?) -> DeviceKind {
        let type = (deviceType ?? "").lowercased()
        switch type {
        case "phone", "mobile", "smartphone": return .phone
        case "tablet": return .tablet
        case "laptop", "notebook": return .laptop
        case "desktop", "pc": return .desktop
        case "computer": return .computer
        case "watch", "wearable": return .watch
        case "tv", "television", "mediaplayer", "media player", "streamingdevice": return .tv
        case "speaker", "audio": return .speaker
        case "printer": return .printer
        case "gameconsole", "game console", "console": return .console
        case "camera", "ipcamera": return .camera
        case "iot", "smarthome", "smart home", "thermostat", "lightbulb": return .iot
        default: break
        }
        let text = [modelNumber, operatingSystem, name].compactMap { $0?.lowercased() }.joined(separator: " ")
        let rules: [(DeviceKind, [String])] = [
            (.watch, ["watch"]),
            (.phone, ["iphone", "pixel", "galaxy s", "android phone", "phone"]),
            (.tablet, ["ipad", "tablet", "galaxy tab", "kindle"]),
            (.laptop, ["macbook", "laptop", "notebook", "thinkpad", "chromebook"]),
            (.desktop, ["imac", "mac mini", "mac-mini", "macmini", "mac studio", "mac pro", "desktop"]),
            (.tv, ["apple tv", "appletv", "roku", "chromecast", "firetv", "fire tv", "bravia", "tv"]),
            (.speaker, ["homepod", "sonos", "echo", "speaker", "nest audio", "nest mini"]),
            (.printer, ["printer", "laserjet", "officejet", "epson", "brother"]),
            (.console, ["playstation", "xbox", "nintendo", "switch"]),
            (.camera, ["camera", "ring", "arlo", "wyze"]),
            (.iot, ["hue", "nest", "thermostat", "plug", "bulb", "esp_", "esp32", "tasmota", "shelly"]),
            (.computer, ["macos", "mac os", "windows", "linux"]),
            (.phone, ["ios", "android"]),
        ]
        for (kind, needles) in rules where needles.contains(where: { text.contains($0) }) {
            return kind
        }
        return .unknown
    }
}

/// Turns what the router knows about a client into a name a person would use.
///
/// Order: the name the user set on the router (`userDeviceName`), then the
/// router's `friendlyName`, then `hostName`, both cleaned of mDNS/DNS-SD
/// suffixes. Opaque values (UUIDs, long hex runs) are skipped. Then the model
/// number (e.g. "iPhone"), the manufacturer, and finally the device kind,
/// each with the last two MAC bytes so similar devices stay apart.
public enum ClientNaming {
    public static func displayName(
        userDeviceName: String? = nil,
        friendlyName: String? = nil,
        hostName: String? = nil,
        modelNumber: String? = nil,
        manufacturer: String? = nil,
        kind: DeviceKind = .unknown,
        macAddresses: [String] = []
    ) -> String {
        if let custom = clean(userDeviceName), !isOpaque(custom) {
            return custom
        }
        for candidate in [friendlyName, hostName] {
            if let name = cleanHost(candidate), !isOpaque(name) {
                return name
            }
        }
        let suffix = macSuffix(macAddresses)
        if let model = clean(modelNumber), !isOpaque(model) {
            return suffix.map { "\(model) (\($0))" } ?? model
        }
        if let maker = clean(manufacturer).map(shortManufacturer) {
            let base = kind == .unknown ? "\(maker) device" : "\(maker) \(kind.label.lowercased())"
            return suffix.map { "\(base) (\($0))" } ?? base
        }
        return suffix.map { "\(kind.label) (\($0))" } ?? kind.label
    }

    /// Strips Bonjour service suffixes (`._device-info._tcp.local`), `.local`,
    /// `.lan`/`.home` DNS suffixes and decodes DNS-SD `\032`-style escapes.
    public static func cleanHost(_ raw: String?) -> String? {
        guard var value = clean(raw) else { return nil }
        value = decodeEscapes(value)
        if let range = value.range(of: "._") {
            value = String(value[..<range.lowerBound])
        }
        for suffix in [".local.", ".local", ".lan", ".home", ".localdomain", ".home.arpa"] where value.lowercased().hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        return clean(value)
    }

    /// True for names a router invents: UUIDs, bare MACs and long hex strings.
    public static func isOpaque(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if UUID(uuidString: trimmed) != nil { return true }
        if trimmed.count <= 17, MACAddress.normalize(trimmed) != nil,
           trimmed.allSatisfy({ $0.isHexDigit || ":-.".contains($0) }) {
            return true
        }
        let compact = trimmed.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        if compact.count >= 16, compact.allSatisfy(\.isHexDigit) { return true }
        return false
    }

    /// Last two bytes of the first MAC, e.g. "AB:CD".
    public static func macSuffix(_ macs: [String]) -> String? {
        guard let mac = macs.compactMap(MACAddress.normalize).first else { return nil }
        return mac.split(separator: ":").suffix(2).joined(separator: ":")
    }

    static func shortManufacturer(_ value: String) -> String {
        var name = value
        for suffix in [", Inc.", " Inc.", " Inc", " Corporation", " Corp.", " Co., Ltd.", " Ltd.", " LLC", " GmbH"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    private static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func decodeEscapes(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var result = ""
        var iterator = Array(value)
        var index = 0
        while index < iterator.count {
            let char = iterator[index]
            if char == "\\", index + 3 < iterator.count,
               let code = Int(String(iterator[(index + 1)...(index + 3)])),
               let scalar = UnicodeScalar(code) {
                result.append(Character(scalar))
                index += 4
            } else if char == "\\", index + 1 < iterator.count {
                result.append(iterator[index + 1])
                index += 2
            } else {
                result.append(char)
                index += 1
            }
        }
        iterator.removeAll()
        return result
    }
}

/// Human labels for the band strings JNAP uses: `2.4GHz`, `5GHz`, `5GL`,
/// `5GH`, `6GHz`, and radio IDs such as `RADIO_5GHz_2`.
public enum BandFormat {
    public static func label(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var value = raw.uppercased()
        if value.hasPrefix("RADIO_") { value = String(value.dropFirst(6)) }
        var index: String?
        if let underscore = value.lastIndex(of: "_") {
            let tail = String(value[value.index(after: underscore)...])
            if Int(tail) != nil {
                index = tail
                value = String(value[..<underscore])
            }
        }
        let base: String
        switch value {
        case "2.4GHZ", "2.4G", "2G", "24G", "2.4": base = "2.4 GHz"
        case "5GHZ", "5G", "5": base = "5 GHz"
        case "5GL", "5GHZ_LOW", "5GLOW": base = "5 GHz Low"
        case "5GH", "5GHZ_HIGH", "5GHIGH": base = "5 GHz High"
        case "6GHZ", "6G", "6": base = "6 GHz"
        case "60GHZ": base = "60 GHz"
        default: base = raw
        }
        return index.map { "\(base) (\($0))" } ?? base
    }

    /// Compact form for edge labels, e.g. "5GL", "5G", "6G".
    public static func short(_ raw: String?) -> String? {
        guard let label = label(raw) else { return nil }
        switch label {
        case "2.4 GHz": return "2.4G"
        case "5 GHz": return "5G"
        case "5 GHz Low": return "5GL"
        case "5 GHz High": return "5GH"
        case "6 GHz": return "6G"
        default: return label
        }
    }
}
