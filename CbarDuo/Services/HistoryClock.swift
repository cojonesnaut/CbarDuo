import Combine
import Foundation

/// One clock for the popover's history graphs (network traffic, system
/// power, memory). While the popover is open it ticks every second so the
/// graphs move live; while it is closed it ticks every 6 s, so the graphs
/// keep their history at a fraction of the wake-ups. Each tick reports the
/// seconds since the previous one, and every graph fills its fixed-width
/// time slots from that (see `HistorySlots`).
@MainActor
final class HistoryClock {
    static let shared = HistoryClock()
    static let liveInterval: TimeInterval = 1
    static let backgroundInterval: TimeInterval = 6

    private var handlers: [(TimeInterval) -> Void] = []
    private var timer: Timer?
    private var lastTick: TimeInterval?
    private var isLive = false
    private var visibilityObserver: AnyCancellable?

    private init() {}

    /// `handler` receives the seconds elapsed since the previous tick (0 on the first).
    func subscribe(_ handler: @escaping (TimeInterval) -> Void) {
        handlers.append(handler)
    }

    /// Follows the popover: live while it is shown, background otherwise.
    func start() {
        guard visibilityObserver == nil else { return }
        schedule(live: PopoverPresentationState.shared.isShown)
        visibilityObserver = PopoverPresentationState.shared.$isShown
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] shown in self?.schedule(live: shown) }
    }

    private func schedule(live: Bool) {
        isLive = live
        timer?.invalidate()
        // Catch up on opening so the graphs are current the moment they show.
        tick()
        let interval = live ? Self.liveInterval : Self.backgroundInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Generous tolerance in the background lets macOS batch the wake-up.
        timer.tolerance = live ? 0.1 : 1.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastTick.map { now - $0 } ?? 0
        lastTick = now
        for handler in handlers {
            handler(elapsed)
        }
    }
}

/// Turns irregular tick gaps into a whole number of fixed-width graph slots,
/// carrying the remainder so slots never drift from real time.
struct HistorySlots {
    let slotLength: TimeInterval
    let capacity: Int
    private var pending: TimeInterval = 0

    init(slotLength: TimeInterval, capacity: Int) {
        self.slotLength = slotLength
        self.capacity = capacity
    }

    /// Slots to append for `elapsed` seconds. A gap longer than the whole
    /// graph (sleep) fills it once and drops the excess.
    mutating func advance(by elapsed: TimeInterval) -> Int {
        pending += max(elapsed, 0)
        // A quarter-slot of slack absorbs timer jitter.
        let slots = Int((pending + slotLength * 0.25) / slotLength)
        pending = max(pending - Double(slots) * slotLength, 0)
        if slots > capacity {
            pending = 0
            return capacity
        }
        return slots
    }
}
