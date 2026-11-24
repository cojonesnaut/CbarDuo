import Darwin
import Foundation

/// Samples memory and startup-disk usage for the indicator bar, only while
/// the bar's slot needs them (Memory every 2 s, Disk every 30 s).
@MainActor
final class SystemUsageMonitor: ObservableObject {
    static let shared = SystemUsageMonitor()

    /// Fraction of physical memory in use (app memory + wired + compressed), 0…1.
    @Published private(set) var memoryUsed: Double?
    /// Fraction of the startup disk in use, 0…1.
    @Published private(set) var diskUsed: Double?

    private var timer: Timer?
    private var activeSlot: IndicatorBarSlot?
    private var defaultsObserver: NSObjectProtocol?

    private init() {}

    /// Starts following the bar slot preference.
    func start() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.apply(IndicatorBarSlot.current) }
        }
        apply(IndicatorBarSlot.current)
    }

    private func apply(_ slot: IndicatorBarSlot) {
        guard slot != activeSlot else { return }
        activeSlot = slot
        timer?.invalidate()
        timer = nil

        let interval: TimeInterval
        switch slot {
        case .memory: interval = 2
        case .disk: interval = 30
        case .volume, .network: return
        }
        sample(slot)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let slot = self.activeSlot else { return }
                self.sample(slot)
            }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample(_ slot: IndicatorBarSlot) {
        switch slot {
        case .memory: memoryUsed = Self.readMemoryUsed()
        case .disk: diskUsed = Self.readDiskUsed()
        case .volume, .network: break
        }
    }

    /// App memory (internal − purgeable) + wired + compressed, over physical
    /// memory: the same parts Activity Monitor adds up as "Memory Used".
    nonisolated static func readMemoryUsed() -> Double? {
        readMemoryBreakdown()?.usedFraction
    }

    /// Memory split the way Activity Monitor shows it.
    nonisolated static func readMemoryBreakdown() -> MemoryBreakdown? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let page = UInt64(pageSize)
        let internalPages = UInt64(statistics.internal_page_count)
        let purgeable = UInt64(statistics.purgeable_count)
        return MemoryBreakdown(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            appBytes: (internalPages > purgeable ? internalPages - purgeable : 0) * page,
            wiredBytes: UInt64(statistics.wire_count) * page,
            compressedBytes: UInt64(statistics.compressor_page_count) * page,
            cachedBytes: (UInt64(statistics.external_page_count) + purgeable) * page
        )
    }

    /// Used share of the startup disk, counting space macOS can free for
    /// important use as available (what Finder reports).
    nonisolated static func readDiskUsed() -> Double? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return min(max(1 - Double(available) / Double(total), 0), 1)
    }
}

/// Memory in Activity Monitor's categories.
struct MemoryBreakdown: Equatable, Sendable {
    var totalBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var cachedBytes: UInt64

    /// App + wired + compressed ("Memory Used").
    var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

    var usedFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    func fraction(_ bytes: UInt64) -> Double {
        totalBytes > 0 ? min(Double(bytes) / Double(totalBytes), 1) : 0
    }
}
