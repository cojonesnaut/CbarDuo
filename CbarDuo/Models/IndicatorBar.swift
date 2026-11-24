import Foundation
import SwiftUI

/// What the bar under the ring shows (Settings → Indicator → Bar).
enum IndicatorBarSlot: String, CaseIterable, Sendable {
    case volume
    case network
    case memory
    case disk

    var title: String {
        switch self {
        case .volume: localized("Volume")
        case .network: localized("Network Activity")
        case .memory: localized("Memory")
        case .disk: localized("Disk")
        }
    }

    var symbol: String {
        switch self {
        case .volume: "speaker.wave.2"
        case .network: "arrow.up.arrow.down"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        }
    }

    static var current: IndicatorBarSlot {
        IndicatorBarSlot(rawValue: UserDefaults.standard.string(forKey: PreferenceKeys.barSlot) ?? "") ?? .volume
    }
}

/// How the bar is drawn.
enum IndicatorBarStyle: String, CaseIterable, Sendable {
    /// Four dots (the original look).
    case dotted
    /// One continuous arc.
    case solid
    /// Four short dashes along the arc.
    case segmented

    var title: String {
        switch self {
        case .dotted: localized("Dotted")
        case .solid: localized("Solid")
        case .segmented: localized("Segmented")
        }
    }
}

/// How the bar shows and animates its level.
enum IndicatorBarFill: String, CaseIterable, Sendable {
    /// Four steps that cross-fade (the original look).
    case classic
    /// Continuous level; the partly filled segment is shown at partial strength.
    case fade
    /// Continuous level; the partly filled segment grows in size or length.
    case grow
    /// Four steps, no animation.
    case snap

    var title: String {
        switch self {
        case .classic: localized("Classic")
        case .fade: localized("Fade")
        case .grow: localized("Grow")
        case .snap: localized("Snap")
        }
    }

    /// True when the bar follows the continuous level rather than 4 steps.
    var isContinuous: Bool { self == .fade || self == .grow }

    var animation: Animation? {
        switch self {
        case .classic: AnimationConstants.content
        case .fade: .easeInOut(duration: 0.3)
        case .grow: .spring(response: 0.35, dampingFraction: 0.85)
        case .snap: nil
        }
    }
}

/// The value the bar shows: a continuous level and its 4-step form.
struct IndicatorBarValue: Equatable, Sendable {
    /// 0…1, nil when unknown.
    var level: Double?
    /// 0…4 filled steps, nil when unknown.
    var steps: Int?

    static let segmentCount = 4

    init(level: Double?, steps: Int?) {
        self.level = level.map { min(max($0, 0), 1) }
        self.steps = steps
    }

    /// Steps derived from the level: any non-zero level lights at least one.
    init(level: Double?) {
        let clamped = level.map { min(max($0, 0), 1) }
        self.init(
            level: clamped,
            steps: clamped.map { $0 <= 0 ? 0 : min(Self.segmentCount, Int(($0 * Double(Self.segmentCount)).rounded(.up))) }
        )
    }

    /// Volume keeps its original 4-step mapping (muted = 0).
    static func volume(_ volume: OutputVolumeStatus) -> IndicatorBarValue {
        let level = volume.level.map { volume.isMuted ? 0 : $0 }
        return IndicatorBarValue(level: level, steps: volume.activeDotCount)
    }

    /// Download + upload rate on a log scale: ≤1 KB/s is empty, ≥50 MB/s is full.
    static func networkLevel(bytesPerSecond: Double) -> Double {
        let kilobytes = bytesPerSecond / 1024
        guard kilobytes > 1 else { return 0 }
        return min(log10(kilobytes) / log10(50 * 1024), 1)
    }

    /// The bar's value for a slot. Nil for volume: the glyph then uses its own
    /// status, exactly as before the bar became configurable.
    static func make(
        slot: IndicatorBarSlot,
        networkSpeed: NetworkSpeed?,
        memoryUsed: Double?,
        diskUsed: Double?
    ) -> IndicatorBarValue? {
        switch slot {
        case .volume:
            return nil
        case .network:
            let rate = networkSpeed.map { $0.downloadBytesPerSecond + $0.uploadBytesPerSecond }
            return IndicatorBarValue(level: rate.map(networkLevel(bytesPerSecond:)))
        case .memory:
            return IndicatorBarValue(level: memoryUsed)
        case .disk:
            return IndicatorBarValue(level: diskUsed)
        }
    }

    /// How filled segment `index` (0…3) is, 0…1, for a fill style. Nil when unknown.
    func progress(ofSegment index: Int, fill: IndicatorBarFill) -> Double? {
        if fill.isContinuous {
            guard let level else { return nil }
            return min(max(level * Double(Self.segmentCount) - Double(index), 0), 1)
        }
        guard let steps else { return nil }
        return index < steps ? 1 : 0
    }

    /// Fill fraction of the whole bar (for the solid style), 0…1. Nil when unknown.
    func fraction(fill: IndicatorBarFill) -> Double? {
        if fill.isContinuous { return level }
        return steps.map { Double($0) / Double(Self.segmentCount) }
    }
}
