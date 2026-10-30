import Foundation

/// Parses the parts of the router's `sysinfo.cgi` page that describe the air:
/// the site survey, the router's own radio settings, airtime counters and
/// radar events. The page also holds secrets (Wi-Fi keys, serials), so callers
/// must hand it straight to this parser and drop the text afterwards. Nothing
/// here keeps or logs the raw page.
public enum SysinfoAirwavesParser {
    public static func parse(
        _ text: String,
        capturedAt: Date,
        heardAtNodeID: String? = nil,
        ownMACs: [String] = [],
        ownSSIDs: Set<String> = []
    ) -> AirwavesScan {
        let lines = text.components(separatedBy: .newlines)
        let keys = OwnMeshMatcher.keys(ownMACs)
        var networks: [HeardNetwork] = []
        var scannedBands = Set<WiFiBand>()
        var radios: [WiFiBand: NodeRadio] = [:]
        var stats: [WiFiBand: RadioAirStats] = [:]
        var radar: Int?

        // Survey state
        var surveyBand: WiFiBand?
        var cell: CellBuilder?
        func flushCell() {
            if let built = cell?.build(fallbackBand: surveyBand, keys: keys, ownSSIDs: ownSSIDs, index: networks.count) {
                networks.append(built)
            }
            cell = nil
        }

        // Radio settings state
        var settingsFrequency: Double?
        var settingsWidthCode: Int?
        var settingsMode: String?
        var inSettings = false
        func flushSettings() {
            defer { settingsFrequency = nil; settingsWidthCode = nil; settingsMode = nil; inSettings = false }
            guard inSettings, let mhz = settingsFrequency, let band = WiFiBand(frequencyMHz: mhz) else { return }
            var width = settingsMode.map { SpectrumMath.width(phyMode: $0) }
            if width?.width == 20, let code = settingsWidthCode, settingsMode?.uppercased().contains("20") != true {
                width = (widthCode(code), nil)
            }
            radios[band] = NodeRadio(
                nodeID: heardAtNodeID ?? "router",
                band: band,
                channel: band.channel(frequencyMHz: mhz),
                widthMHz: width?.width ?? settingsWidthCode.map(widthCode),
                secondaryBelow: width?.secondaryBelow
            )
        }

        var statsBand: WiFiBand?
        var inRadar = false

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Site Survey on ") {
                flushCell()
                let label = line.dropFirst("Site Survey on ".count).replacingOccurrences(of: ":", with: "")
                surveyBand = WiFiBand(label: label)
                if let surveyBand { scannedBands.insert(surveyBand) }
                continue
            }
            if line.hasPrefix("====") {
                flushCell()
                surveyBand = nil
                flushSettings()
                statsBand = nil
                inRadar = false
                continue
            }
            if surveyBand != nil {
                if line.hasSuffix("No scan results"), let band = surveyBand {
                    // Scanned, nothing heard.
                    scannedBands.insert(band)
                    continue
                }
                if let range = line.range(of: "Address:"), line.hasPrefix("Cell ") {
                    flushCell()
                    cell = CellBuilder(bssid: line[range.upperBound...].trimmingCharacters(in: .whitespaces))
                    continue
                }
                cell?.consume(line)
                continue
            }

