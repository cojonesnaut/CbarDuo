import XCTest
@testable import CbarDuo

final class PopoverRowsAndMemoryTests: XCTestCase {
    func testHiddenTabsAreLeftOutAndNeverAllHidden() {
        XCTAssertEqual(PopoverTab.visible(hiddenRaw: ""), PopoverTab.allCases)
        XCTAssertEqual(PopoverTab.visible(hiddenRaw: "mic,bluetooth"), [.network, .volume, .battery, .system])
        let all = PopoverTab.allCases.map(\.rawValue).joined(separator: ",")
        XCTAssertEqual(PopoverTab.visible(hiddenRaw: all), [.network])
        XCTAssertEqual(PopoverTab.visible(hiddenRaw: "unknown"), PopoverTab.allCases)
    }

    func testMemoryUsedIsAppPlusWiredPlusCompressed() {
        let gib: UInt64 = 1_073_741_824
        let memory = MemoryBreakdown(totalBytes: 16 * gib, appBytes: 7 * gib, wiredBytes: 2 * gib, compressedBytes: 3 * gib, cachedBytes: 4 * gib)
        XCTAssertEqual(memory.usedBytes, 12 * gib)
        XCTAssertEqual(memory.usedFraction ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(memory.fraction(memory.wiredBytes), 0.125, accuracy: 0.0001)
    }

    func testSMCParameterBlockMatchesTheControllerLayout() {
        XCTAssertEqual(MemoryLayout<SMCTemperatureReader.Parameters>.size, 80)
        XCTAssertEqual(SMCTemperatureReader.fourCC("#KEY"), 0x234B_4559)
        XCTAssertEqual(SMCTemperatureReader.string(0x5470_3261), "Tp2a")
    }

    func testUptimeFormatting() {
        XCTAssertTrue(SystemCounters.formatUptime(40 * 3600 + 600).contains("1"))
        XCTAssertTrue(SystemCounters.formatUptime(40 * 3600 + 600).contains("16"))
        XCTAssertTrue(SystemCounters.formatUptime(12 * 60).contains("12"))
    }

    func testWholeGigabytesDropDecimals() {
        let value = SystemFormat.bytes(16 * 1_073_741_824)
        XCTAssertTrue(value.hasPrefix("16") && !value.contains("16,0") && !value.contains("16.0"), value)
    }

    func testSmallAmountsUseMegabytes() {
        let value = SystemFormat.bytes(499 * 1_048_576)
        XCTAssertTrue(value.contains("499") && value.contains("MB"), value)
    }

    func testGigabytesUseTwoDecimals() {
        let value = SystemFormat.bytes(UInt64(11.68 * 1_073_741_824))
        XCTAssertTrue(value.contains("11") && value.contains("68") && value.contains("GB"), value)
    }

    func testLiveBreakdownIsConsistent() throws {
        let memory = try XCTUnwrap(SystemUsageMonitor.readMemoryBreakdown())
        XCTAssertLessThanOrEqual(memory.usedBytes, memory.totalBytes)
        print("LIVE MEMORY used=\(SystemFormat.bytes(memory.usedBytes)) of \(SystemFormat.bytes(memory.totalBytes)) app=\(SystemFormat.bytes(memory.appBytes)) wired=\(SystemFormat.bytes(memory.wiredBytes)) compressed=\(SystemFormat.bytes(memory.compressedBytes)) cached=\(SystemFormat.bytes(memory.cachedBytes))")
    }
}
