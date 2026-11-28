import SwiftUI

/// Modes the desktop widget cycles through on click. Batches ship in
/// order — `.standard` and `.adaptive` first, `.custom` second; `.music`
/// appends last — raw values must never be reused or reordered, and
/// cycling uses `allCases.count`, so new modes join the cycle
/// automatically.
enum DesktopWidgetMode: Int, CaseIterable {
    case standard = 0
    case adaptive = 1
    case custom = 2

    /// Name flashed briefly on the widget face when the mode is entered.
    var title: String {
        switch self {
        case .standard: return "Standard"
        case .adaptive: return "Adaptive Ring"
        case .custom: return "Custom"
        }
    }

    /// Modes reachable in the current release. Adaptive and Custom are
    /// built but ship in a later update: cycling, rendering and Settings
    /// all clamp to this list, so widening it is the only change needed
    /// when they ship.
    static var releasedModes: [DesktopWidgetMode] { [.standard] }
}

/// What the ring itself reports in custom mode. `.battery` keeps the
/// full battery presentation (charging bolt, colour roles); every other
/// source draws as a plain progress arc with the Adaptive Ring's colour
/// for that metric. Raw values persist — never reuse or reorder them.
enum DesktopWidgetRingSource: Int, CaseIterable {
    case battery = 0
    case cpu = 1
    case memory = 2
    case thermal = 3
    case brightness = 4
    case wifi = 5

    /// Settings-picker label.
    var title: String {
        switch self {
        case .battery: return "Battery"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .thermal: return "Thermal"
        case .brightness: return "Brightness"
        case .wifi: return "Wi-Fi Signal"
        }
    }
}

/// User-selectable widget size. The raw values persist — never reuse or
/// reorder them.
enum DesktopWidgetSize: Int, CaseIterable {
    case small = 0
    case medium = 1
    case large = 2

    var scale: CGFloat {
        switch self {
        case .small: return 0.8
        case .medium: return 1.0
        case .large: return 1.3
        }
    }

    /// Settings-picker label.
    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

/// What the four dots under the ring report in custom mode. Raw values
/// persist in UserDefaults — never reuse or reorder them.
enum DesktopWidgetDotsSource: Int, CaseIterable {
    case volume = 0
    case battery = 1
    case cpu = 2
    case memory = 3
    case thermal = 4
    case wifi = 5

    /// Settings-picker and caption label.
    var title: String {
        switch self {
        case .volume: return "Volume"
        case .battery: return "Battery"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .thermal: return "Thermal"
        case .wifi: return "Wi-Fi Signal"
        }
    }
}

/// What sits in the glyph's centre in custom mode. `.network` means no
/// override: the centre follows the live connection, exactly like the
/// menu bar. Raw values persist — never reuse or reorder them.
enum DesktopWidgetCenterSource: Int, CaseIterable {
    case network = 0
    case cpu = 1
    case memory = 2
    case thermal = 3
    case brightness = 4

    /// Settings-picker label.
    var title: String {
        switch self {
        case .network: return "Network"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .thermal: return "Thermal"
        case .brightness: return "Brightness"
        }
    }
}

/// The desktop widget's face: the real Duo glyph, large, on a glass card.
///
/// Mode 1 (standard) resolves the glyph exactly like the menu bar's
/// battery presentation; mode 2 (adaptive) forces the Adaptive Ring with
/// the live performance monitor, colour-coded unconditionally (the
/// Settings colour-coding toggle governs the menu bar; on this showcase
/// surface the colour IS the signal), with the active metric's symbol
/// held in the centre. Mode 3 (custom) lets the user choose what the
/// ring reports, what the four dots report and which symbol sits in the
/// centre; the dots are driven by feeding the glyph a status copy whose
/// volume carries the chosen metric's level, so the dot geometry and
/// thresholds stay the menu bar's own. The percentage is deliberately
/// not drawn inside the ring gap — the glyph scales its 8 pt text by
/// raster, which softens at this size — the caption below renders it
/// natively instead.
struct DesktopWidgetView: View {
    @ObservedObject var statusStore: SystemStatusStore
    @ObservedObject private var adaptiveRingMonitor = AdaptiveRingMonitor.shared
    @AppStorage(PreferenceKeys.desktopWidgetMode) private var modeRaw = DesktopWidgetMode.standard.rawValue
    @AppStorage(PreferenceKeys.desktopWidgetCustomDots) private var customDotsRaw = DesktopWidgetDotsSource.volume.rawValue
    @AppStorage(PreferenceKeys.desktopWidgetCustomCenter) private var customCenterRaw = DesktopWidgetCenterSource.network.rawValue
    @AppStorage(PreferenceKeys.desktopWidgetCustomRing) private var customRingRaw = DesktopWidgetRingSource.battery.rawValue
    @AppStorage(PreferenceKeys.desktopWidgetSize) private var widgetSizeRaw = DesktopWidgetSize.medium.rawValue
    @AppStorage(PreferenceKeys.animationsEnabled) private var animationsEnabled = true
    @AppStorage(PreferenceKeys.batteryColorCoding) private var batteryColorCoding = false
    @AppStorage(PreferenceKeys.adaptiveRingColorCoding) private var adaptiveRingColorCoding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var adaptivePresentation = AdaptiveRingPresentationState()
    @State private var adaptiveTransition: AdaptiveRingPresentationTransition = .none
    @State private var monitorOwner = UUID()
    @State private var toastName: String?
    @State private var toastGeneration = 0
    /// Follows Icon & widget style in System Settings.
    @StateObject private var widgetStyle = WidgetStyleObserver()

