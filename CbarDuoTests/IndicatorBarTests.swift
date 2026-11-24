import XCTest
@testable import CbarDuo

final class IndicatorBarTests: XCTestCase {
    func testVolumeSlotKeepsTheOriginalBarPath() {
        XCTAssertNil(IndicatorBarValue.make(slot: .volume, networkSpeed: nil, memoryUsed: 0.5, diskUsed: 0.5))
        let muted = IndicatorBarValue.volume(OutputVolumeStatus(level: 0.8, isMuted: true, isSettable: true))
        XCTAssertEqual(muted.level, 0)
        XCTAssertEqual(muted.steps, 0)
    }

    func testStepsFromLevelLightAtLeastOneForAnyActivity() {
        XCTAssertEqual(IndicatorBarValue(level: 0).steps, 0)
        XCTAssertEqual(IndicatorBarValue(level: 0.01).steps, 1)
        XCTAssertEqual(IndicatorBarValue(level: 0.5).steps, 2)
        XCTAssertEqual(IndicatorBarValue(level: 0.51).steps, 3)
        XCTAssertEqual(IndicatorBarValue(level: 1).steps, 4)
        XCTAssertNil(IndicatorBarValue(level: nil).steps)
    }

    func testNetworkLevelIsLogarithmic() {
        XCTAssertEqual(IndicatorBarValue.networkLevel(bytesPerSecond: 0), 0)
        XCTAssertEqual(IndicatorBarValue.networkLevel(bytesPerSecond: 1024), 0)
        XCTAssertEqual(IndicatorBarValue.networkLevel(bytesPerSecond: 50 * 1024 * 1024), 1, accuracy: 0.0001)
        XCTAssertEqual(IndicatorBarValue.networkLevel(bytesPerSecond: 500 * 1024 * 1024), 1)
        let oneMegabyte = IndicatorBarValue.networkLevel(bytesPerSecond: 1024 * 1024)
        XCTAssertGreaterThan(oneMegabyte, 0.5)
        XCTAssertLessThan(oneMegabyte, 0.75)
        let network = IndicatorBarValue.make(slot: .network, networkSpeed: NetworkSpeed(downloadBytesPerSecond: 512 * 1024, uploadBytesPerSecond: 512 * 1024), memoryUsed: nil, diskUsed: nil)
        XCTAssertEqual(network?.level ?? -1, oneMegabyte, accuracy: 0.0001)
    }

    func testSegmentProgressPerFillStyle() {
        let value = IndicatorBarValue(level: 0.62)
        // Step styles: 3 of 4 segments fully on.
        for fill in [IndicatorBarFill.classic, .snap] {
            XCTAssertEqual((0..<4).map { value.progress(ofSegment: $0, fill: fill) }, [1, 1, 1, 0])
            XCTAssertEqual(value.fraction(fill: fill), 0.75)
        }
        // Continuous styles: the third segment is partly filled.
        for fill in [IndicatorBarFill.fade, .grow] {
            XCTAssertEqual(value.progress(ofSegment: 1, fill: fill), 1)
            XCTAssertEqual(value.progress(ofSegment: 2, fill: fill) ?? -1, 0.48, accuracy: 0.0001)
            XCTAssertEqual(value.progress(ofSegment: 3, fill: fill), 0)
            XCTAssertEqual(value.fraction(fill: fill) ?? -1, 0.62, accuracy: 0.0001)
        }
        XCTAssertNil(IndicatorBarValue(level: nil).progress(ofSegment: 0, fill: .fade))
    }

    func testLiveMemoryAndDiskReadingsAreFractions() {
        let memory = SystemUsageMonitor.readMemoryUsed()
        let disk = SystemUsageMonitor.readDiskUsed()
        XCTAssertNotNil(memory)
        XCTAssertNotNil(disk)
        print("LIVE memoryUsed=\(memory ?? -1) diskUsed=\(disk ?? -1)")
        XCTAssertTrue((0...1).contains(memory ?? -1))
        XCTAssertTrue((0...1).contains(disk ?? -1))
    }
}
