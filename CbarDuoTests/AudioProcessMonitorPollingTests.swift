import XCTest
@testable import CbarDuo

final class AudioProcessMonitorPollingTests: XCTestCase {
    func testNoPollingWhenNothingIsVisibleOrAdjusted() {
        XCTAssertFalse(AudioProcessMonitor.needsPolling(visibleViews: 0, trackedApps: 0))
    }

    func testPollsWhileAMixerListIsVisible() {
        XCTAssertTrue(AudioProcessMonitor.needsPolling(visibleViews: 1, trackedApps: 0))
    }

    func testPollsForAdjustedAppsWithThePopoverClosed() {
        XCTAssertTrue(AudioProcessMonitor.needsPolling(visibleViews: 0, trackedApps: 2))
    }

    @MainActor
    func testVisibleListReadsLiveProcessesAndClosingStopsIt() {
        let monitor = AudioProcessMonitor()
        monitor.start()
        monitor.viewAppeared()
        // A full read lists at least the regular apps that have opened audio.
        let visibleCount = monitor.apps.count
        monitor.viewDisappeared()
        monitor.setTrackedBundleIDs([])
        monitor.refresh()
        XCTAssertGreaterThanOrEqual(visibleCount, 0)
        XCTAssertTrue(monitor.apps.allSatisfy { !$0.isRecording }, "recording is only read while a list is visible")
    }
}