    private var mode: DesktopWidgetMode {
        let stored = DesktopWidgetMode(rawValue: modeRaw) ?? .standard
        return DesktopWidgetMode.releasedModes.contains(stored) ? stored : .standard
    }

    private var dotsSource: DesktopWidgetDotsSource {
        DesktopWidgetDotsSource(rawValue: customDotsRaw) ?? .volume
    }

    private var centerSource: DesktopWidgetCenterSource {
        DesktopWidgetCenterSource(rawValue: customCenterRaw) ?? .network
    }

    private var ringSource: DesktopWidgetRingSource {
        DesktopWidgetRingSource(rawValue: customRingRaw) ?? .battery
    }

    private var sizeScale: CGFloat {
        (DesktopWidgetSize(rawValue: widgetSizeRaw) ?? .medium).scale
    }

    /// The glyph's visual extent on the card, in points.
    private var glyphExtent: CGFloat { 102 * sizeScale }

    private var motionAllowed: Bool {
        animationsEnabled && !reduceMotion
    }

    /// Metrics the glyph is drawn with. This mirrors the film stage's
    /// approach (see DuoStatusView): grow the DESIGN fields and leave
    /// overallSize at the menu-bar value, so the glyph draws natively at
    /// widget size and its root scaleEffect(overallSize / canvasSize)
    /// scales DOWN — sharp. sized(_:) grows only overallSize, which
    /// upscales the small native render; the SF Symbol centres (CPU,
    /// memorychip…) came out soft that way.
    private var glyphMetrics: DuoGlyphMetrics {
        let factor = glyphExtent / DuoGlyphMetrics.standard.overallSize
        var metrics = DuoGlyphMetrics.standard
        metrics.ringDiameter *= factor
        metrics.ringLineWidth *= factor
        metrics.wifiSymbolSize *= factor
        metrics.wifiYOffset *= factor
        metrics.dotDiameter *= factor
        metrics.dotSpacing *= factor
        metrics.dotYOffset *= factor
        metrics.ringYOffset *= factor
        return metrics
    }

    /// Mode changes cross through a blur, like a native widget refresh:
    /// the old face blurs and fades out while the new one sharpens in.
    private var modeTransition: AnyTransition {
        guard motionAllowed else { return .opacity }
        return .modifier(
            active: WidgetModeBlurModifier(radius: 12, opacity: 0),
            identity: WidgetModeBlurModifier(radius: 0, opacity: 1)
        )
    }

    /// The performance monitor runs in adaptive mode (it IS the data)
    /// and in custom mode (CPU / memory / thermal dots or centre read
    /// its snapshots). Standard mode never acquires it.
    private var needsMonitor: Bool {
        mode == .adaptive || mode == .custom || mirrorsMenuBarAdaptiveRing
    }

    /// Standard mode mirrors the menu bar, so it must also follow the
    /// menu bar's own Battery → Adaptive switch: a desktop Mac, or a
    /// MacBook that has reached full charge on power, draws the Adaptive
    /// Ring there, and the widget has to draw the same ring.
    private var mirrorsMenuBarAdaptiveRing: Bool {
        mode == .standard && statusStore.usesReleasedAdaptiveRing
    }

