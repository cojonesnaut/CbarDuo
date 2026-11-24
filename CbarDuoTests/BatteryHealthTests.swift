import XCTest
@testable import CbarDuo

final class BatteryHealthTests: XCTestCase {
    func testMaximumCapacityUsesNominalOverDesignCapacityFromBatteryData() {
        // Values from a real MacBook Air (DuoBar App Store shows 90% / 228).
        let registry: [String: Any] = [
            "CycleCount": 228,
            "MaxCapacity": 100,
            "BatteryData": [
                "DesignCapacity": 4382,
                "NominalChargeCapacity": 3947,
                "AppleRawMaxCapacity": 3817
            ]
        ]
        XCTAssertEqual(BatteryHealth.from(registry: registry), BatteryHealth(cycleCount: 228, maximumCapacityPercent: 90))
    }

    func testFallsBackToRawMaxCapacityAndTopLevelKeys() {
        let registry: [String: Any] = ["CycleCount": 12, "DesignCapacity": 5000, "AppleRawMaxCapacity": 4900]
        XCTAssertEqual(BatteryHealth.from(registry: registry), BatteryHealth(cycleCount: 12, maximumCapacityPercent: 98))
    }

    func testCapsAtOneHundredAndHandlesMissingDesignCapacity() {
        XCTAssertEqual(
            BatteryHealth.from(registry: ["BatteryData": ["DesignCapacity": 4000, "NominalChargeCapacity": 4100]]).maximumCapacityPercent,
            100
        )
        let empty = BatteryHealth.from(registry: ["NominalChargeCapacity": 3000])
        XCTAssertNil(empty.maximumCapacityPercent)
        XCTAssertTrue(empty.isEmpty)
    }
}
