import SwiftUI

/// Battery page shown inside the popover when the battery row is opened:
/// power source and charging state, Low Power Mode, battery health, and a
/// link to Battery settings.
struct BatteryDetailView: View {
    let battery: BatteryStatus
    let timeEstimate: BatteryTimeEstimate
    let onBack: () -> Void
    let onOpenBatterySettings: () -> Void

    @State private var health = BatteryHealth.read()

    var body: some View {
        VStack(spacing: PopoverStyle.spacing) {
            header

            VStack(spacing: 0) {
                infoRow(
                    title: localized("Power Source"),
                    value: battery.isPluggedIn ? localized("Power Adapter") : localized("Battery")
                )
                PopoverDivider()
                infoRow(title: summary.detail, value: summary.secondaryDetail ?? "")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(PopoverCardBackground())

            PopoverSection(title: localized("Energy Mode")) {
                Button(action: onOpenBatterySettings) {
                    HStack(spacing: 11) {
                        Image(systemName: battery.isLowPowerModeEnabled ? "battery.25percent" : "battery.100percent")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.primary.opacity(0.12), in: Circle())
                        Text(localized("Low Power Mode"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer(minLength: 8)
                        Text(battery.isLowPowerModeEnabled ? localized("On") : localized("Off"))
                            .font(PopoverFont.detail)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(localized("Open Battery Settings"))
            }

            if let health {
                PopoverSection(title: localized("Battery Health")) {
                    if let percent = health.maximumCapacityPercent {
                        infoRow(title: localized("Maximum Capacity"), value: localized("%d%%", percent))
                    }
                    if health.maximumCapacityPercent != nil, health.cycleCount != nil {
                        PopoverDivider()
                    }
                    if let cycles = health.cycleCount {
                        infoRow(title: localized("Cycle Count"), value: "\(cycles)")
                    }
                }
            }

            PopoverFooterButton(
                title: localized("Battery Settings…"),
                symbol: "gearshape",
                action: onOpenBatterySettings
            )
            .padding(.top, 2)
        }
        .onAppear { health = BatteryHealth.read() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(PopoverCardBackground(radius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(localized("Back"))
            .accessibilityLabel(localized("Back"))

            Text(localized("Battery"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let percentage = battery.percentage {
                Text(localized("%d%%", percentage))
                    .font(.headline)
                    .monospacedDigit()
            }
        }
        .padding(.top, 2)
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .accessibilityElement(children: .combine)
    }

    /// Same wording as the battery row ("Charging On Hold", "2:10 to full", …).
    private var summary: BatteryStatusRow {
        BatteryStatusRow(battery: battery, showPercentage: true, timeEstimate: timeEstimate)
    }
}
