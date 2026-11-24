import CoreGraphics
import Foundation

enum MenuBarIconSize {
    static let preferenceKey = "cbarDuo.menuBarIconScale"
    static let minimumScale = 0.80
    static let defaultScale = 1.00
    static let largeScale = 1.05
    static let extraLargeScale = 1.20
    static let maximumScale = extraLargeScale
    static let step = 0.05
    static let minimumStatusItemWidth: CGFloat = 22
    static let baseStatusItemWidth: CGFloat = 27

    static func resolve(_ rawValue: Double?) -> Double {
        guard let rawValue, rawValue.isFinite else { return defaultScale }

        let clamped = min(max(rawValue, minimumScale), maximumScale)
        let quantizedPercent = ((clamped * 100) / (step * 100)).rounded() * (step * 100)
        return min(max(quantizedPercent / 100, minimumScale), maximumScale)
    }

    static func storedScale(in defaults: UserDefaults = .standard) -> Double {
        let rawValue = (defaults.object(forKey: preferenceKey) as? NSNumber)?.doubleValue
        return resolve(rawValue)
    }

    static func statusItemWidth(for rawScale: Double?) -> CGFloat {
        max(minimumStatusItemWidth, baseStatusItemWidth * CGFloat(resolve(rawScale)))
    }
}

/// How heavy the indicator's ring is drawn (Settings → Indicator → Icon).
enum IconThickness: String, CaseIterable, Sendable {
    case thin
    case regular
    case bold

    /// Multiplier on the ring's stroke width; regular is the default look.
    var ringWidthMultiplier: CGFloat {
        switch self {
        case .thin: 0.75
        case .regular: 1.0
        case .bold: 1.3
        }
    }

    var title: String {
        switch self {
        case .thin: localized("Thin")
        case .regular: localized("Regular")
        case .bold: localized("Bold")
        }
    }

    static func resolve(_ rawValue: String?) -> IconThickness {
        rawValue.flatMap(IconThickness.init(rawValue:)) ?? .regular
    }
}