    /// Whether the ring currently draws the Adaptive Ring's progress.
    private var drawsAdaptiveRing: Bool {
        mode == .adaptive || mirrorsMenuBarAdaptiveRing
    }

    /// The status the glyph renders. In custom mode with a non-volume
    /// dots source, this is a copy whose volume level carries the chosen
    /// metric's fraction, so DuoGlyphState derives the dot count from it
    /// with the menu bar's own thresholds. A nil fraction (source
    /// unavailable) yields a nil dot count, which the glyph draws as
    /// "no reading" — never as the real volume.
    private var effectiveStatus: SystemStatus {
        guard mode == .custom, dotsSource != .volume else {
            return statusStore.status
        }
        var status = statusStore.status
        status.audio.volume = OutputVolumeStatus(
            level: dotsFraction,
            isMuted: false,
            isSettable: false
        )
        return status
    }

    /// The fraction the custom dots currently report, on each source's
    /// natural 0–1 scale. Thermal is a four-step state, mapped onto
    /// quarters (nominal ¼ … critical 4⁄4).
    private var dotsFraction: Double? {
        switch dotsSource {
        case .volume:
            return statusStore.status.audio.volume.level
        case .battery:
            return statusStore.status.battery.percentage.map { Double($0) / 100 }
        case .cpu:
            return adaptiveRingMonitor.performanceSnapshot?.cpuLoad
        case .memory:
            return adaptiveRingMonitor.performanceSnapshot?.memory.map { 1 - $0.availableHeadroom }
        case .thermal:
            return adaptiveRingMonitor.performanceSnapshot.map {
                Double($0.thermalState.rawValue + 1) / 4
            }
        case .wifi:
            return statusStore.status.network.signalStrength
        }
    }

    /// The fraction a non-battery custom ring currently reports, on the
    /// same natural scales as dotsFraction.
    private var ringFraction: Double? {
        switch ringSource {
        case .battery:
            return nil
        case .cpu:
            return adaptiveRingMonitor.performanceSnapshot?.cpuLoad
        case .memory:
            return adaptiveRingMonitor.performanceSnapshot?.memory.map { 1 - $0.availableHeadroom }
        case .thermal:
            return adaptiveRingMonitor.performanceSnapshot.map {
                Double($0.thermalState.rawValue + 1) / 4
            }
        case .brightness:
            if case .available(let value) = adaptiveRingMonitor.brightnessSnapshot?.availability {
                return value
            }
            return nil
        case .wifi:
            return statusStore.status.network.signalStrength
        }
    }

