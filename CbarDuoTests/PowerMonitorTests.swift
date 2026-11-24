import SwiftUI
import XCTest
@testable import CbarDuo

final class PowerMonitorTests: XCTestCase {
    func testGraphCeilingRoundsUpToOneTwoOrFive() {
        XCTAssertEqual(PowerMonitor.graphCeiling(0.4), 1)
        XCTAssertEqual(PowerMonitor.graphCeiling(5.7), 10)
        XCTAssertEqual(PowerMonitor.graphCeiling(14), 20)
        XCTAssertEqual(PowerMonitor.graphCeiling(38), 50)
        XCTAssertEqual(PowerMonitor.graphCeiling(120), 200)
    }

    func testWattsKeepOneDecimalBelowTen() {
        let small = PowerMonitor.formatWatts(5.7)
        XCTAssertTrue(small.contains("5") && small.contains("7") && small.hasSuffix("W"), small)
        let large = PowerMonitor.formatWatts(26.4)
        XCTAssertTrue(large.hasPrefix("26") && !large.contains("4"), large)
    }

    func testLiveSensorsReadPlausibleValues() throws {
        let smc = try XCTUnwrap(SMCTemperatureReader.shared)
        let system = smc.watts("PSTR")
        let adapter = smc.watts("PDTR")
        let battery = smc.batteryTemperature()
        print("LIVE POWER system=\(system.map { "\($0)" } ?? "nil") adapter=\(adapter.map { "\($0)" } ?? "nil") batteryTemp=\(battery.map { "\($0)" } ?? "nil")")
        if let system { XCTAssertTrue(system > 0 && system < 1000) }
        if let battery { XCTAssertTrue(battery > 5 && battery < 80) }
        XCTAssertNil(smc.watts("ZZZZ"))
    }

    @MainActor
    func testRenderBatteryTabWithPower() throws {
        PowerMonitor.shared.start()
        PowerMonitor.shared.viewAppeared()
        PowerMonitor.shared.wantsEnergyApps = true
        RunLoop.main.run(until: Date().addingTimeInterval(4.5))
        defer { PowerMonitor.shared.viewDisappeared() }
        print("LIVE ENERGY APPS \(PowerMonitor.shared.energyApps.map { "\($0.name)=\($0.cpu)" })")

        let store = SystemStatusStore(startServices: false)
        store.applyDebugBatteryLevel(.full)
        store.applyDebugNetworkState(.strong)
        let view = StatusPopoverView(statusStore: store, initialTab: .battery, onClose: {})
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CbarDuo-Tab-battery.png")
        try png.write(to: url, options: .atomic)
        print("RENDERED \(url.path)")
    }
}
