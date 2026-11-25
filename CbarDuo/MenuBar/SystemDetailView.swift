import AppKit
import SwiftUI

/// The popover's System tab, styled like Vorssaint's System card: small
/// type, temperature tiles, colour-coded usage bars, memory with a history
/// graph, uptime and connected USB devices, all in one bordered card.
struct SystemDetailView: View {
    let onOpenActivityMonitor: () -> Void

    @ObservedObject private var monitor = SystemTabMonitor.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedCPU = false
    @State private var expandedGPU = false
    @State private var expandedMemory = false
    @State private var expandedDevices = false

    /// Vorssaint's type scale for this card.
    private enum Fonts {
        static let subsection = SwiftUI.Font.system(size: 10.5, weight: .semibold)
        static let row = SwiftUI.Font.system(size: 11)
        static let value = SwiftUI.Font.system(size: 11, weight: .medium)
        static let secondaryRow = SwiftUI.Font.system(size: 10.5)
        static let chevron = SwiftUI.Font.system(size: 8, weight: .semibold)
        static let smallIcon = SwiftUI.Font.system(size: 9)
    }

    private static let processLimit = 15

    var body: some View {
        let snapshot = monitor.snapshot
        VStack(spacing: 8) {
            PopoverSectionLabel(title: localized("System"))
            VStack(alignment: .leading, spacing: 10) {
                temperatures(snapshot)
                Divider()
                hardwareUsage(snapshot)
                Divider()
                memory(snapshot)
                Divider()
                uptime(snapshot)
                Divider()
                connectedDevices(snapshot)
            }
            .padding(10)
            .background(PopoverCardBackground(radius: 10))
        }
        .onAppear { monitor.viewAppeared() }
        .onDisappear {
            monitor.wantsProcesses = false
            monitor.wantsGPUProcesses = false
            monitor.viewDisappeared()
        }
        .onChange(of: expandedCPU || expandedMemory) { _, wants in monitor.wantsProcesses = wants }
        .onChange(of: expandedGPU) { _, wants in monitor.wantsGPUProcesses = wants }
    }

    // MARK: Temperatures

