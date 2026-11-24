import Darwin
import Foundation

/// Keeps the last minute of download/upload rates for the Network tab's
/// graph (one slot per second), plus the active interface's IPv4 address.
/// It samples on `HistoryClock`: every second while the popover is open,
/// every few seconds in the background, filling the slots in between with
/// the average rate. Only the Network tab observes it, so its updates never
/// redraw the menu bar item.
@MainActor
final class NetworkTrafficMonitor: ObservableObject {
    static let shared = NetworkTrafficMonitor()
    static let historyLength = 60

    struct Sample: Equatable {
        var download: Double
        var upload: Double
    }

    /// Oldest first, at most `historyLength` samples.
    @Published private(set) var history: [Sample] = []
    @Published private(set) var ipAddress: String?

    var current: Sample? { history.last }

    private var isStarted = false
    private var calculator = NetworkSpeedCalculator()
    private var interfaceName: String?
    private var slots = HistorySlots(slotLength: 1, capacity: historyLength)

    func start() {
        guard !isStarted else { return }
        isStarted = true
        HistoryClock.shared.subscribe { [weak self] elapsed in self?.sample(elapsed: elapsed) }
    }

    /// The interface whose traffic is measured; nil while offline.
    func setInterface(_ name: String?) {
        guard name != interfaceName else { return }
        interfaceName = name
        calculator.reset()
        ipAddress = name.flatMap(Self.ipv4Address(for:))
    }

    private func sample(elapsed: TimeInterval) {
        let counters = interfaceName.flatMap(NetworkSpeedService.readCounters(for:))
        // The rate is the average since the previous tick, however long ago.
        let speed = calculator.update(
            interface: interfaceName,
            counters: counters,
            at: ProcessInfo.processInfo.systemUptime
        )
        // A gap (offline, first reading) records as zero so the graph keeps time.
        let sample = Sample(download: speed?.downloadBytesPerSecond ?? 0, upload: speed?.uploadBytesPerSecond ?? 0)
        for _ in 0..<slots.advance(by: elapsed) { append(sample) }
        // Addresses change on DHCP renewals without an interface change.
        let address = interfaceName.flatMap(Self.ipv4Address(for:))
        if address != ipAddress { ipAddress = address }
    }

    func append(_ sample: Sample) {
        history.append(sample)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }

    nonisolated static func ipv4Address(for name: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let item = entry.pointee
            if let address = item.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               String(cString: item.ifa_name) == name {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            cursor = item.ifa_next
        }
        return nil
    }
}

enum NetworkRateFormatter {
    /// DuoBar-style rate: "0 KB/s", "640 KB/s", "2.4 MB/s", "1.25 GB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let locale = AppLanguage.current.formatLocale
        let kilobytes = max(0, bytesPerSecond) / 1000
        if kilobytes < 999.5 {
            return localized("%@ KB/s", kilobytes.formatted(.number.precision(.fractionLength(0)).locale(locale)))
        }
        let megabytes = kilobytes / 1000
        if megabytes < 999.5 {
            return localized("%@ MB/s", megabytes.formatted(.number.precision(.fractionLength(1)).locale(locale)))
        }
        let gigabytes = megabytes / 1000
        return localized("%@ GB/s", gigabytes.formatted(.number.precision(.fractionLength(2)).locale(locale)))
    }
}
