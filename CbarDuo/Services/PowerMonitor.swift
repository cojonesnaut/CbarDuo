import Foundation
import IOKit

/// Power readings for the Battery tab: total system draw, adapter input and
/// rating, battery temperature, and the apps using significant energy.
/// System draw is recorded in 2 s slots from launch (one SMC read per
/// `HistoryClock` tick) so its graph already has history when the tab opens;
/// the rest is read only while the tab is visible.
@MainActor
final class PowerMonitor: ObservableObject {
    static let shared = PowerMonitor()
    static let historyLength = 90

    struct Reading: Equatable {
        var systemWatts: Double?
        var adapterWatts: Double?
        var adapterMaxWatts: Double?
        var batteryTemperature: Double?
        var externalConnected = false
    }

    @Published private(set) var reading = Reading()
    /// System power in watts, oldest first.
    @Published private(set) var systemHistory: [Double] = []
    @Published private(set) var energyApps: [ProcessUsageSampler.Usage] = []
    @Published private(set) var energyAppsMeasured = false

    /// Set while the energy list is expanded.
    var wantsEnergyApps = false {
        didSet {
            guard wantsEnergyApps != oldValue else { return }
            energyApps = []
            energyAppsMeasured = false
            if wantsEnergyApps { tick(full: true, slots: 0) }
        }
    }

    private var isStarted = false
    private var visibleViews = 0
    private let core = PowerSamplerCore()
    private var slots = HistorySlots(slotLength: 2, capacity: historyLength)

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        HistoryClock.shared.subscribe { [weak self] elapsed in
            guard let self else { return }
            // The first tick records one point so the graph has a start.
            let count = elapsed == 0 ? 1 : slots.advance(by: elapsed)
            guard count > 0 else { return }
            tick(full: visibleViews > 0, slots: count)
        }
    }

    func viewAppeared() {
        visibleViews += 1
        if visibleViews == 1 { tick(full: true, slots: 0) }
    }

    func viewDisappeared() {
        visibleViews = max(visibleViews - 1, 0)
        if visibleViews == 0 { wantsEnergyApps = false }
    }

    /// `slots`: how many 2 s graph slots this reading fills (0 for an
    /// out-of-band refresh such as the tab opening).
    private func tick(full: Bool, slots: Int) {
        let includeApps = full && wantsEnergyApps
        core.sample(full: full, includeApps: includeApps) { [weak self] reading, apps in
            Task { @MainActor in
                guard let self else { return }
                if let watts = reading.systemWatts, slots > 0 {
                    self.systemHistory.append(contentsOf: repeatElement(watts, count: slots))
                    if self.systemHistory.count > Self.historyLength {
                        self.systemHistory.removeFirst(self.systemHistory.count - Self.historyLength)
                    }
                }
                if full {
                    self.reading = reading
                } else {
                    self.reading.systemWatts = reading.systemWatts
                }
                if includeApps, self.wantsEnergyApps, let apps {
                    self.energyApps = apps
                    self.energyAppsMeasured = true
                }
            }
        }
    }

    /// The top of the system power graph: the peak rounded up to 1, 2 or 5
    /// of a power of ten, so the label reads "20 W" and moves in steps.
    nonisolated static func graphCeiling(_ peak: Double) -> Double {
        var scale = 1.0
        while scale < 10_000 {
            for step in [1.0, 2, 5] where step * scale >= peak {
                return step * scale
            }
            scale *= 10
        }
        return peak
    }

    /// "5.7 W" below 10 W, "26 W" above, in the app's language.
    nonisolated static func formatWatts(_ watts: Double) -> String {
        let locale = AppLanguage.current.formatLocale
        let digits = abs(watts) < 10 ? 1 : 0
        return localized("%@ W", watts.formatted(.number.precision(.fractionLength(digits)).locale(locale)))
    }
}

/// Sampler state that lives on a background queue.
private final class PowerSamplerCore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.cojonesnaut.cbarduo.power-sampler", qos: .utility)
    private var processes = ProcessUsageSampler()
    private var processesPrimed = false

    /// Apps at or above this share of one core count as using significant energy.
    static let significantCPUPercent = 2.0
    static let appLimit = 15

    func sample(
        full: Bool,
        includeApps: Bool,
        completion: @escaping @Sendable (PowerMonitor.Reading, [ProcessUsageSampler.Usage]?) -> Void
    ) {
        queue.async { [self] in
            let smc = SMCTemperatureReader.shared
            var reading = PowerMonitor.Reading()
            reading.systemWatts = smc?.watts("PSTR")

            var apps: [ProcessUsageSampler.Usage]?
            if full {
                reading.adapterWatts = smc?.watts("PDTR")
                reading.batteryTemperature = smc?.batteryTemperature()
                if let battery = Self.batteryProperties() {
                    reading.externalConnected = (battery["ExternalConnected"] as? Bool) ?? false
                    if let adapter = battery["AdapterDetails"] as? [String: Any],
                       let rated = adapter["Watts"] as? Int, rated > 0 {
                        reading.adapterMaxWatts = Double(rated)
                    }
                    // Without a system power sensor, the battery's discharge is the draw.
                    if reading.systemWatts == nil, !reading.externalConnected,
                       let millivolts = battery["Voltage"] as? Int,
                       let milliamps = (battery["Amperage"] as? Int) ?? (battery["InstantAmperage"] as? Int),
                       milliamps < 0 {
                        reading.systemWatts = Double(millivolts) / 1000 * Double(-milliamps) / 1000
                    }
                }
                if includeApps {
                    let sampled = processes.sample()
                    // CPU shares need two samples; the first only primes the counters.
                    if processesPrimed {
                        apps = Array(sampled
                            .filter { $0.cpu >= Self.significantCPUPercent }
                            .sorted { $0.cpu > $1.cpu }
                            .prefix(Self.appLimit))
                    }
                    processesPrimed = true
                } else {
                    processesPrimed = false
                }
            }
            completion(reading, apps)
        }
    }

    private static func batteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return properties?.takeRetainedValue() as? [String: Any]
    }
}
