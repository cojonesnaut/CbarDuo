import AppKit
import Combine

/// The desktop-widget look chosen in System Settings > Appearance >
/// Icon & widget style.
enum WidgetStyle: Equatable {
    /// "Default": an opaque card that follows the system appearance.
    case standard
    /// "Dark": an opaque dark card.
    case dark
    /// "Light" variant of the opaque card.
    case light
    /// "Clear": see-through, slightly darkened (dark) or veiled white (light).
    case clear(isDark: Bool)
    /// "Tinted": see-through with the chosen tint color.
    case tinted(isDark: Bool, tint: NSColor)

    /// Parses the global `AppleIconAppearanceTheme` default, for example
    /// `ClearDark`, `TintedLight` or `RegularDark`. A missing value is the
    /// Default style. Unknown values fall back to Default.
    static func parse(theme: String?, tint: NSColor, systemIsDark: Bool) -> WidgetStyle {
        guard let theme else { return .standard }
        let isDark: Bool
        if theme.hasSuffix("Dark") {
            isDark = true
        } else if theme.hasSuffix("Light") {
            isDark = false
        } else {
            isDark = systemIsDark
        }
        if theme.hasPrefix("Clear") { return .clear(isDark: isDark) }
        if theme.hasPrefix("Tinted") { return .tinted(isDark: isDark, tint: tint) }
        if theme.hasPrefix("Regular") { return isDark ? .dark : .light }
        return .standard
    }
}

/// Follows Icon & widget style and the Liquid Glass slider in System
/// Settings, so the desktop widget can look like the system's own widgets.
///
/// macOS keeps the style in the global defaults `AppleIconAppearanceTheme`
/// and `AppleIconAppearanceTintColor` / `AppleIconAppearanceCustomTintColor`.
/// These are not public API, so this only reads them; if Apple renames them,
/// the widget falls back to the Default style.
@MainActor
final class WidgetStyleObserver: ObservableObject {
    @Published private(set) var style: WidgetStyle
    /// The Liquid Glass slider in System Settings > Appearance, 0 (Clear)
    /// through 1 (Tinted), from the global default `NSGlassTintAmount`.
    /// The see-through styles blur the wallpaper more toward Tinted.
    @Published private(set) var glassTint: Double

    /// Used when the slider has never been moved and the key is missing.
    static let defaultGlassTint = 0.5

    private var observations: [NSKeyValueObservation] = []
    private var appearanceObserver: NSObjectProtocol?

    init() {
        style = Self.currentStyle
        glassTint = Self.currentGlassTint
        // Key-value observing a defaults key also reports writes made by
        // other processes (System Settings), through cfprefsd.
        let defaults = UserDefaults.standard
        observations = [
            defaults.observe(\.AppleIconAppearanceTheme, options: []) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            },
            defaults.observe(\.AppleIconAppearanceTintColor, options: []) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            },
            defaults.observe(\.AppleIconAppearanceCustomTintColor, options: []) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            },
            defaults.observe(\.NSGlassTintAmount, options: []) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        ]
        // The Default style and styles without a Light/Dark suffix follow
        // the system appearance.
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
    }

    private func refresh() {
        let style = Self.currentStyle
        if style != self.style { self.style = style }
        let glassTint = Self.currentGlassTint
        if glassTint != self.glassTint { self.glassTint = glassTint }
    }

    private static var currentGlassTint: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "NSGlassTintAmount") != nil else { return defaultGlassTint }
        // double(forKey:) also accepts the value stored as text.
        return min(max(defaults.double(forKey: "NSGlassTintAmount"), 0), 1)
    }

    private static var currentStyle: WidgetStyle {
        let defaults = UserDefaults.standard
        let systemIsDark = defaults.string(forKey: "AppleInterfaceStyle") == "Dark"
        return WidgetStyle.parse(
            theme: defaults.string(forKey: "AppleIconAppearanceTheme"),
            tint: tintColor(defaults),
            systemIsDark: systemIsDark
        )
    }

    /// The Tinted style's color: the custom color as "r g b a" when one is
    /// picked, otherwise the system accent color.
    private static func tintColor(_ defaults: UserDefaults) -> NSColor {
        if defaults.string(forKey: "AppleIconAppearanceTintColor") == "Other",
           let raw = defaults.string(forKey: "AppleIconAppearanceCustomTintColor") {
            let parts = raw.split(separator: " ").compactMap { Double($0) }
            if parts.count >= 3 {
                return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: 1)
            }
        }
        return .controlAccentColor
    }
}

private extension UserDefaults {
    // Exposed only so they can be key-value observed; the names must match
    // the defaults keys exactly.
    @objc dynamic var AppleIconAppearanceTheme: String? { string(forKey: "AppleIconAppearanceTheme") }
    @objc dynamic var AppleIconAppearanceTintColor: String? { string(forKey: "AppleIconAppearanceTintColor") }
    @objc dynamic var AppleIconAppearanceCustomTintColor: String? {
        string(forKey: "AppleIconAppearanceCustomTintColor")
    }
    @objc dynamic var NSGlassTintAmount: Double { double(forKey: "NSGlassTintAmount") }
}
