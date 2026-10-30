import XCTest
@testable import MeshBarCore

final class SignalLevelTests: XCTestCase {
    func testRSSISteps() {
        XCTAssertEqual(SignalLevel.fraction(rssi: -45), 1)
        XCTAssertEqual(SignalLevel.fraction(rssi: -65), 0.66)
        XCTAssertEqual(SignalLevel.fraction(rssi: -75), 0.33)
        XCTAssertEqual(SignalLevel.fraction(rssi: -90), 0.1)
        XCTAssertEqual(SignalLevel.fraction(rssi: nil), 1)
    }
}
