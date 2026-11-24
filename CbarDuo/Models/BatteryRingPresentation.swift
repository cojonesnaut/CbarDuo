import Foundation

enum BatteryBoltPlacement: Equatable, Sendable {
    case none
    case topGap
}

enum BatteryRingColorRole: Equatable, Sendable {
    case monochrome
    case charging
    case lowPowerMode
    case lowBattery
}

struct BatteryRingPresentation: Equatable, Sendable {
    let boltPlacement: BatteryBoltPlacement
    let colorRole: BatteryRingColorRole
    /// True while the battery shows 100% with the charger still connected but the
    /// system has not yet reported the authoritative "fully charged" state.
    var boltDimmed: Bool = false

    static func resolve(
        battery: BatteryStatus,
        colorCodingEnabled: Bool
    ) -> BatteryRingPresentation {
        guard battery.isAvailable else {
            return BatteryRingPresentation(boltPlacement: .none, colorRole: .monochrome)
        }

        // Connected to power: the ring is always green, whether the battery is
        // charging, paused by macOS, or full, and regardless of color coding.
        // IOPowerSources' authoritative full flag still hides the charging bolt.
        if battery.isPluggedIn {
            let boltPlacement: BatteryBoltPlacement = battery.isFullyCharged ? .none : .topGap
            return BatteryRingPresentation(
                boltPlacement: boltPlacement,
                colorRole: .charging,
                boltDimmed: boltPlacement == .topGap && (battery.percentage ?? 0) >= 100
            )
        }

        guard colorCodingEnabled, !battery.isFullyCharged else {
            return BatteryRingPresentation(boltPlacement: .none, colorRole: .monochrome)
        }

        let colorRole: BatteryRingColorRole
        if battery.isLowPowerModeEnabled {
            colorRole = .lowPowerMode
        } else if let percentage = battery.percentage, percentage < 20 {
            colorRole = .lowBattery
        } else {
            colorRole = .monochrome
        }
        return BatteryRingPresentation(boltPlacement: .none, colorRole: colorRole)
    }
}