    private func temperatures(_ snapshot: SystemTabMonitor.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            subsectionLabel(localized("Temperatures"))
            HStack(spacing: 8) {
                temperatureTile(localized("CPU"), symbol: "cpu", value: snapshot.cpuTemperature)
                temperatureTile(localized("GPU"), symbol: "memorychip", value: snapshot.gpuTemperature)
            }
        }
    }

    private func temperatureTile(_ title: String, symbol: String, value: Double?) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(Fonts.smallIcon)
                Text(title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            Text(value.map { localized("%d °C", Int($0.rounded())) } ?? "-")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.045)))
        .accessibilityElement(children: .combine)
    }

    // MARK: Hardware usage

    private func hardwareUsage(_ snapshot: SystemTabMonitor.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                subsectionLabel(localized("Hardware usage"))
                Spacer(minLength: 0)
                Button(action: onOpenActivityMonitor) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(localized("Activity Monitor…"))
                .accessibilityLabel(localized("Activity Monitor…"))
            }
            usageRow(localized("CPU"), value: snapshot.cpuUsage, expanded: $expandedCPU)
            if expandedCPU {
                processList(
                    monitor.processes.sorted { $0.cpu > $1.cpu }.map { ProcessRow(pid: $0.pid, name: $0.name, value: Self.percent($0.cpu)) },
                    emptyText: localized("Calculating…")
                )
            }
            usageRow(localized("GPU"), value: snapshot.gpuUsage, expanded: $expandedGPU)
            if expandedGPU {
                processList(
                    monitor.gpuProcesses.map { ProcessRow(pid: $0.pid, name: $0.name, value: Self.percent($0.percent)) },
                    emptyText: monitor.gpuProcessesMeasured ? localized("No apps using the GPU") : localized("Calculating…")
                )
            }
        }
    }

    private func usageRow(_ title: String, value: Double?, expanded: Binding<Bool>?) -> some View {
        HStack(spacing: 8) {
            chevron(expanded)
            Text(title)
                .font(Fonts.row)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Longer translations (French "Processeur") shrink rather than truncate.
                .minimumScaleFactor(0.75)
                .frame(width: 52, alignment: .leading)
            UsageBar(fraction: value ?? 0, color: usageColor(value ?? 0))
            Text(value.map { localized("%d%%", Int(($0 * 100).rounded())) } ?? "-")
                .font(Fonts.value)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded?.wrappedValue.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(expanded == nil ? [] : .isButton)
    }

    /// Accent below 60%, yellow below 85%, red above.
    private func usageColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: SettingsStyle.accent
        case ..<0.85: SystemPalette.yellow(colorScheme)
        default: SystemPalette.red(colorScheme)
        }
    }

    // MARK: Memory

    private func memory(_ snapshot: SystemTabMonitor.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            subsectionLabel(localized("Memory"))
            HStack(spacing: 8) {
                chevron($expandedMemory)
                Text(localized("Pressure"))
                    .font(Fonts.row)
                    .foregroundStyle(.secondary)
                if let pressure = snapshot.pressure {
                    PressurePill(level: pressure)
                }
                Spacer(minLength: 8)
                if let memory = snapshot.memory {
                    Text(localized("%@ / %@", SystemFormat.bytes(memory.usedBytes), SystemFormat.bytes(memory.totalBytes)))
                        .font(Fonts.value)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { expandedMemory.toggle() }
            .accessibilityAddTraits(.isButton)

            if let memory = snapshot.memory {
                secondaryRow(localized("Compressed"), SystemFormat.bytes(memory.compressedBytes))
                secondaryRow(localized("Cached files"), SystemFormat.bytes(memory.cachedBytes))
            }
            if let swap = snapshot.swapUsed {
                secondaryRow(localized("Swap used"), SystemFormat.bytes(swap))
            }
            if monitor.memoryHistory.count > 1 {
                MemoryHistoryGraph(values: monitor.memoryHistory, color: SystemPalette.mint(colorScheme))
                    .frame(height: 30)
                    .padding(.top, 4)
            }
            if expandedMemory {
                processList(
                    monitor.processes.sorted { $0.memory > $1.memory }.map { ProcessRow(pid: $0.pid, name: $0.name, value: SystemFormat.bytes($0.memory)) },
                    emptyText: localized("Calculating…")
                )
            }
        }
    }

    private func secondaryRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Fonts.secondaryRow)
            Spacer(minLength: 8)
            Text(value)
                .font(Fonts.value)
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .accessibilityElement(children: .combine)
    }

    // MARK: Uptime and devices

    private func uptime(_ snapshot: SystemTabMonitor.Snapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(Fonts.smallIcon)
            Text(snapshot.uptime.map { localized("Up for %@", SystemCounters.formatUptime($0)) } ?? "-")
                .font(.system(size: 10.5, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    private func connectedDevices(_ snapshot: SystemTabMonitor.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expandedDevices.toggle()
            } label: {
                HStack(spacing: 8) {
                    Label(localized("Connected Devices"), systemImage: "cable.connector")
                        .font(Fonts.value)
                    Spacer(minLength: 0)
                    Text("\(snapshot.devices.count)")
                        .font(Fonts.value)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(Fonts.chevron)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expandedDevices ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedDevices {
                ForEach(Array(snapshot.devices.enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(Fonts.secondaryRow)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 20)
                }
            }
        }
    }

    // MARK: Shared pieces

    private func subsectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Fonts.subsection)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func chevron(_ expanded: Binding<Bool>?) -> some View {
        Image(systemName: "chevron.right")
            .font(Fonts.chevron)
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded?.wrappedValue == true ? 90 : 0))
            .opacity(expanded == nil ? 0.35 : 1)
    }

    private struct ProcessRow: Identifiable {
        let pid: pid_t
        let name: String
        let value: String
        var id: pid_t { pid }
    }

    private static func percent(_ value: Double) -> String {
        localized("%@%%", value.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.current.formatLocale)))
    }

    private func processList(_ apps: [ProcessRow], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if apps.isEmpty {
                Text(emptyText)
                    .font(Fonts.secondaryRow)
                    .foregroundStyle(.tertiary)
            }
            ForEach(apps.prefix(Self.processLimit)) { app in
                HStack(spacing: 7) {
                    Image(nsImage: ProcessIcon.icon(for: app.pid))
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(app.name)
                        .font(Fonts.secondaryRow)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(app.value)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .help(app.name)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.leading, 38)
        .padding(.vertical, 2)
    }
}

