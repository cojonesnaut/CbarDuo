import XCTest
@testable import CbarDuo

final class HistorySlotsTests: XCTestCase {
    func testLiveOneSecondTicksFillOneSecondSlots() {
        var slots = HistorySlots(slotLength: 1, capacity: 60)
        XCTAssertEqual((0..<10).map { _ in slots.advance(by: 1.02) }.reduce(0, +), 10)
    }

    func testLiveTicksFillTwoSecondSlotsEveryOtherTick() {
        var slots = HistorySlots(slotLength: 2, capacity: 90)
        XCTAssertEqual((0..<8).map { _ in slots.advance(by: 1) }, [0, 1, 0, 1, 0, 1, 0, 1])
    }

    func testBackgroundTicksKeepRealTimeDespiteJitter() {
        var network = HistorySlots(slotLength: 1, capacity: 60)
        var memory = HistorySlots(slotLength: 2, capacity: 90)
        let gaps = [6.4, 5.7, 7.2, 6.0, 5.9, 6.8]   // 38 s in all
        XCTAssertEqual(gaps.map { network.advance(by: $0) }.reduce(0, +), 38)
        XCTAssertEqual(gaps.map { memory.advance(by: $0) }.reduce(0, +), 19)
    }

    func testGapLongerThanTheGraphFillsItOnce() {
        var slots = HistorySlots(slotLength: 2, capacity: 90)
        XCTAssertEqual(slots.advance(by: 3600), 90)
        XCTAssertEqual(slots.advance(by: 2), 1, "no backlog carried after a sleep")
    }

    func testBackgroundClockFiresTwelveTimesLessThanSeparateTimers() {
        let before = 60.0 / 1 + 60.0 / 2 + 60.0 / 2      // network, power, memory timers
        let after = 60.0 / HistoryClock.backgroundInterval
        XCTAssertEqual(before / after, 12, accuracy: 0.001)
    }
}

final class HistoryClockModeTests: XCTestCase {
    @MainActor
    func testTicksEverySecondWhileThePopoverIsShownAndSlowsWhenHidden() {
        var ticks: [TimeInterval] = []
        HistoryClock.shared.start()
        HistoryClock.shared.subscribe { _ in ticks.append(ProcessInfo.processInfo.systemUptime) }

        PopoverPresentationState.shared.show()
        RunLoop.main.run(until: Date().addingTimeInterval(3.4))
        let liveTicks = ticks.count
        PopoverPresentationState.shared.hide()
        ticks.removeAll()
        RunLoop.main.run(until: Date().addingTimeInterval(3.4))

        XCTAssertGreaterThanOrEqual(liveTicks, 3, "about one tick per second while shown")
        // Hiding ticks once to switch modes, then waits about 6 s.
        XCTAssertLessThanOrEqual(ticks.count, 1, "background ticks are seconds apart")
    }
}
