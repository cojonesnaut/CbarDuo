import AppKit
import SwiftUI

// Popover look (inside a system NSPopover, which supplies the Liquid Glass,
// arrow and shadow): small uppercase section titles, rounded cards of rows, and a footer of
// two equal buttons. Colors derive from .primary so light and dark both work.

enum PopoverStyle {
    static let width: CGFloat = 330
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 14
    static let cardCornerRadius: CGFloat = 14
    static let cardFill = Color.primary.opacity(0.05)
    static let cardBorder = Color.primary.opacity(0.09)
    static let divider = Color.primary.opacity(0.08)
}

/// Type scale for the popover, matching the Network and Battery rows.
enum PopoverFont {
    /// Row and card titles ("Network", "Output", the current device).
    static let title = Font.system(size: 12.5, weight: .semibold)
    /// List rows (devices, Nearby Networks).
    static let body = Font.system(size: 12)
    /// Details, values and notes under or beside a title.
    static let detail = Font.system(size: 10.5)
    /// Icons in list rows.
    static let listIcon = Font.system(size: 12, weight: .regular)
    /// Disclosure chevrons and checkmarks.
    static let accessory = Font.system(size: 9, weight: .semibold)
}

/// Rounded card fill and border shared by cards, the tab strip and footer buttons.
struct PopoverCardBackground: View {
    var radius: CGFloat = PopoverStyle.cardCornerRadius
    var fill: Color = PopoverStyle.cardFill

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(PopoverStyle.cardBorder)
            )
    }
}

/// Small uppercase title above a card, e.g. "NETWORK".
struct PopoverSectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased(with: AppLanguage.current.formatLocale))
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Section title followed by a rounded card holding the rows.
struct PopoverSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 8) {
            PopoverSectionLabel(title: title)
            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(PopoverCardBackground())
        }
    }
}

/// Hairline between rows inside a card.
struct PopoverDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopoverStyle.divider)
            .frame(height: 1)
            .padding(.horizontal, 10)
    }
}

/// Small capsule with a colored dot, e.g. "● Ethernet", under the header.
struct PopoverStatusPill: View {
    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }
}

/// One of the two equal-width footer buttons (Settings, Quit).
struct PopoverFooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(PopoverCardBackground(radius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Category tabs

/// The categories the popover switches between with its icon bar.
enum PopoverTab: String, CaseIterable, Identifiable {
    case network
    case volume
    case mic
    case battery
    case bluetooth
    case system

    var id: String { rawValue }

    /// Tabs left after hiding the ones in `hiddenRaw` (comma-separated
    /// raw values, Settings → Popover → Rows). Never empty.
    static func visible(hiddenRaw: String) -> [PopoverTab] {
        let hidden = Set(hiddenRaw.split(separator: ",").map(String.init))
        let tabs = allCases.filter { !hidden.contains($0.rawValue) }
        return tabs.isEmpty ? [.network] : tabs
    }

    var title: String {
        switch self {
        case .network: localized("Network")
        case .volume: localized("Volume")
        case .mic: localized("Microphone")
        case .battery: localized("Battery")
        case .bluetooth: localized("Bluetooth")
        case .system: localized("System")
        }
    }

    /// SF Symbol for the tab; Bluetooth has none, so it is drawn by `BluetoothGlyph`.
    var symbol: String? {
        switch self {
        case .network: "network"
        case .volume: "speaker.wave.2"
        case .mic: "mic"
        case .battery: "battery.75"
        case .bluetooth: nil
        case .system: "cpu"
        }
    }
}

/// The Bluetooth rune, drawn because SF Symbols has no Bluetooth logo.
struct BluetoothGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        var path = Path()
        path.move(to: pt(0.18, 0.28))
        path.addLine(to: pt(0.80, 0.73))
        path.addLine(to: pt(0.50, 0.96))
        path.addLine(to: pt(0.50, 0.04))
        path.addLine(to: pt(0.80, 0.27))
        path.addLine(to: pt(0.18, 0.72))
        return path
    }
}

/// Icon for a tab: its SF Symbol, or the drawn Bluetooth rune.
struct PopoverTabIcon: View {
    let tab: PopoverTab
    var size: CGFloat = 15

    var body: some View {
        if let symbol = tab.symbol {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
        } else {
            BluetoothGlyph()
                .stroke(style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.62, height: size * 1.05)
        }
    }
}

/// Row of category icons in a rounded strip; the selected one sits in an
/// accent-tinted rounded square with an accent border.
struct PopoverTabBar: View {
    @Binding var selection: PopoverTab
    var tabs: [PopoverTab] = PopoverTab.allCases

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                PopoverTabButton(tab: tab, isSelected: tab == selection) {
                    selection = tab
                }
            }
        }
        .padding(4)
        .background(PopoverCardBackground())
        // No animation here: switching tabs also resizes the popover, and an
        // animation scoped to the selection would animate the icons' re-layout
        // during that resize, making them bounce.
    }
}

private struct PopoverTabButton: View {
    let tab: PopoverTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PopoverTabIcon(tab: tab, size: 14)
                .fontWeight(.medium)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? SettingsStyle.accent.opacity(0.35) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? SettingsStyle.accent : Color.clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension View {
    /// No square focus rings around the rounded custom controls.
    func focusRingsDisabled() -> some View {
        focusEffectDisabled()
    }
}
