import SwiftUI

/// The popover's Network tab, laid out like DuoBar's network page: the
/// current rate, a traffic graph, download/upload rates, connection details
/// and a link to Network settings.
struct NetworkDetailView: View {
    @ObservedObject var statusStore: SystemStatusStore
    let onOpenNetworkSettings: () -> Void

    @ObservedObject private var traffic = NetworkTrafficMonitor.shared

    static let downloadColor = Color(red: 0.71, green: 0.45, blue: 0.86)
    static let uploadColor = Color(red: 1.00, green: 0.62, blue: 0.20)

    var body: some View {
        let network = statusStore.status.network
        let current = network.isConnected ? traffic.current : nil
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(localized("Network"))
                    .font(PopoverFont.title)
                Spacer(minLength: 8)
                Text(NetworkRateFormatter.rate((current?.download ?? 0) + (current?.upload ?? 0)))
                    .font(PopoverFont.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)

            NetworkTrafficGraph(
                samples: traffic.history,
                slots: NetworkTrafficMonitor.historyLength,
                downloadColor: Self.downloadColor,
                uploadColor: Self.uploadColor
            )
            .frame(height: 58)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(PopoverCardBackground(radius: 10))
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                rateRow(localized("Download"), color: Self.downloadColor, value: current?.download ?? 0)
                rateRow(localized("Upload"), color: Self.uploadColor, value: current?.upload ?? 0)
            }

            divider

            VStack(spacing: 0) {
                infoRow(localized("Connection"), connectionText(network))
                if network.isConnected, network.transport == .wifi, let ssid = network.ssid {
                    infoRow(localized("Network Name"), ssid)
                }
                infoRow(localized("IP Address"), network.isConnected ? (displayedIPAddress ?? "–") : "–")
            }

            divider

            Button(action: onOpenNetworkSettings) {
                Text(localized("Network Settings…"))
                    .font(PopoverFont.body)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
        }
    }

    /// Marketing captures show a placeholder instead of the Mac's real address.
    private var displayedIPAddress: String? {
        #if DEBUG
        if MarketingCaptureMode.isEnabled { return "192.168.1.20" }
        #endif
        return traffic.ipAddress
    }

    private var divider: some View {
        Rectangle()
            .fill(PopoverStyle.divider)
            .frame(height: 1)
            .padding(.horizontal, 4)
    }

    private func rateRow(_ title: String, color: Color, value: Double) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(PopoverFont.body)
            Spacer(minLength: 8)
            Text(NetworkRateFormatter.rate(value))
                .font(PopoverFont.body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
        .accessibilityElement(children: .combine)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(PopoverFont.body)
            Spacer(minLength: 8)
            Text(value)
                .font(PopoverFont.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
        .accessibilityElement(children: .combine)
    }

    private func connectionText(_ network: NetworkStatus) -> String {
        guard network.isAvailable else { return localized("Unavailable") }
        guard network.isConnected else {
            return network.isWiFiPoweredOn == false ? localized("Wi-Fi disabled") : localized("Not connected")
        }
        switch network.transport {
        case .wifi: return localized("Wi-Fi")
        case .ethernet: return localized("Ethernet")
        case .other: return network.interfaceName ?? localized("Connected")
        case .none: return localized("Not connected")
        }
    }
}

/// Download and upload over the last minute: smooth filled curves on one
/// shared scale, newest at the right edge.
struct NetworkTrafficGraph: View {
    let samples: [NetworkTrafficMonitor.Sample]
    let slots: Int
    let downloadColor: Color
    let uploadColor: Color

    /// Below this peak the graph stays flat instead of magnifying noise.
    static let minimumScale: Double = 2_000

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let peak = max(samples.map { max($0.download, $0.upload) }.max() ?? 0, Self.minimumScale)
            ZStack {
                series(samples.map(\.download), color: downloadColor, peak: peak, size: size)
                series(samples.map(\.upload), color: uploadColor, peak: peak, size: size)
            }
        }
    }

    @ViewBuilder
    private func series(_ values: [Double], color: Color, peak: Double, size: CGSize) -> some View {
        let points = Self.points(values, peak: peak, size: size, slots: slots)
        if points.count > 1 {
            ZStack {
                Self.curve(points, closingTo: size.height)
                    .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                Self.curve(points, closingTo: nil)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }

    static func points(_ values: [Double], peak: Double, size: CGSize, slots: Int) -> [CGPoint] {
        let step = size.width / CGFloat(max(slots - 1, 1))
        let offset = CGFloat(max(slots - values.count, 0)) * step
        let usable = size.height - 2
        return values.suffix(slots).enumerated().map { index, value in
            CGPoint(
                x: offset + CGFloat(index) * step,
                y: 1 + usable * (1 - CGFloat(min(max(value / peak, 0), 1)))
            )
        }
    }

    /// Catmull-Rom spline through the points, clamped so peaks never overshoot
    /// the graph; closed down to `baseline` when given (for the fill).
    static func curve(_ points: [CGPoint], closingTo baseline: CGFloat?) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            if let baseline {
                path.move(to: CGPoint(x: first.x, y: baseline))
                path.addLine(to: first)
            } else {
                path.move(to: first)
            }
            let top = points.map(\.y).min() ?? 0
            let bottom = points.map(\.y).max() ?? 0
            for index in 0..<(points.count - 1) {
                let p0 = points[max(index - 1, 0)]
                let p1 = points[index]
                let p2 = points[index + 1]
                let p3 = points[min(index + 2, points.count - 1)]
                func clamp(_ point: CGPoint) -> CGPoint {
                    CGPoint(x: point.x, y: min(max(point.y, top), bottom))
                }
                let control1 = clamp(CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6))
                let control2 = clamp(CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
                path.addCurve(to: p2, control1: control1, control2: control2)
            }
            if let baseline {
                path.addLine(to: CGPoint(x: last.x, y: baseline))
                path.closeSubpath()
            }
        }
    }
}