            if line.hasPrefix("-------------") {
                flushSettings()
                if line.contains(" Settings ") { inSettings = true }
                if line.lowercased().contains("apstats") { statsBand = nil }
                inRadar = line.lowercased().contains("radar")
                continue
            }
            if inSettings {
                if line.hasPrefix("Frequency:"), let ghz = Double(line.dropFirst("Frequency:".count).replacingOccurrences(of: "GHz", with: "").trimmingCharacters(in: .whitespaces)) {
                    settingsFrequency = ghz * 1000
                } else if let value = value(after: "get_chwidth:", in: line) {
                    settingsWidthCode = Int(value)
                } else if let value = value(after: "get_mode:", in: line) {
                    settingsMode = value
                }
                continue
            }
            if line.hasPrefix("radio level information of ") {
                let label = line.dropFirst("radio level information of ".count).replacingOccurrences(of: ":", with: "")
                statsBand = WiFiBand(label: label)
                if let statsBand, stats[statsBand] == nil { stats[statsBand] = RadioAirStats(band: statsBand) }
                continue
            }
            if let band = statsBand {
                if line.hasPrefix("Self BSS chan util"), let n = intAfterEquals(line) {
                    stats[band]?.selfUtilization = n
                } else if line.hasPrefix("OBSS chan util"), let n = intAfterEquals(line) {
                    stats[band]?.otherUtilization = n
                } else if line.contains("Chan NF"), let n = intAfterEquals(line), n < 0 {
                    stats[band]?.noiseFloorDbm = n
                }
            }
            if inRadar, line.hasPrefix("Radar: detected"), let n = Int(line.split(separator: " ").dropFirst(2).first ?? "") {
                radar = (radar ?? 0) + n
            }
        }
        flushCell()
        flushSettings()

        return AirwavesScan(
            source: .routerScan,
            capturedAt: capturedAt,
            heardAtNodeID: heardAtNodeID,
            networks: networks,
            stats: stats.values.sorted { $0.band < $1.band },
            scannerRadios: radios,
            radarEvents: radar,
            scannedBands: scannedBands
        )
    }

    static func widthCode(_ code: Int) -> Int {
        switch code {
        case 1: return 40
        case 2: return 80
        case 3, 4: return 160
        case 5: return 320
        default: return 20
        }
    }

    private static func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    private static func intAfterEquals(_ line: String) -> Int? {
        guard let eq = line.lastIndex(of: "=") else { return nil }
        return Int(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
    }

    /// Decodes iwlist ESSID escapes (`\x41`). All-zero or empty names are hidden.
    static func decodeESSID(_ raw: String) -> String? {
        var bytes: [UInt8] = []
        var chars = Array(raw.utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == UInt8(ascii: "\\"), i + 3 < chars.count, chars[i + 1] == UInt8(ascii: "x"),
               let byte = UInt8(String(decoding: chars[(i + 2)...(i + 3)], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                i += 4
            } else {
                bytes.append(chars[i])
                i += 1
            }
        }
        chars = []
        if bytes.allSatisfy({ $0 == 0 }) { return nil }
        let name = String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private struct CellBuilder {
        var bssid: String
        var essid: String?
        var frequencyMHz: Double?
        var channel: Int?
        var rssi: Int?
        var noise: Int?
        var phyMode: String?

        mutating func consume(_ line: String) {
            if line.hasPrefix("ESSID:") {
                var value = String(line.dropFirst("ESSID:".count))
                if value.hasPrefix("\"") { value.removeFirst() }
                if value.hasSuffix("\"") { value.removeLast() }
                essid = SysinfoAirwavesParser.decodeESSID(value)
            } else if line.hasPrefix("Frequency:") {
                let body = line.dropFirst("Frequency:".count)
                if let ghz = Double(body.split(separator: " ").first ?? "") { frequencyMHz = ghz * 1000 }
                if let open = body.range(of: "(Channel "), let close = body[open.upperBound...].firstIndex(of: ")") {
                    channel = Int(body[open.upperBound..<close])
                }
            } else if line.contains("Signal level=") {
                rssi = Self.dbm(after: "Signal level=", in: line)
                noise = Self.dbm(after: "Noise level=", in: line)
            } else if let range = line.range(of: "phy_mode=") {
                phyMode = String(line[range.upperBound...])
            }
        }

        static func dbm(after marker: String, in line: String) -> Int? {
            guard let range = line.range(of: marker) else { return nil }
            let rest = line[range.upperBound...]
            let token = rest.prefix { $0 == "-" || $0.isNumber }
            return Int(token)
        }

        func build(fallbackBand: WiFiBand?, keys: Set<String>, ownSSIDs: Set<String>, index: Int) -> HeardNetwork? {
            guard let rssi else { return nil }
            guard let band = frequencyMHz.flatMap(WiFiBand.init(frequencyMHz:)) ?? fallbackBand else { return nil }
            guard let channel = channel ?? frequencyMHz.map(band.channel(frequencyMHz:)) else { return nil }
            var mode: (width: Int, secondaryBelow: Bool?) = phyMode.map(SpectrumMath.width(phyMode:)) ?? (20, nil)
            if band == .ghz24 { mode.width = min(mode.width, 40) }
            let normalized = MACAddress.normalize(bssid)
            return HeardNetwork(
                id: "\(band.rawValue)|\(normalized ?? "cell-\(index)")",
                ssid: essid,
                bssid: normalized,
                band: band,
                channel: channel,
                widthMHz: mode.width,
                secondaryBelow: mode.secondaryBelow,
                rssiDbm: rssi,
                noiseDbm: noise,
                isOwnMesh: OwnMeshMatcher.isOwn(bssid: normalized, ssid: essid, keys: keys, ownSSIDs: ownSSIDs)
            )
        }
    }
}

/// nodes/setup/GetSelectedChannels and wirelessap/GetDFSSettings.
public enum ChannelPlanParser {
    public static func parse(selectedChannels: Data, dfsSettings: Data? = nil, widths: [WiFiBand: (Int, Bool?)] = [:]) -> ChannelPlan? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: selectedChannels),
              let list = root.objectValue?["selectedChannels"]?.arrayValue else { return nil }
        var radios: [NodeRadio] = []
        for entry in list {
            guard let object = entry.objectValue, let deviceID = object["deviceID"]?.stringValue else { continue }
            for channel in object["channels"]?.arrayValue ?? [] {
                guard let c = channel.objectValue,
                      let number = c["channel"]?.intValue, number > 0,
                      let band = (c["band"]?.stringValue).flatMap(WiFiBand.init(label:)) ?? (c["radioID"]?.stringValue).flatMap(WiFiBand.init(label:))
                else { continue }
                let width = widths[band]
                radios.append(NodeRadio(nodeID: deviceID, band: band, channel: number, widthMHz: width?.0, secondaryBelow: width?.1))
            }
        }
        var plan = ChannelPlan(radios: radios)
        if let dfsSettings, let dfs = (try? JSONDecoder().decode(JSONValue.self, from: dfsSettings))?.objectValue {
            plan.isDFSEnabled = dfs["isDFSEnabled"]?.boolValue
            plan.isDFSSupported = dfs["isDFSSupported"]?.boolValue
        }
        return plan
    }
}