    var body: some View {
        // Capture the State bindings once: result-builder modifier
        // closures must not capture the projections directly (same
        // constraint DuoStatusView documents).
        let adaptivePresentationBinding = $adaptivePresentation
        let adaptiveTransitionBinding = $adaptiveTransition

        ZStack {
            Color.clear
                .widgetSurface(
                    in: RoundedRectangle(cornerRadius: 30 * sizeScale, style: .continuous),
                    style: widgetStyle.style,
                    glassTint: widgetStyle.glassTint
                )

            VStack(spacing: 7 * sizeScale) {
                // The glyph's layout box stays at the menu-bar size (its
                // design fields carry the magnification — see
                // glyphMetrics), so it is centred in a fixed visual
                // frame, the same arrangement the film stage uses.
                DuoGlyphView(
                    status: effectiveStatus,
                    presentation: .normal,
                    metrics: glyphMetrics,
                    animationsEnabled: animationsEnabled,
                    ringPresentation: ringPresentation,
                    centerStateOverride: centerOverride,
                    ringTransitionAnimation: ringAnimation,
                    usesCustomRingTransition: drawsAdaptiveRing,
                    ringColorOverride: ringColor,
                    batteryColorCodingEnabled: batteryColorCoding,
                    showBatteryPercentage: false
                )
                .frame(width: glyphExtent, height: glyphExtent)

                Text(caption)
                    .font(.system(size: max(10, 12 * sizeScale), weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .id(mode)
            .transition(modeTransition)
        }
        .animation(motionAllowed ? .easeInOut(duration: 0.3) : nil, value: mode)
        .animation(.easeInOut(duration: 0.25), value: toastName)
        .overlay(alignment: .top) {
            if let toastName {
                Text(toastName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .widgetSurface(in: Capsule(), style: widgetStyle.style, glassTint: widgetStyle.glassTint)
                    .padding(.top, 7 * sizeScale)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .onAppear {
            if needsMonitor { acquireMonitor() }
        }
        .onDisappear {
            adaptiveRingMonitor.release(owner: monitorOwner)
        }
        .onChange(of: mode) { _, newMode in
            // Re-sync the ring when a mode switch keeps the monitor running.
            if needsMonitor { acquireMonitor() }
            flashModeName(newMode)
        }
        .onChange(of: needsMonitor) { _, needed in
            if needed {
                acquireMonitor()
            } else {
                adaptiveRingMonitor.release(owner: monitorOwner)
            }
        }
        .onChange(of: adaptiveRingMonitor.state) { _, newState in
            guard drawsAdaptiveRing else { return }
            var presentation = adaptivePresentationBinding.wrappedValue
            let transition = presentation.retarget(to: newState)
            adaptivePresentationBinding.wrappedValue = presentation
            adaptiveTransitionBinding.wrappedValue = transition
        }
    }

    private var ringPresentation: DuoPersistentRingPresentation {
        if mode == .custom, ringSource != .battery {
            // An unavailable source draws an empty ring, never a
            // stand-in value.
            return .adaptive(progress: ringFraction ?? 0)
        }
        return DuoPersistentRingPresentationResolver.resolve(
            mode: drawsAdaptiveRing ? .adaptive : .battery,
            battery: statusStore.status.battery,
            adaptiveProgress: adaptivePresentation.displayedProgress,
            batteryColorCodingEnabled: batteryColorCoding
        )
    }

    private var centerOverride: DuoCenterState? {
        switch mode {
        case .standard:
            return nil
        case .adaptive:
            switch AdaptiveRingSourceIdentity(state: adaptiveRingMonitor.state) {
            case .cpu: return .performanceCPU
            case .memory: return .performanceMemory
            case .thermal: return .performanceThermal
            case .brightness: return .adaptiveBrightness
            case .neutral: return nil
            }
        case .custom:
            switch centerSource {
            case .network: return nil
            case .cpu: return .performanceCPU
            case .memory: return .performanceMemory
            case .thermal: return .performanceThermal
            case .brightness: return .adaptiveBrightness
            }
        }
    }

    private var ringColor: Color? {
        if mode == .custom, ringSource != .battery {
            // The custom ring reports one chosen metric, so its colour
            // is that metric's Adaptive Ring colour outright — the
            // resolver's "only when the engine agrees" rule is the menu
            // bar's policy, not this surface's.
            let role: AdaptiveRingColorRole
            switch ringSource {
            case .cpu: role = .cpu
            case .memory: role = .memory
            case .thermal: role = .thermal
            case .brightness: role = .brightness
            case .battery, .wifi: return nil
            }
            return AdaptiveRingColorPresentation(role: role, intensity: 0.85).color
        }
        guard drawsAdaptiveRing else { return nil }
        return AdaptiveRingColorResolver.resolve(
            state: adaptiveRingMonitor.state,
            decision: adaptiveRingMonitor.performanceDecision,
            // Standard mode mirrors the menu bar, so it honours the
            // Settings colour-coding toggle; the adaptive showcase mode
            // colour-codes unconditionally.
            colorCodingEnabled: mode == .adaptive || adaptiveRingColorCoding
        ).color
    }

    private var ringAnimation: Animation? {
        guard drawsAdaptiveRing else { return nil }
        let duration = adaptiveTransition.effectiveDuration(
            animationsEnabled: animationsEnabled,
            reduceMotion: reduceMotion
        )
        return duration > 0 ? .timingCurve(0.4, 0, 0.2, 1, duration: duration) : nil
    }

    private var caption: String {
        switch mode {
        case .standard:
            return statusStore.status.battery.percentage.map { "\($0)%" } ?? "—"
        case .adaptive:
            switch AdaptiveRingSourceIdentity(state: adaptiveRingMonitor.state) {
            case .cpu: return "CPU"
            case .memory: return "Memory"
            case .thermal: return "Thermal"
            case .brightness: return "Brightness"
            case .neutral: return "Idle"
            }
        case .custom:
            // The caption reports the dots source: it is the number the
            // four dots are quantising, so label and value travel
            // together.
            switch dotsSource {
            case .volume:
                return percentCaption("Volume", statusStore.status.audio.volume.level)
            case .battery:
                return statusStore.status.battery.percentage.map { "Battery \($0)%" } ?? "Battery —"
            case .cpu:
                return percentCaption("CPU", adaptiveRingMonitor.performanceSnapshot?.cpuLoad)
            case .memory:
                return percentCaption(
                    "Memory",
                    adaptiveRingMonitor.performanceSnapshot?.memory.map { 1 - $0.availableHeadroom }
                )
            case .thermal:
                guard let thermal = adaptiveRingMonitor.performanceSnapshot?.thermalState else {
                    return "Thermal —"
                }
                switch thermal {
                case .nominal: return "Thermal · Nominal"
                case .fair: return "Thermal · Fair"
                case .serious: return "Thermal · Serious"
                case .critical: return "Thermal · Critical"
                }
            case .wifi:
                return percentCaption("Wi-Fi", statusStore.status.network.signalStrength)
            }
        }
    }

    private func percentCaption(_ label: String, _ fraction: Double?) -> String {
        guard let fraction else { return "\(label) —" }
        return "\(label) \(Int((fraction * 100).rounded()))%"
    }

    private func acquireMonitor() {
        adaptiveRingMonitor.acquire(owner: monitorOwner)
        var presentation = adaptivePresentation
        presentation.synchronize(to: adaptiveRingMonitor.state)
        adaptivePresentation = presentation
    }

    /// Briefly names the mode just entered, so a click-cycle is never a
    /// guessing game. Rapid clicking restarts the clock: only the latest
    /// generation may clear the label.
    private func flashModeName(_ newMode: DesktopWidgetMode) {
        toastName = newMode.title
        toastGeneration += 1
        let generation = toastGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.25))
            if toastGeneration == generation {
                toastName = nil
            }
        }
    }
}

/// Blur + fade pair for the mode-change transition: the outgoing face
/// blurs away while the incoming one sharpens from the same blur.
private struct WidgetModeBlurModifier: ViewModifier {
    let radius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: radius)
            .opacity(opacity)
    }
}

private extension View {
    /// The widget's card surface, matched to the system's own desktop
    /// widgets in each Icon & widget style. In the see-through styles the
    /// Liquid Glass slider sets how much the wallpaper behind is blurred, as
    /// it does for the native widgets. Earlier systems keep the translucent
    /// material, without a border.
    @ViewBuilder
    func widgetSurface<S: InsettableShape>(in shape: S, style: WidgetStyle, glassTint: Double) -> some View {
        if #available(macOS 26.0, *) {
            background { WidgetSurface(shape: shape, style: style, glassTint: glassTint) }
        } else {
            background { shape.fill(.ultraThinMaterial) }
        }
    }
}

/// Fills and rim measured from the native widgets, against the wallpaper
/// behind them, for each Icon & widget style.
@available(macOS 26.0, *)
private struct WidgetSurface<S: InsettableShape>: View {
    let shape: S
    let style: WidgetStyle
    let glassTint: Double
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            switch style {
            case .clear(let isDark), .tinted(let isDark, _):
                WidgetFrost(shape: shape, glassTint: glassTint, isDark: isDark)
            default:
                EmptyView()
            }
            switch style {
            case .standard:
                opaqueCard(dark: colorScheme == .dark)
            case .dark:
                opaqueCard(dark: true)
            case .light:
                opaqueCard(dark: false)
            case .clear(let isDark):
                // Dark: the wallpaper about a tenth darker.
                // Light: a white veil of about a sixth.
                shape.fill(isDark ? Color.black.opacity(0.10) : Color.white.opacity(0.17))
            case .tinted(let isDark, let tint):
                if isDark {
                    shape.fill(Color.black.opacity(0.10))
                    shape.fill(Color(nsColor: tint).opacity(0.02))
                } else {
                    shape.fill(Color(nsColor: tint).opacity(0.13))
                    shape.fill(Color.white.opacity(0.07))
                }
            }
            WidgetSurfaceRim(shape: shape)
        }
    }

    /// The Default and Dark styles: an opaque card, lighter at the top.
    /// The native dark card measures 55 → 33 (of 255) on screen, top to
    /// bottom. In this desktop-level panel grays come out brighter than
    /// specified (about value^0.82), so the inputs are set lower to land on
    /// the measured values. The light card is an estimate: it could not be
    /// measured.
    private func opaqueCard(dark: Bool) -> some View {
        let top = dark ? 42.0 / 255 : 0.96
        let bottom = dark ? 24.0 / 255 : 0.89
        return shape.fill(
            LinearGradient(
                colors: [Color(.sRGB, white: top), Color(.sRGB, white: bottom)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

/// The see-through styles' blur of the wallpaper behind the widget, which
/// follows the Liquid Glass slider. Measured on the native widgets: no blur
/// at the Clear end, about half at 0.6, and full from about 0.77 on (0.77
/// and 1 look identical), with no change in color. A behind-window blur
/// with the material's tint removed does it; its opacity sets the strength.
@available(macOS 26.0, *)
private struct WidgetFrost<S: InsettableShape>: View {
    let shape: S
    let glassTint: Double
    let isDark: Bool

    static func strength(for glassTint: Double) -> Double {
        min(max((glassTint - 0.35) / 0.42, 0), 1)
    }

    var body: some View {
        let strength = Self.strength(for: glassTint)
        if strength > 0.01 {
            BehindWindowBlur(material: .hudWindow, isDark: isDark)
                .clipShape(shape)
                .opacity(strength)

        }
    }
}

/// A blur of whatever is behind the window (here, the wallpaper).
/// A blur of whatever is behind the window (here, the wallpaper), without
/// the gray tint every system material adds on top. The native widgets blur
/// the wallpaper but keep its color, so the material's tint and color
/// filters are switched off and only its blur is kept. That relies on the
/// material's layer structure, which is not public: if it is not found, the
/// view keeps the plain material (blur plus tint).
private struct BehindWindowBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let isDark: Bool

    func makeNSView(context: Context) -> PureBlurView {
        let view = PureBlurView()
        view.blendingMode = .behindWindow
        // Always active: the widget's panel is never the key window.
        view.state = .active
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PureBlurView, context: Context) {
        view.material = material
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        view.needsLayout = true
    }
}

final class PureBlurView: NSVisualEffectView {
    // The material repaints its layers in updateLayer and layout, so the
    // tint is removed again after each.
    override func updateLayer() {
        super.updateLayer()
        removeTint()
    }

    override func layout() {
        super.layout()
        removeTint()
    }

    /// The material is a blurring backdrop layer with plain color layers
    /// over it (on macOS 26-27: a 40% gray fill, a lighten-blended dark gray
    /// and a faint chameleon tint), and the backdrop saturates what it blurs.
    /// Hiding every leaf layer that carries no filters, and dropping the
    /// saturation filter, leaves just the blur. If the structure changes and
    /// no filtered layer is found, nothing is hidden.
    private func removeTint() {
        guard let root = layer else { return }
        var hasBackdrop = false
        visit(root) { if !($0.filters ?? []).isEmpty { hasBackdrop = true } }
        guard hasBackdrop else { return }
        visit(root) { layer in
            if layer !== root, (layer.filters ?? []).isEmpty, layer.sublayers?.isEmpty ?? true {
                layer.isHidden = true
            }
            // The backdrop also boosts saturation; the native widgets keep
            // the wallpaper's color, so only that filter is dropped.
            if let filters = layer.filters as? [NSObject], filters.count > 1 {
                let kept = filters.filter { "\($0.value(forKey: "name") ?? "")" != "colorSaturate" }
                if kept.count != filters.count { layer.filters = kept }
            }
        }
    }

    private func visit(_ layer: CALayer, _ body: (CALayer) -> Void) {
        body(layer)
        layer.sublayers?.forEach { visit($0, body) }
    }
}

/// The thin light rim of the native widgets: a one-point edge, brightest at
/// the top and bottom. No inner glow: next to the native widgets, a glow
/// reads as frost around the edges.
private struct WidgetSurfaceRim<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.30), location: 0),
                    .init(color: .white.opacity(0.12), location: 0.5),
                    .init(color: .white.opacity(0.26), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: 1
        )
        .allowsHitTesting(false)
    }
}
