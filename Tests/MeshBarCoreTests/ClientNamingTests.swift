import XCTest
@testable import MeshBarCore

final class ClientNamingTests: XCTestCase {
    let mac = ["02:00:00:00:AB:CD"]

    func testUserDeviceNameWins() {
        let name = ClientNaming.displayName(
            userDeviceName: "Kitchen iPad",
            friendlyName: "Something Else.local",
            macAddresses: mac
        )
        XCTAssertEqual(name, "Kitchen iPad")
    }

    func testStripsBonjourSuffix() {
        XCTAssertEqual(
            ClientNaming.displayName(friendlyName: "Demo’s MacBook Pro._device-info._tcp.local"),
            "Demo’s MacBook Pro"
        )
        XCTAssertEqual(ClientNaming.cleanHost("Demo MacBook (2)._device-info._tcp.local"), "Demo MacBook (2)")
        XCTAssertEqual(ClientNaming.cleanHost("living-room-tv.local"), "living-room-tv")
        XCTAssertEqual(ClientNaming.cleanHost("printer.lan"), "printer")
        XCTAssertEqual(ClientNaming.cleanHost("Demo\\032Speaker._airplay._tcp.local"), "Demo Speaker")
    }

    func testUUIDFallsBackToModelAndMACSuffix() {
        let name = ClientNaming.displayName(
            friendlyName: "6F9619FF-8B86-D011-B42D-00C04FC964FF",
            modelNumber: "iPhone",
            manufacturer: "Apple Inc.",
            kind: .phone,
            macAddresses: mac
        )
        XCTAssertEqual(name, "iPhone (AB:CD)")
    }

    func testHostNameUsedWhenFriendlyNameOpaque() {
        let name = ClientNaming.displayName(
            friendlyName: "6F9619FF-8B86-D011-B42D-00C04FC964FF",
            hostName: "demo-laptop",
            macAddresses: mac
        )
        XCTAssertEqual(name, "demo-laptop")
    }

    func testManufacturerThenKindFallback() {
        XCTAssertEqual(
            ClientNaming.displayName(manufacturer: "Example Corp.", kind: .tv, macAddresses: mac),
            "Example tv (AB:CD)"
        )
        XCTAssertEqual(ClientNaming.displayName(friendlyName: "02:00:00:00:AB:CD", macAddresses: mac), "Device (AB:CD)")
        XCTAssertEqual(ClientNaming.displayName(), "Device")
    }

