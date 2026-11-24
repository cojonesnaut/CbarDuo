import AppKit
import SwiftUI

/// Power rows under the battery in the Battery tab, styled like Vorssaint's
/// Power card: apps using significant energy, battery temperature, system
/// power with its history graph, and adapter input with its rating.
struct PowerDetailsView: View {
    @ObservedObject private var monitor = PowerMonitor.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var appsExpanded = false

    var body: some View {
        let reading = monitor.reading
        VStack(alignment: .leading, spacing: 10) {
            energyApps
            if let temperature = reading.batteryTemperature {
                Divider()
                row(icon: "thermometer.medium", color: .secondary,
                    label: localized("Battery temperature"),
                    value: localized("%d °C", Int(temperature.rounded())))
            }
            if let watts = reading.systemWatts {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    row(icon: "bolt.fill", color: SystemPalette.orange(colorScheme),
                        label: localized("System"), value: PowerMonitor.formatWatts(watts))
                    if monitor.systemHistory.count > 1 {
                        let ceiling = PowerMonitor.graphCeiling(monitor.systemHistory.max() ?? 0)
                        PowerHistoryGraph(
                            values: monitor.systemHistory,
                            ceiling: ceiling,
                            label: PowerMonitor.formatWatts(ceiling),
                            color: SystemPalette.orange(colorScheme)
                        )
                        .frame(height: 30)
                        .padding(.top, 4)
                    }
                }
            }
            if reading.externalConnected, let adapter = reading.adapterWatts {
                Divider()
                row(icon: "powerplug.fill", color: SettingsStyle.accent,
                    label: localized("Adapter"), value: PowerMonitor.formatWatts(adapter),
                    caption: reading.adapterMaxWatts.map {
                        localized("%@ max", PowerMonitor.formatWatts($0))
                    } ?? localized("Plugged in"))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .onAppear { monitor.viewAppeared() }
        .onDisappear {
            appsExpanded = false
            monitor.viewDisappeared()
        }
        .onChange(of: appsExpanded) { _, expanded in monitor.wantsEnergyApps = expanded }
    }

    // MARK: Apps using significant energy

    private var energyApps: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                appsExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(appsExpanded ? 90 : 0))
                    Text(localized("Apps using significant energy"))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)

            if appsExpanded {
                if monitor.energyApps.isEmpty {
                    Text(monitor.energyAppsMeasured
                         ? localized("No apps using significant energy")
                         : localized("Calculating…"))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 16)
                } else {
                    ForEach(monitor.energyApps) { app in
                        HStack(spacing: 7) {
                            Image(nsImage: ProcessIcon.icon(for: app.pid))
                                .resizable()
                                .frame(width: 14, height: 14)
                            Text(app.name)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(localized("%@%%", app.cpu.formatted(
                                .number.precision(.fractionLength(1)).locale(AppLanguage.current.formatLocale)
                            )))
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                        }
                        .padding(.leading, 16)
                        .help(app.name)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    // MARK: Rows

    private func row(icon: String, color: Color, label: String, value: String, caption: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.74))
                if let caption {
                    Text(caption)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// System power over recent samples, scaled to a rounded ceiling that is
/// drawn as a dashed line and labelled over the oldest samples.
struct PowerHistoryGraph: View {
    let values: [Double]
    let ceiling: Double
    let label: String
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let baseline = max(0.5, size.height - 0.5)
            let points = MemoryHistoryGraph.points(values.map { $0 / max(ceiling, 0.0001) }, in: size)
            ZStack(alignment: .topLeading) {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: baseline))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: baseline))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.16), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                Path { path in
                    path.move(to: CGPoint(x: 0, y: baseline))
                    path.addLine(to: CGPoint(x: size.width, y: baseline))
                }
                .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                if points.count > 1 {
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0.5))
                    path.addLine(to: CGPoint(x: size.width, y: 0.5))
                }
                .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                Text(label)
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                    .alignmentGuide(.top) { $0[VerticalAlignment.center] }
            }
        }
        .accessibilityHidden(true)
    }
}