/// Status colours, slightly deeper in light mode so they stay readable.
enum SystemPalette {
    static func green(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Color(red: 0.05, green: 0.50, blue: 0.22) : .green
    }

    static func yellow(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Color(red: 0.60, green: 0.40, blue: 0.00) : .yellow
    }

    static func red(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Color(red: 0.72, green: 0.10, blue: 0.12) : .red
    }

    static func orange(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Color(red: 0.72, green: 0.34, blue: 0.00) : .orange
    }

    static func mint(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Color(red: 0.00, green: 0.48, blue: 0.44) : .mint
    }
}

/// Thin rounded usage bar.
struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(3, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 5)
    }
}

/// App icons for the process lists, cached per pid.
@MainActor
enum ProcessIcon {
    private static var cache: [pid_t: NSImage] = [:]
    private static let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    static func icon(for pid: pid_t) -> NSImage {
        if let cached = cache[pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon ?? generic
        if cache.count > 400 { cache.removeAll() }
        cache[pid] = icon
        return icon
    }
}

/// "● Normal" / "● Warning" / "● Critical", tinted by level.
struct PressurePill: View {
    let level: MemoryPressureLevel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.6), radius: 2)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.13)))
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch level {
        case .normal: SystemPalette.green(colorScheme)
        case .warning: SystemPalette.yellow(colorScheme)
        case .critical: SystemPalette.red(colorScheme)
        }
    }

    private var title: String {
        switch level {
        case .normal: localized("Normal")
        case .warning: localized("Warning")
        case .critical: localized("Critical")
        }
    }
}

/// Memory used over recent samples on a fixed 0–100% scale: a filled line
/// across the full width, a baseline, and a dashed 100% ceiling labelled
/// over the oldest samples.
struct MemoryHistoryGraph: View {
    let values: [Double]
    var color: Color = .mint

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let baseline = max(0.5, size.height - 0.5)
            let points = Self.points(values, in: size)
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
                Text(localized("%d%%", 100))
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

    /// Samples spread across the full width, oldest at the left.
    static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let baseline = max(0.5, size.height - 0.5)
        let plotHeight = max(1, baseline - 0.5)
        let lastIndex = CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(
                x: size.width * CGFloat(index) / lastIndex,
                y: baseline - plotHeight * CGFloat(min(max(value, 0), 1))
            )
        }
    }
}

enum SystemFormat {
    /// Binary units like Activity Monitor and Vorssaint: "11.53 GB", "16 GB",
    /// "702.5 MB", "499 MB" (trailing zeros dropped).
    static func bytes(_ value: UInt64) -> String {
        let locale = AppLanguage.current.formatLocale
        let gib = Double(value) / 1_073_741_824
        if gib >= 1 {
            let number = gib.formatted(.number.precision(.fractionLength(0...(gib >= 100 ? 0 : 2))).locale(locale))
            return localized("%@ GB", number)
        }
        let mib = Double(value) / 1_048_576
        return localized("%@ MB", mib.formatted(.number.precision(.fractionLength(0...1)).locale(locale)))
    }
}
