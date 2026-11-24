import AppKit
import SwiftUI

// Building blocks for the Settings window: a sidebar with colored icon tiles,
// rounded setting cards, and purple-accented controls.

enum SettingsStyle {
    static let accent = Color(red: 0.64, green: 0.29, blue: 0.75)
    static let detailBackground = Color.adaptive(light: NSColor(white: 0.955, alpha: 1), dark: NSColor(white: 0.118, alpha: 1))
    static let cardBackground = Color.adaptive(light: .white, dark: NSColor(white: 0.165, alpha: 1))
    static let cardBorder = Color.adaptive(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.05))
    static let controlTrack = Color.adaptive(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.08))
    static let cardCornerRadius: CGFloat = 12
    static let tileSize: CGFloat = 24
}

extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// A rounded, gradient-filled square holding a white SF Symbol, like System Settings.
struct SettingsIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = SettingsStyle.tileSize

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.88), color],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// Section title followed by a rounded card of rows.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: SettingsStyle.cardCornerRadius, style: .continuous)
                    .fill(SettingsStyle.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsStyle.cardCornerRadius, style: .continuous)
                    .strokeBorder(SettingsStyle.cardBorder)
            )

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Hairline between rows inside a card, inset past the icon tile.
struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.leading, SettingsStyle.tileSize + 12)
    }
}

/// One row in a card: icon tile, title and optional subtitle, trailing control.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

/// Row with a purple switch on the right.
struct SettingsToggleRow: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(symbol: symbol, color: color, title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SettingsSwitchStyle())
        }
    }
}

/// Switch drawn with a purple track when on, independent of the system accent color.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? SettingsStyle.accent : SettingsStyle.controlTrack)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(configuration.isOn ? Color.clear : SettingsStyle.cardBorder)
                    )
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: 36, height: 20)
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// Capsule segmented control with a purple selected segment.
struct SettingsSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? SettingsStyle.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsStyle.controlTrack)
        )
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// Sidebar entry: icon tile and title, filled purple when selected.
struct SettingsSidebarItem: View {
    let symbol: String
    let color: Color
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: symbol, color: color, size: 22)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? SettingsStyle.accent : (isHovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Translucent sidebar material that picks up the desktop behind the window.
struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// App-wide light/dark choice offered at the bottom of the sidebar.
enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: localized("System")
        case .light: localized("Light")
        case .dark: localized("Dark")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: PreferenceKeys.appearance) ?? "") ?? .system
    }

    @MainActor
    static func applyCurrent() {
        let target = current.nsAppearance
        if NSApp.appearance?.name != target?.name {
            NSApp.appearance = target
        }
    }
}

/// Row of bar styles or fill styles, each with a small live preview, the name,
/// and an accent underline on the selected one.
struct BarOptionPicker: View {
    struct Option: Identifiable {
        let id: String
        let title: String
        let style: IndicatorBarStyle
        let fill: IndicatorBarFill
    }

    @Binding var selection: String
    let options: [Option]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                let isSelected = option.id == selection
                Button {
                    selection = option.id
                } label: {
                    VStack(spacing: 5) {
                        BarPreviewGlyph(style: option.style, fill: option.fill)
                            .opacity(isSelected ? 1 : 0.5)
                        Text(option.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Capsule()
                            .fill(isSelected ? SettingsStyle.accent : Color.clear)
                            .frame(width: 36, height: 2)
                    }
                    .frame(width: 64)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// A small ring with its bar at about 60%, drawn by the real bar code.
struct BarPreviewGlyph: View {
    let style: IndicatorBarStyle
    let fill: IndicatorBarFill
    private let size: CGFloat = 38

    var body: some View {
        let metrics = DuoGlyphMetrics.standard
        ZStack {
            DuoArcShape(startDegrees: metrics.arcStartDegrees, endDegrees: metrics.arcEndDegrees, progress: 1)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: metrics.arcLineWidth, lineCap: .round))
                .frame(width: metrics.ringPathDiameter, height: metrics.ringPathDiameter)
                .offset(y: metrics.ringYOffset)
            DuoDotRow(
                value: IndicatorBarValue(level: 0.62),
                diameter: metrics.dotDiameter,
                ringDiameter: metrics.ringDiameter,
                rowCenterYOffset: metrics.ringYOffset,
                animationsEnabled: false,
                styleOverride: style,
                fillOverride: fill
            )
        }
        .frame(width: DuoGlyphMetrics.canvasSize, height: DuoGlyphMetrics.canvasSize)
        .scaleEffect(size / DuoGlyphMetrics.canvasSize)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
