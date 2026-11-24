import SwiftUI
import XCTest
@testable import CbarDuo

final class NetworkAndSystemTabTests: XCTestCase {
    func testRateUsesKilobytesUntilAMegabyte() {
        XCTAssertTrue(NetworkRateFormatter.rate(0).hasPrefix("0 "), NetworkRateFormatter.rate(0))
        XCTAssertTrue(NetworkRateFormatter.rate(640_000).contains("640"))
        XCTAssertTrue(NetworkRateFormatter.rate(640_000).contains("KB/s"))
        let mega = NetworkRateFormatter.rate(2_400_000)
        XCTAssertTrue(mega.contains("2") && mega.contains("4") && mega.contains("MB/s"), mega)
    }

    func testMegabytesKeepOneDecimalLikeVorssaint() {
        let value = SystemFormat.bytes(UInt64(702.5 * 1_048_576))
        XCTAssertTrue(value.contains("702") && value.contains("5 MB"), value)
        XCTAssertFalse(SystemFormat.bytes(499 * 1_048_576).contains(","))
    }

    func testTrafficGraphPutsNewestSampleAtRightEdge() {
        let points = NetworkTrafficGraph.points([0, 1000, 2000], peak: 2000, size: CGSize(width: 100, height: 50), slots: 5)
        XCTAssertEqual(points.last?.x ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(points.first?.x ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(points.last?.y ?? 0, 1, accuracy: 0.001)
    }

    func testIPv4LookupForLoopback() {
        XCTAssertEqual(NetworkTrafficMonitor.ipv4Address(for: "lo0"), "127.0.0.1")
    }

    @MainActor
    func testRenderNetworkAndSystemTabs() throws {
        let traffic = NetworkTrafficMonitor.shared
        let pattern: [Double] = [0, 0, 120_000, 18_000, 0, 0, 70_000, 4_000, 0, 0, 0, 22_000, 0, 0, 0, 30_000, 5_000, 0]
        for index in 0..<NetworkTrafficMonitor.historyLength {
            let value = pattern[index % pattern.count]
            traffic.append(.init(download: value * 0.25, upload: value))
        }
        // Live readings for the System tab (temperatures, usage, memory).
        traffic.setInterface("en0")
        SystemTabMonitor.shared.viewAppeared()
        SystemTabMonitor.shared.wantsProcesses = true
        RunLoop.main.run(until: Date().addingTimeInterval(3.5))
        defer {
            SystemTabMonitor.shared.wantsProcesses = false
            SystemTabMonitor.shared.viewDisappeared()
        }
        for tab in [PopoverTab.network, .system] {
            let store = SystemStatusStore(startServices: false)
            store.applyDebugBatteryLevel(.full)
            store.applyDebugNetworkState(.strong)
            let view = StatusPopoverView(statusStore: store, initialTab: tab, onClose: {})
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let hostingView = NSHostingView(rootView: view)
            hostingView.appearance = NSAppearance(named: .darkAqua)
            hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
            hostingView.layoutSubtreeIfNeeded()
            let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
            hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
            let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("CbarDuo-Tab-\(tab.rawValue).png")
            try png.write(to: url, options: .atomic)
            print("RENDERED \(url.path)")
        }
    }
}

final class GPUProcessSamplerTests: XCTestCase {
    func testCreatorStringParsesPid() {
        XCTAssertEqual(GPUProcessSampler.pid(fromCreator: "pid 437, WindowServer"), 437)
        XCTAssertNil(GPUProcessSampler.pid(fromCreator: "WindowServer"))
    }

    func testLiveGPUAppsAfterTwoSamples() {
        var sampler = GPUProcessSampler()
        XCTAssertNil(sampler.sample(), "first call only primes")
        Thread.sleep(forTimeInterval: 1.5)
        let apps = sampler.sample() ?? []
        print("LIVE GPU APPS \(apps.prefix(8).map { "\($0.name)=\(String(format: "%.1f", $0.percent))" })")
        XCTAssertFalse(GPUProcessSampler.gpuTimePerPid().isEmpty, "GPU clients should publish AppUsage")
        XCTAssertTrue(apps.allSatisfy { $0.percent >= 0 && $0.percent <= 100 })
    }
}
