import Foundation
import IOKit

/// Battery health figures from the AppleSmartBattery registry entry.
struct BatteryHealth: Equatable, Sendable {
    var cycleCount: Int?
    /// Current full-charge capacity relative to the design capacity, 0–100.
    var maximumCapacityPercent: Int?

    var isEmpty: Bool { cycleCount == nil && maximumCapacityPercent == nil }

    /// Builds the figures from AppleSmartBattery's registry properties.
    /// Maximum capacity is NominalChargeCapacity ÷ DesignCapacity (falling back
    /// to AppleRawMaxCapacity), read from `BatteryData` when present.
    static func from(registry: [String: Any]) -> BatteryHealth {
        let batteryData = registry["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? {
            (batteryData[key] as? NSNumber)?.intValue ?? (registry[key] as? NSNumber)?.intValue
        }
        let cycles = (registry["CycleCount"] as? NSNumber)?.intValue ?? int("CycleCount")
        let design = int("DesignCapacity")
        let full = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity")
        var percent: Int?
        if let design, design > 0, let full, full > 0 {
            percent = min(100, Int((Double(full) / Double(design) * 100).rounded()))
        }
        return BatteryHealth(
            cycleCount: cycles.flatMap { $0 >= 0 ? $0 : nil },
            maximumCapacityPercent: percent
        )
    }

    /// Reads the current figures; nil on Macs without an internal battery.
    static func read() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let registry = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        let health = from(registry: registry)
        return health.isEmpty ? nil : health
    }
}
