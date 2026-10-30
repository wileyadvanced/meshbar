import CoreLocation
import CoreWLAN
import Foundation
import MeshBarCore

/// Scans from this Mac's Wi-Fi card with CoreWLAN. Channels and signal levels
/// need no permission; network names and BSSIDs need Location access on
/// macOS 14+, which is only requested when the user presses the scan button.
enum MacWiFiScanner {
    struct Result: Sendable {
        var networks: [HeardNetwork]
        var bands: Set<WiFiBand>
        var namesHidden: Bool
    }

    enum ScanError: LocalizedError {
        case noInterface
        case failed

        var errorDescription: String? {
            switch self {
            case .noInterface: return "This Mac's Wi-Fi is off or missing."
            case .failed: return "This Mac's Wi-Fi scan failed. Try again."
            }
        }
    }

    @MainActor private static var locationManager: CLLocationManager?

    @MainActor
    static func scan(ownMACs: [String], ownSSIDs: Set<String>) async throws -> Result {
        let manager = locationManager ?? CLLocationManager()
        locationManager = manager
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        let keys = OwnMeshMatcher.keys(ownMACs)
        return try await Task.detached(priority: .userInitiated) {
            try scanBlocking(keys: keys, ownSSIDs: ownSSIDs)
        }.value
    }

    private static func scanBlocking(keys: Set<String>, ownSSIDs: Set<String>) throws -> Result {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { throw ScanError.noInterface }
        let found: Set<CWNetwork>
        do {
            found = try interface.scanForNetworks(withSSID: nil)
        } catch {
            throw ScanError.failed
        }
        var networks: [HeardNetwork] = []
        var bands: Set<WiFiBand> = [.ghz24, .ghz5]
        var sawIdentity = false
        for (index, network) in found.enumerated() {
            guard let wlan = network.wlanChannel else { continue }
            let band: WiFiBand
            switch wlan.channelBand {
            case .band2GHz: band = .ghz24
            case .band5GHz: band = .ghz5
            case .band6GHz: band = .ghz6
            default: continue
            }
            let width: Int
            switch wlan.channelWidth {
            case .width40MHz: width = 40
            case .width80MHz: width = 80
            case .width160MHz: width = 160
            default: width = 20
            }
            if network.ssid != nil || network.bssid != nil { sawIdentity = true }
            let bssid = network.bssid.flatMap(MACAddress.normalize)
            bands.insert(band)
            networks.append(HeardNetwork(
                id: "mac|\(band.rawValue)|\(bssid ?? "n\(index)")",
                ssid: network.ssid,
                bssid: bssid,
                band: band,
                channel: wlan.channelNumber,
                widthMHz: band == .ghz24 ? min(width, 40) : width,
                rssiDbm: network.rssiValue,
                noiseDbm: network.noiseMeasurement == 0 ? nil : network.noiseMeasurement,
                isOwnMesh: OwnMeshMatcher.isOwn(bssid: bssid, ssid: network.ssid, keys: keys, ownSSIDs: ownSSIDs)
            ))
        }
        return Result(networks: networks, bands: bands, namesHidden: !networks.isEmpty && !sawIdentity)
    }
}
