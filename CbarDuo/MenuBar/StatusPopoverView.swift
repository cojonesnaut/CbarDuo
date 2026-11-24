import AppKit
import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject private var statusStore: SystemStatusStore
    @ObservedObject private var presentation = PopoverPresentationState.shared
    @AppStorage(PreferenceKeys.showBatteryPercentage) private var showBatteryPercentage = true
    @AppStorage(PreferenceKeys.batteryColorCoding) private var batteryColorCoding = false
    @AppStorage(PreferenceKeys.popoverTab) private var tabRaw = PopoverTab.network.rawValue
    @AppStorage(PreferenceKeys.popoverHiddenTabs) private var hiddenTabsRaw = ""
    @State private var showingBatteryDetail = false
    @AppStorage(PreferenceKeys.barSlot) private var barSlotRaw = IndicatorBarSlot.volume.rawValue
    @ObservedObject private var usageMonitor = SystemUsageMonitor.shared
    private let onClose: () -> Void

    init(
        statusStore: SystemStatusStore,
        initialTab: PopoverTab? = nil,
        onClose: @escaping () -> Void
    ) {
        self.statusStore = statusStore
        self.onClose = onClose
        if let initialTab {
            _tabRaw = AppStorage(wrappedValue: initialTab.rawValue, PreferenceKeys.popoverTab)
            UserDefaults.standard.set(initialTab.rawValue, forKey: PreferenceKeys.popoverTab)
        }
    }

    private var visibleTabs: [PopoverTab] {
        PopoverTab.visible(hiddenRaw: hiddenTabsRaw)
    }

    /// The selected tab, falling back to the first visible one when the
    /// saved tab has been hidden in Settings.
    private var tab: Binding<PopoverTab> {
        Binding(
            get: {
                let saved = PopoverTab(rawValue: tabRaw) ?? .network
                return visibleTabs.contains(saved) ? saved : visibleTabs[0]
            },
            set: { tabRaw = $0.rawValue }
        )
    }

    var body: some View {
        // The NSPopover draws the glass and animates opening and closing.
        // Pinned to the top: switching tabs changes the content height at once
        // while the popover animates its size, and a centered layout would
        // make the header and icon bar jump during that animation.
        panelContent
            .focusRingsDisabled()
            // Every open starts on the tabs, not on a page left open last time.
            .onChange(of: presentation.isShown) { _, isShown in
                if !isShown { showingBatteryDetail = false }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var panelContent: some View {
        VStack(spacing: PopoverStyle.spacing) {
            if showingBatteryDetail {
                BatteryDetailView(
                    battery: statusStore.status.battery,
                    timeEstimate: statusStore.batteryTimeEstimate,
                    onBack: { showingBatteryDetail = false },
                    onOpenBatterySettings: openBatterySettings
                )
            } else {
                tabsContent
            }
        }
        .padding(.horizontal, PopoverStyle.padding)
        .padding(.bottom, PopoverStyle.padding)
        .padding(.top, PopoverStyle.padding)
        .frame(width: PopoverStyle.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @ViewBuilder
    private var tabsContent: some View {
        header

        PopoverTabBar(selection: tab, tabs: visibleTabs)

        switch tab.wrappedValue {
        // Audio tabs carry their own "Output" / "Input" card, like Fader.
        case .volume: volumeContent
        case .mic: micContent
        // DuoBar-style page with its own title row and graph card.
        case .network:
            NetworkDetailView(
                statusStore: statusStore,
                onOpenNetworkSettings: openNetworkSettings
            )
        // Vorssaint-style card with its own type scale.
        case .system:
            SystemDetailView(onOpenActivityMonitor: openActivityMonitor)
        case .battery, .bluetooth:
            PopoverSection(title: tab.wrappedValue.title) {
                switch tab.wrappedValue {
                case .battery:
                    batteryContent
                    PopoverDivider()
                    PowerDetailsView()
                default: bluetoothContent
                }
            }
        }

        #if DEBUG
        if !FilmTimelinePlayer.captureConfigured {
            DebugStatusSimulatorView(statusStore: statusStore)
        }
        #endif

        // Development diagnostics belong in the dedicated DEBUG diagnostics
        // surface, never in the production status-card hierarchy.
        HStack(spacing: 8) {
            settingsAction
            PopoverFooterButton(title: localized("Quit"), symbol: "power") {
                NSApp.terminate(nil)
            }
            .accessibilityLabel(localized("Quit CbarDuo"))
        }
        .padding(.top, 2)
    }

    // MARK: Tab content

    private var volumeContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            outputPanel
            PopoverDivider()
            AppMixerSection()
        }
    }

    private var outputPanel: some View {
        AudioDevicePanel(
            title: localized("Output"),
            current: statusStore.status.audio.defaultOutput,
            devices: statusStore.status.audio.selectableOutputs,
            isInput: false,
            emptyText: localized("No output device"),
            failureText: localized("Unable to Switch Output"),
            onSelect: { statusStore.setDefaultOutput(uid: $0) },
            onOpenSoundSettings: openSoundSettings
        ) {
            VolumeStatusRow(
                volume: statusStore.status.audio.volume,
                hasOutputDevice: statusStore.status.audio.defaultOutput != nil,
                playbackDeviceIdentifier: statusStore.status.audio.defaultOutput?.uid,
                onSetVolume: statusStore.setVolume,
                onSetMuted: statusStore.setMuted
            )
        }
    }

    private var micContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            inputPanel
            PopoverDivider()
            RecordingAppsSection()
        }
    }

    private var inputPanel: some View {
        AudioDevicePanel(
            title: localized("Input"),
            current: statusStore.status.audio.defaultInput,
            devices: statusStore.status.audio.selectableInputs,
            isInput: true,
            emptyText: localized("No input device"),
            failureText: localized("Unable to Switch Input"),
            onSelect: { statusStore.setDefaultInput(uid: $0) },
            onOpenSoundSettings: openSoundSettings
        ) {
            let inputVolume = statusStore.status.audio.inputVolume
            if inputVolume.isSettable, let level = inputVolume.level {
                FaderSlider(
                    level: level,
                    symbol: level > 0 ? "mic.fill" : "mic.slash.fill",
                    onChange: { _ = statusStore.setInputVolume($0) }
                )
                .accessibilityLabel(localized("Input volume"))
                .accessibilityValue(localized("%d%%", Int((level * 100).rounded())))
            } else if statusStore.status.audio.defaultInput != nil {
                Text(localized("Controlled by device"))
                    .font(PopoverFont.detail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            }
        }
    }

    private var batteryContent: some View {
        Button { showingBatteryDetail = true } label: {
            BatteryStatusRow(
                battery: statusStore.status.battery,
                showPercentage: showBatteryPercentage,
                showsDisclosure: true,
                timeEstimate: statusStore.batteryTimeEstimate
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityHint(localized("Show battery details"))
    }

    @ViewBuilder
    private var bluetoothContent: some View {
        Button(action: openBluetoothSettings) {
            BluetoothSummaryRow(bluetooth: statusStore.status.bluetooth)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityHint(localized("Bluetooth Settings…"))

        let devices = statusStore.status.audio.connectedBluetoothOutputs
        if statusStore.status.bluetooth.isPoweredOn {
            PopoverDivider()
            if devices.isEmpty {
                Text(localized("No Bluetooth audio devices connected"))
                    .font(PopoverFont.detail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
            } else {
                ForEach(Array(devices.enumerated()), id: \.element.uid) { index, device in
                    if index > 0 { PopoverDivider() }
                    BluetoothDeviceRow(
                        device: device,
                        isCurrentOutput: device.uid == statusStore.status.audio.defaultOutput?.uid
                    )
                }
            }
        }
    }

    /// Header: the live menu bar indicator, the app name and a connection pill.
    private var header: some View {
        VStack(spacing: 6) {
            DuoGlyphView(
                status: statusStore.status,
                metrics: DuoGlyphMetrics.standard.sized(40),
                animationsEnabled: false,
                batteryColorCodingEnabled: batteryColorCoding,
                barValue: IndicatorBarValue.make(
                    slot: IndicatorBarSlot(rawValue: barSlotRaw) ?? .volume,
                    networkSpeed: statusStore.networkSpeed,
                    memoryUsed: usageMonitor.memoryUsed,
                    diskUsed: usageMonitor.diskUsed
                )
            )
            .frame(width: 40, height: 40)
            .padding(.top, 2)
            .accessibilityHidden(true)
            Text("CbarDuo")
                .font(.headline)
            PopoverStatusPill(
                text: networkState,
                isActive: statusStore.status.network.isConnected
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var settingsAction: some View {
        // Deliberately not SettingsLink: the Settings scene's window
        // cannot stay resizable (the scene strips the flag), so settings
        // open in the app's own window via SettingsPresenter.
        PopoverFooterButton(title: localized("Settings"), symbol: "gearshape", action: openSettings)
    }

    private func openSettings() {
        SettingsPresenter.show()
        onClose()
    }

    private func openNetworkSettings() {
        // Mirrors Apple's own Wi-Fi icon (#17): holding Option while
        // activating the row opens the general Network settings instead of
        // the transport-specific pane.
        if NSEvent.modifierFlags.contains(.option) {
            _ = SystemSettingsOpener.open(.network)
        } else {
            _ = SystemSettingsOpener.open(SystemSettingsOpener.pane(for: statusStore.status.network))
        }
        onClose()
    }

    private func openBatterySettings() {
        _ = SystemSettingsOpener.open(.battery)
        onClose()
    }

    private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        onClose()
    }

    private func openBluetoothSettings() {
        _ = SystemSettingsOpener.open(.bluetooth)
        onClose()
    }

    private func openSoundSettings() {
        _ = SystemSettingsOpener.open(.sound)
        onClose()
    }

    private var networkState: String {
        let network = statusStore.status.network
        guard network.isAvailable else { return localized("Unavailable") }
        if network.isWiFiPoweredOn == false, !network.isConnected { return localized("Off") }
        guard network.isConnected else { return localized("Offline") }
        switch network.transport {
        case .wifi: return localized("Wi-Fi")
        case .ethernet: return localized("Ethernet")
        case .other: return localized("Connected")
        case .none: return localized("Offline")
        }
    }

    private var audioOutputSymbol: String {
        guard let output = statusStore.status.audio.defaultOutput else { return "speaker.slash" }
        switch output.category {
        case .airPods: return "airpodspro"
        case .headphones, .bluetoothAudio: return "headphones"
        case .displayAudio: return "display"
        case .usbAudio, .builtInSpeaker, .other: return "speaker.wave.2"
        }
    }

    private var audioOutputDetail: String {
        statusStore.status.audio.defaultOutput?.name ?? localized("No output device")
    }

    private var audioInputSymbol: String {
        statusStore.status.audio.defaultInput == nil ? "mic.slash" : "mic"
    }

    private var audioInputDetail: String {
        statusStore.status.audio.defaultInput?.name ?? localized("No input device")
    }

    private var audioInputState: String {
        guard let input = statusStore.status.audio.defaultInput else { return localized("Unavailable") }
        switch input.transport {
        case .builtIn: return localized("Built-in")
        case .bluetooth, .bluetoothLE: return localized("Bluetooth")
        case .usb: return localized("USB")
        case .hdmi, .displayPort: return localized("Display")
        case .airPlay: return localized("AirPlay")
        case .virtual: return localized("Virtual")
        case .other: return localized("Connected")
        }
    }

    private var audioOutputState: String {
        guard let output = statusStore.status.audio.defaultOutput else { return localized("Unavailable") }
        if output.transport.isBluetooth {
            return output.temporaryGlyph == .airPods ? localized("AirPods") : localized("Bluetooth")
        }
        switch output.transport {
        case .builtIn: return localized("Built-in")
        case .airPlay: return localized("AirPlay")
        case .usb: return localized("USB")
        case .hdmi, .displayPort: return localized("Display")
        case .virtual: return localized("Virtual")
        case .bluetooth, .bluetoothLE: return localized("Bluetooth")
        case .other: return localized("Connected")
        }
    }
}

struct BatteryStatusRow: View {
    let battery: BatteryStatus
    let showPercentage: Bool
    var showsDisclosure = false
    var timeEstimate: BatteryTimeEstimate = .unavailable

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(.primary.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(localized("Battery"))
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 8)
                    if let trailingValue {
                        Text(trailingValue)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 6) {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    if let secondaryDetail {
                        Spacer(minLength: 0)
                        Text(secondaryDetail)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }
            }

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .popoverCardBackground(cornerRadius: 11, fillOpacity: 0.045)
    }

    var trailingValue: String? {
        guard showPercentage, let percentage = battery.percentage else { return nil }
        return localized("%d%%", percentage)
    }

    var detail: String {
        guard battery.isAvailable else { return localized("No internal battery") }
        if battery.isFullyCharged { return localized("Fully charged") }
        if battery.isCharging { return localized("Charging") }
        if battery.isPluggedIn { return localized("Charging On Hold") }
        if battery.isLowPowerModeEnabled { return localized("Low Power Mode") }
        return localized("Using battery power")
    }

    var secondaryDetail: String? {
        guard battery.isAvailable else { return nil }
        switch timeEstimate {
        case .toFull(let minutes):
            return localized("%@ to full", BatteryTimeFormatter.duration(minutes: minutes))
        case .toEmpty(let minutes):
            return localized("%@ left", BatteryTimeFormatter.duration(minutes: minutes))
        case .calculating:
            return localized("Calculating…")
        case .unavailable:
            break
        }
        return battery.isPluggedIn ? localized("Using Adapter") : nil
    }

    var symbol: String {
        if battery.isFullyCharged { return "battery.100percent" }
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.percentage ?? 0 {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        default: return "battery.25percent"
        }
    }
}

#if DEBUG
private struct DebugStatusSimulatorView: View {
    let statusStore: SystemStatusStore
    @AppStorage(PreferenceKeys.batteryColorCoding) private var batteryColorCoding = false
    @ObservedObject private var adaptiveRingMonitor = AdaptiveRingMonitor.shared

    var body: some View {
        Menu {
            Menu("Simulate") {
                simulationControls
            }

            Menu("Diagnostics") {
                diagnosticItem("Laptop Ring Mode", value: laptopRingModeLabel)
                diagnosticItem("Charging session", value: chargingSessionLabel)
                diagnosticItem("Waiting for full charge", value: waitingForFullChargeLabel)
                diagnosticItem("Adaptive telemetry lease", value: adaptiveRingMonitor.monitoringOwnerCount > 0 ? "Active" : "Inactive")
                diagnosticItem("Adaptive monitor", value: adaptiveRingMonitor.isMonitoring ? "Running" : "Stopped")
                diagnosticItem("Adaptive source", value: adaptiveRingMonitor.debugTestSource.rawValue)
                diagnosticItem("Brightness", value: brightnessLabel)
                diagnosticItem("Adaptive metric", value: adaptiveRingMonitor.state.diagnosticLabel)
                diagnosticItem("Adaptive progress", value: adaptiveProgressLabel)
                diagnosticItem("Final ring target", value: finalRingOverrideLabel)
            }
        } label: {
            HStack {
                Label("Debug Simulator", systemImage: "hammer")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(debugSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .frame(minHeight: 26)
    }

    @ViewBuilder
    private var simulationControls: some View {
        Menu("Battery Level") {
            ForEach(DebugBatteryLevel.allCases) { level in
                Button(level.title) { statusStore.applyDebugBatteryLevel(level) }
            }
        }
        Menu("Battery Power") {
            ForEach(DebugPowerState.allCases) { powerState in
                Button(powerState.rawValue) { statusStore.applyDebugPowerState(powerState) }
            }
        }
        Menu("Low Power Mode") {
            ForEach(DebugLowPowerMode.allCases) { lowPowerMode in
                Button(lowPowerMode.rawValue) { statusStore.applyDebugLowPowerMode(lowPowerMode) }
            }
        }
        Menu("Battery Color Coding") {
            Button("Off") { batteryColorCoding = false }
            Button("On") { batteryColorCoding = true }
        }
        Menu("MacBook Adaptive Ring") {
            Button("Battery / Unplugged") {
                statusStore.applyDebugAdaptiveBatteryBaseline()
                adaptiveRingMonitor.clearDebugSyntheticInput()
            }
            Button("Charging") {
                scheduleAdaptiveChargingSimulation()
            }
            Divider()
            Button("Adaptive — Neutral") { scheduleAdaptive(.neutral) }
            Button("Adaptive — Brightness") { scheduleAdaptive(.brightness50) }
            Button("Adaptive — CPU") { scheduleAdaptive(.cpuHigh) }
            Button("Adaptive — Memory") { scheduleAdaptive(.memoryPressure) }
            Button("Adaptive — Thermal") { scheduleAdaptive(.thermalSerious) }
            Divider()
            Button("Use Live System State") {
                adaptiveRingMonitor.clearDebugSyntheticInput()
                statusStore.restoreLiveStatus()
            }
        }
        Menu("Network") {
            ForEach(DebugNetworkState.allCases) { networkState in
                Button(networkState.rawValue) { statusStore.applyDebugNetworkState(networkState) }
            }
        }
        Menu("Volume") {
            ForEach(DebugVolumeState.allCases) { volumeState in
                Button(volumeState.rawValue) { statusStore.applyDebugVolumeState(volumeState) }
            }
        }
        Menu("Audio Connection") {
            ForEach(DebugAudioDeviceState.allCases) { deviceState in
                Button(deviceState.rawValue) { statusStore.applyDebugAudioDeviceState(deviceState) }
            }
        }
        Divider()
        Button("Restore Live Data") { statusStore.restoreLiveStatus() }
    }

    private func diagnosticItem(_ title: String, value: String) -> some View {
        Button("\(title): \(value)") {}
            .disabled(true)
    }

    private var debugSummary: String {
        "\(laptopRingModeLabel) · \(adaptiveRingMonitor.debugTestSource.rawValue)"
    }

    private var laptopRingModeLabel: String {
        switch statusStore.laptopRingModeState.mode {
        case .battery: "Battery"
        case .adaptive: "Adaptive"
        }
    }

    private var chargingSessionLabel: String {
        guard let start = statusStore.laptopRingModeState.sessionStartPercentage,
              let target = statusStore.laptopRingModeState.targetPercentage
        else { return "None" }
        let waiting = statusStore.laptopRingModeState.isWaitingForFullChargeDelay ? " · waiting for full delay" : ""
        return "\(start)% → \(target)%\(waiting)"
    }

    private var waitingForFullChargeLabel: String {
        statusStore.laptopRingModeState.isWaitingForFullChargeDelay ? "Yes" : "No"
    }

    private var brightnessLabel: String {
        guard let availability = adaptiveRingMonitor.brightnessSnapshot?.availability else { return "Sampling…" }
        switch availability {
        case .available(let value): return String(format: "%.0f%%", value * 100)
        case .unavailable: return "Unavailable"
        }
    }

    private var adaptiveProgressLabel: String {
        let target = AdaptiveRingVisualTarget(state: adaptiveRingMonitor.state).progress
        return String(format: "%.1f%%", target * 100)
    }

    private var finalRingOverrideLabel: String {
        guard statusStore.usesAdaptiveRing else { return "Battery Ring" }
        let target = AdaptiveRingVisualTarget(state: adaptiveRingMonitor.state).progress
        return String(format: "%.1f%%", target * 100)
    }

    private func scheduleAdaptiveChargingSimulation() {
        Task { @MainActor in
            statusStore.applyDebugAdaptiveChargingBaseline()
            adaptiveRingMonitor.clearDebugSyntheticInput()
            adaptiveQALog("DEBUG controller prepared at 50%; visible Charging percentage preserved; awaiting 80% target")
        }
    }

    private func scheduleAdaptive(_ scenario: AdaptiveRingSyntheticScenario) {
        Task { @MainActor in
            await activateAdaptive(scenario)
        }
    }

    @MainActor
    private func activateAdaptive(_ scenario: AdaptiveRingSyntheticScenario) async {
        if statusStore.laptopRingModeState.mode == .adaptive {
            useAdaptiveSourceScenario(scenario)
            return
        }

        // Direct selection first lets the real Charging presentation settle.
        if statusStore.laptopRingModeState.targetPercentage != DebugBatteryLevel.eighty.rawValue
            || !statusStore.status.battery.isCharging {
            statusStore.applyDebugAdaptiveChargingBaseline()
            try? await Task.sleep(for: .seconds(BatteryChargingAnimationProfile.entranceDuration))
            guard !Task.isCancelled else { return }
        }

        useAdaptiveSourceScenario(scenario)
        await Task.yield()
        statusStore.reachDebugAdaptiveTarget()
        adaptiveQALog("DEBUG crossed controller target without publishing a synthetic battery jump for \(scenario.rawValue)")
    }

    private func useAdaptiveSourceScenario(_ scenario: AdaptiveRingSyntheticScenario) {
        let preference: PerformancePreference = scenario == .memoryPressure ? .memory : .automatic
        adaptiveRingMonitor.useDebugSyntheticInput(
            scenario.input,
            label: scenario.rawValue,
            preference: preference
        )
    }

    private func adaptiveQALog(_ message: String) {
        NSLog("%@", "[CbarDuo Adaptive QA] \(message)")
    }
}
#endif

/// Bluetooth on/off summary with a disclosure to Bluetooth settings.
private struct BluetoothSummaryRow: View {
    let bluetooth: BluetoothStatus

    var body: some View {
        HStack(spacing: 11) {
            BluetoothGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 8, height: 13)
                .frame(width: 28, height: 28)
                .background(.primary.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(localized("Bluetooth"))
                    .font(.system(size: 12.5, weight: .semibold))
                Text(state)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .contentShape(Rectangle())
    }

    private var state: String {
        guard bluetooth.isAvailable else { return localized("Unavailable") }
        return bluetooth.isPoweredOn ? localized("On") : localized("Off")
    }
}

/// A connected Bluetooth audio device, marked when it is the current output.
private struct BluetoothDeviceRow: View {
    let device: AudioDeviceStatus
    let isCurrentOutput: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.temporaryGlyph == .airPods ? "airpodspro" : "headphones")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(device.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if isCurrentOutput {
                Text(localized("Output"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SettingsStyle.accent)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .accessibilityElement(children: .combine)
    }
}