    func testOpaqueDetection() {
        XCTAssertTrue(ClientNaming.isOpaque("6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        XCTAssertTrue(ClientNaming.isOpaque("0123456789abcdef0123"))
        XCTAssertTrue(ClientNaming.isOpaque("02:00:00:00:AB:CD"))
        XCTAssertFalse(ClientNaming.isOpaque("Living Room TV"))
        XCTAssertFalse(ClientNaming.isOpaque("cafe"))
    }

    func testDeviceKindClassification() {
        XCTAssertEqual(DeviceKind.classify(deviceType: "Phone", modelNumber: nil, operatingSystem: nil, name: nil), .phone)
        XCTAssertEqual(DeviceKind.classify(deviceType: "", modelNumber: nil, operatingSystem: nil, name: "Demo’s MacBook Pro"), .laptop)
        XCTAssertEqual(DeviceKind.classify(deviceType: nil, modelNumber: nil, operatingSystem: nil, name: "Office Mac mini"), .desktop)
        XCTAssertEqual(DeviceKind.classify(deviceType: nil, modelNumber: "iPad", operatingSystem: "iPadOS", name: nil), .tablet)
        XCTAssertEqual(DeviceKind.classify(deviceType: nil, modelNumber: nil, operatingSystem: "iOS", name: "Unknown"), .phone)
        XCTAssertEqual(DeviceKind.classify(deviceType: nil, modelNumber: nil, operatingSystem: nil, name: "Garden"), .unknown)
    }

    func testParserBuildsFriendlyClientNames() throws {
        let devices = """
        {"devices": [
          {"deviceID": "c-1", "friendlyName": "Demo’s MacBook Pro._device-info._tcp.local",
           "model": {"deviceType": ""},
           "knownInterfaces": [{"macAddress": "02:00:00:00:00:01", "interfaceType": "Wireless"}],
           "connections": [{"macAddress": "02:00:00:00:00:01", "ipAddress": "192.168.1.240"}],
           "properties": []},
          {"deviceID": "c-2", "friendlyName": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
           "model": {"deviceType": "Phone", "manufacturer": "Apple Inc.", "modelNumber": "iPhone"},
           "unit": {"operatingSystem": "iOS"},
           "knownInterfaces": [{"macAddress": "02:00:00:00:12:34", "interfaceType": "Wireless"}],
           "connections": [], "properties": []}
        ]}
        """
        var pieces = ParsedActions()
        pieces.devices = Data(devices.utf8)
        let snapshot = MeshSnapshotParser.parse(pieces)
        let laptop = try XCTUnwrap(snapshot.clients.first { $0.id == "c-1" })
        XCTAssertEqual(laptop.name, "Demo’s MacBook Pro")
        XCTAssertEqual(laptop.kind, .laptop)
        XCTAssertTrue(laptop.isOnline)
        let phone = try XCTUnwrap(snapshot.clients.first { $0.id == "c-2" })
        XCTAssertEqual(phone.name, "iPhone (12:34)")
        XCTAssertEqual(phone.kind, .phone)
        XCTAssertFalse(phone.isOnline)
    }
}

final class RadioFormatTests: XCTestCase {
    func testBandLabels() {
        XCTAssertEqual(BandFormat.label("5GL"), "5 GHz Low")
        XCTAssertEqual(BandFormat.label("5GH"), "5 GHz High")
        XCTAssertEqual(BandFormat.label("2.4GHz"), "2.4 GHz")
        XCTAssertEqual(BandFormat.label("RADIO_5GHz"), "5 GHz")
        XCTAssertEqual(BandFormat.label("RADIO_5GHz_2"), "5 GHz (2)")
        XCTAssertEqual(BandFormat.label("6GHz"), "6 GHz")
        XCTAssertEqual(BandFormat.short("5GH"), "5GH")
        XCTAssertEqual(BandFormat.short("5GHz"), "5G")
        XCTAssertNil(BandFormat.label(""))
    }

    func testRadioBandPrefersBandField() {
        XCTAssertEqual(RadioInfo.band(radioID: "RADIO_5GHz_2", bandField: "5GHz"), "5GHz")
        XCTAssertEqual(RadioInfo.band(radioID: "RADIO_5GHz_2", bandField: nil), "5GHz_2")
        XCTAssertEqual(RadioInfo.band(radioID: "RADIO_2.4GHz", bandField: nil), "2.4GHz")
    }

    func testRadioChipText() {
        let auto = RadioInfo(id: "RADIO_2.4GHz", band: "2.4GHz", isEnabled: true, ssid: "ExampleMesh",
                             channel: 0, channelWidth: "Auto", security: "WPA2-Personal")
        XCTAssertEqual(auto.bandLabel, "2.4 GHz")
        XCTAssertEqual(auto.chipDetail, "Auto ch · WPA2")
        let fixed = RadioInfo(id: "RADIO_5GHz", band: "5GHz", isEnabled: true, ssid: "ExampleMesh",
                              channel: 36, channelWidth: "80MHz", security: "WPA3-Personal")
        XCTAssertEqual(fixed.chipDetail, "ch 36 · 80 MHz · WPA3")
        XCTAssertFalse(fixed.chipDetail.contains("ExampleMesh"))
    }

    func testParsedRadioUsesBandField() throws {
        let json = """
        {"radios": [{"radioID": "RADIO_5GHz_2", "band": "5GHz", "physicalRadioID": "ath10",
          "settings": {"isEnabled": true, "ssid": "ExampleMesh", "channel": 0, "channelWidth": "Auto", "security": "WPA3-Personal"}}]}
        """
        var pieces = ParsedActions()
        pieces.radios = Data(json.utf8)
        let snapshot = MeshSnapshotParser.parse(pieces)
        XCTAssertEqual(snapshot.radios.first?.band, "5GHz")
        XCTAssertEqual(snapshot.radios.first?.bandLabel, "5 GHz")
        XCTAssertEqual(snapshot.radios.first?.ssid, "ExampleMesh")
    }
}
