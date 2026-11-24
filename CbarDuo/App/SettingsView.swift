import ServiceManagement
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case indicator
    case popover
    case desktopWidget
    case general
    #if DEBUG
    case debug
    #endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .indicator: localized("Indicator")
        case .popover: localized("Popover")
        case .desktopWidget: localized("Desktop Widget")
        case .general: localized("General")
        #if DEBUG
        case .debug: "Debug"
        #endif
        }
    }

    var symbol: String {
        switch self {
        case .indicator: "sparkles"
        case .popover: "list.bullet.rectangle.fill"
        case .desktopWidget: "macwindow"
        case .general: "gearshape.fill"
        #if DEBUG
        case .debug: "ladybug.fill"
        #endif
        }
    }

    var color: Color {
        switch self {
        case .indicator: .blue
        case .popover: Color(red: 0.25, green: 0.55, blue: 0.98)
        case .desktopWidget: .teal
        case .general: .gray
        #if DEBUG
        case .debug: .orange
        #endif
        }
    }
}

struct SettingsView: View {
    /// The app's live status, used by the Indicator preview. Nil falls back to sample data.
    var statusStore: SystemStatusStore?

    @AppStorage(PreferenceKeys.showBatteryPercentage) private var showBatteryPercentage = true
    @AppStorage(PreferenceKeys.animationsEnabled) private var animationsEnabled = true
    @AppStorage(PreferenceKeys.menuBarIconScale) private var menuBarIconScale = MenuBarIconSize.defaultScale
    @AppStorage(PreferenceKeys.batteryColorCoding) private var batteryColorCoding = false
    @AppStorage(PreferenceKeys.adaptiveRingPriority) private var adaptiveRingPriorityRaw = PerformancePreference.automatic.rawValue
    @AppStorage(PreferenceKeys.adaptiveRingColorCoding) private var adaptiveRingColorCoding = false
    @AppStorage(PreferenceKeys.openOnHover) private var openOnHover = false
    @AppStorage(PreferenceKeys.showInDock) private var showInDock = false
    @AppStorage(PreferenceKeys.showDesktopWidget) private var showDesktopWidget = false
    @AppStorage(PreferenceKeys.desktopWidgetCustomDots) private var desktopWidgetCustomDots = DesktopWidgetDotsSource.volume.rawValue
    @AppStorage(PreferenceKeys.desktopWidgetCustomCenter) private var desktopWidgetCustomCenter = DesktopWidgetCenterSource.network.rawValue
    @AppStorage(PreferenceKeys.desktopWidgetCustomRing) private var desktopWidgetCustomRing = DesktopWidgetRingSource.battery.rawValue
    @AppStorage(PreferenceKeys.desktopWidgetSize) private var desktopWidgetSize = DesktopWidgetSize.medium.rawValue
    @AppStorage(PreferenceKeys.showBatteryPercentageInMenuBar) private var showBatteryPercentageInMenuBar = false
    @AppStorage(PreferenceKeys.appLanguage) private var appLanguage = ""
    @AppStorage(PreferenceKeys.appearance) private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage(PreferenceKeys.iconThickness) private var iconThicknessRaw = IconThickness.regular.rawValue
    @AppStorage(PreferenceKeys.barSlot) private var barSlotRaw = IndicatorBarSlot.volume.rawValue
    @AppStorage(PreferenceKeys.popoverHiddenTabs) private var hiddenTabsRaw = ""
    @AppStorage(PreferenceKeys.barStyle) private var barStyleRaw = IndicatorBarStyle.dotted.rawValue
    @AppStorage(PreferenceKeys.barFill) private var barFillRaw = IndicatorBarFill.classic.rawValue
    @ObservedObject private var usageMonitor = SystemUsageMonitor.shared
    @ObservedObject private var updateController = UpdateController.shared
    @StateObject private var launchAtLogin = LaunchAtLoginService()
    @ObservedObject private var adaptiveRingMonitor = AdaptiveRingMonitor.shared
    @State private var page: SettingsPage
    private let deviceContextService = DeviceContextService()
    #if DEBUG
    @AppStorage(PreferenceKeys.simulateDesktopMac) private var simulateDesktopMac = false
    #endif

    init(statusStore: SystemStatusStore? = nil, initialPage: SettingsPage = .indicator) {
        self.statusStore = statusStore
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 640, idealWidth: 720, maxWidth: .infinity, minHeight: 460, idealHeight: 560, maxHeight: .infinity)
        .ignoresSafeArea()
        .focusRingsDisabled()
        .background(SettingsWindowConfigurator())
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            launchAtLogin.refresh()
            if showsAdaptiveRingSettings {
                adaptiveRingMonitor.setPreference(adaptiveRingPriority.wrappedValue)
            }
        }
        .onChange(of: adaptiveRingPriorityRaw) {
            if showsAdaptiveRingSettings {
                adaptiveRingMonitor.setPreference(adaptiveRingPriority.wrappedValue)
            }
        }
        .onChange(of: appearanceRaw) {
            AppAppearance.applyCurrent()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsPage.allCases) { item in
                SettingsSidebarItem(
                    symbol: item.symbol,
                    color: item.color,
                    title: item.title,
                    isSelected: page == item
                ) {
                    page = item
                }
            }
            Spacer(minLength: 16)
            SettingsSegmentedControl(
                selection: $appearanceRaw,
                options: AppAppearance.allCases.map { ($0.rawValue, $0.title) }
            )
            .accessibilityLabel(localized("Appearance"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 52)
        .padding(.bottom, 14)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(SettingsSidebarMaterial())
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if page == .indicator {
                indicatorPreview
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch page {
                    case .indicator: indicatorPage
                    case .popover: popoverPage
                    case .desktopWidget: desktopWidgetPage
                    case .general: generalPage
                    #if DEBUG
                    case .debug: debugPage
                    #endif
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, page == .indicator ? 20 : 44)
                .padding(.bottom, 24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsStyle.detailBackground)
    }

    // MARK: Indicator

    private var indicatorPreview: some View {
        HStack {
            Text(localized("Preview").uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 22) {
                if let statusStore {
                    LiveIndicatorPreviewTile(statusStore: statusStore, style: previewStyle, usageMonitor: usageMonitor)
                } else {
                    IndicatorPreviewTile(title: localized("Live"), status: Self.sampleStatus, style: previewStyle, barValue: sampleBarValue)
                }
                IndicatorPreviewTile(title: localized("Charging"), status: previewStatus(percentage: 64, pluggedIn: true), style: previewStyle, barValue: sampleBarValue)
                IndicatorPreviewTile(title: localized("Low"), status: previewStatus(percentage: 12, pluggedIn: false), style: previewStyle, barValue: sampleBarValue)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(SettingsStyle.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(SettingsStyle.cardBorder)
            )
            Spacer()
        }
        .padding(.leading, 24)
        .padding(.trailing, 24)
        .padding(.top, 40)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var indicatorPage: some View {
        SettingsSection(title: localized("Ring")) {
            SettingsToggleRow(
                symbol: "percent",
                color: .green,
                title: localized("Show Percentage"),
                subtitle: localized("Show the battery level above the menu bar icon."),
                isOn: $showBatteryPercentageInMenuBar
            )
            if showsBatteryRingSettings {
                SettingsRowDivider()
                SettingsToggleRow(
                    symbol: "paintpalette.fill",
                    color: .orange,
                    title: localized("Battery Color Coding"),
                    subtitle: localized("Yellow in Low Power Mode and red below 20%. The ring is always green on power."),
                    isOn: $batteryColorCoding
                )
            }
        }

        if showsAdaptiveRingSettings {
            SettingsSection(
                title: localized("Adaptive Ring"),
                footer: localized("Used only when multiple system conditions need attention. Critical conditions can still take priority.")
            ) {
                SettingsRow(symbol: "gauge.medium", color: .pink, title: localized("Adaptive Ring Priority")) {
                    Picker(localized("Adaptive Ring Priority"), selection: adaptiveRingPriority) {
                        ForEach(PerformancePreference.allCases, id: \.self) { preference in
                            Text(preference.localizedDisplayName).tag(preference)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                SettingsRowDivider()
                SettingsToggleRow(
                    symbol: "paintpalette.fill",
                    color: .orange,
                    title: localized("Adaptive Ring Color Coding"),
                    isOn: $adaptiveRingColorCoding
                )
            }
        }

        barSection

        SettingsSection(
            title: localized("Icon"),
            footer: localized("Choose a preset or fine-tune CbarDuo to better match your menu bar.")
        ) {
            SettingsRow(symbol: "line.3.horizontal", color: .blue, title: localized("Thickness")) {
                SettingsSegmentedControl(
                    selection: $iconThicknessRaw,
                    options: IconThickness.allCases.map { ($0.rawValue, $0.title) }
                )
                .accessibilityLabel(localized("Ring thickness"))
            }
            SettingsRowDivider()
            SettingsRow(symbol: "textformat.size", color: .indigo, title: localized("Icon Size")) {
                SettingsSegmentedControl(
                    selection: iconSizePreset,
                    options: [
                        (MenuBarIconSize.minimumScale, localized("Small")),
                        (MenuBarIconSize.defaultScale, localized("Default")),
                        (MenuBarIconSize.largeScale, localized("Large")),
                        (MenuBarIconSize.extraLargeScale, localized("Extra Large"))
                    ]
                )
                .accessibilityLabel(localized("Menu bar icon size"))
            }
            SettingsRowDivider()
            SettingsRow(symbol: "slider.horizontal.3", color: .orange, title: localized("Fine-tune")) {
                HStack(spacing: 10) {
                    Slider(
                        value: resolvedMenuBarIconScale,
                        in: MenuBarIconSize.minimumScale...MenuBarIconSize.maximumScale,
                        step: MenuBarIconSize.step
                    )
                    .tint(SettingsStyle.accent)
                    .frame(width: 170)
                    .accessibilityLabel(localized("Menu bar icon size"))
                    .accessibilityValue(iconScalePercentText)
                    Text(iconScalePercentText)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            SettingsRowDivider()
            SettingsToggleRow(
                symbol: "wand.and.stars",
                color: .purple,
                title: localized("Enable animations"),
                isOn: $animationsEnabled
            )
        }
    }

    // MARK: Bar

    private static let barTint = Color(red: 0.86, green: 0.28, blue: 0.86)

    @ViewBuilder
    private var barSection: some View {
        SettingsSection(
            title: localized("Bar"),
            footer: localized("The bar under the ring. Network Activity, Memory and Disk are measured only while chosen.")
        ) {
            SettingsRow(symbol: "circle.bottomhalf.filled", color: Self.barTint, title: localized("Slot")) {
                Picker(localized("Slot"), selection: $barSlotRaw) {
                    ForEach(IndicatorBarSlot.allCases, id: \.self) { slot in
                        Label(slot.title, systemImage: slot.symbol).tag(slot.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            SettingsRowDivider()
            SettingsRow(symbol: "paintbrush.pointed.fill", color: Self.barTint, title: localized("Style")) {
                BarOptionPicker(
                    selection: $barStyleRaw,
                    options: IndicatorBarStyle.allCases.map { style in
                        BarOptionPicker.Option(id: style.rawValue, title: style.title, style: style, fill: .classic)
                    }
                )
            }
            SettingsRowDivider()
            SettingsRow(symbol: "circle.lefthalf.filled", color: Self.barTint, title: localized("Fill Style")) {
                BarOptionPicker(
                    selection: $barFillRaw,
                    options: IndicatorBarFill.allCases.map { fill in
                        BarOptionPicker.Option(
                            id: fill.rawValue,
                            title: fill.title,
                            style: IndicatorBarStyle(rawValue: barStyleRaw) ?? .dotted,
                            fill: fill
                        )
                    }
                )
            }
        }
    }

    /// Bar shown in the sample preview tiles when the slot is not Volume.
    private var sampleBarValue: IndicatorBarValue? {
        (IndicatorBarSlot(rawValue: barSlotRaw) ?? .volume) == .volume ? nil : IndicatorBarValue(level: 0.62)
    }

    // MARK: Popover

    @ViewBuilder
    private var popoverPage: some View {
        SettingsSection(title: localized("Rows"), footer: localized("Choose which sections the popover shows.")) {
            ForEach(Array(PopoverTab.allCases.enumerated()), id: \.element) { index, tab in
                if index > 0 { SettingsRowDivider() }
                popoverRowToggle(tab)
            }
        }

        SettingsSection(title: localized("Content")) {
            SettingsToggleRow(
                symbol: "battery.100",
                color: .green,
                title: localized("Show battery percentage in popover"),
                isOn: $showBatteryPercentage
            )
        }

        SettingsSection(title: localized("Behavior")) {
            SettingsToggleRow(
                symbol: "cursorarrow.rays",
                color: .indigo,
                title: localized("Open on Hover"),
                subtitle: localized("Open CbarDuo when the pointer moves over the menu bar icon."),
                isOn: $openOnHover
            )
        }
    }

    private func popoverRowToggle(_ tab: PopoverTab) -> some View {
        let hidden = Set(hiddenTabsRaw.split(separator: ",").map(String.init))
        let isVisible = !hidden.contains(tab.rawValue)
        let isLastVisible = isVisible && PopoverTab.visible(hiddenRaw: hiddenTabsRaw) == [tab]
        return HStack(spacing: 12) {
            PopoverTabIcon(tab: tab, size: 14)
                .foregroundStyle(.secondary)
                .frame(width: SettingsStyle.tileSize)
            Text(tab.title)
                .font(.system(size: 13))
            Spacer(minLength: 12)
            Toggle(tab.title, isOn: Binding(
                get: { isVisible },
                set: { show in
                    var updated = hidden
                    if show { updated.remove(tab.rawValue) } else { updated.insert(tab.rawValue) }
                    hiddenTabsRaw = PopoverTab.allCases.map(\.rawValue).filter(updated.contains).joined(separator: ",")
                }
            ))
            .labelsHidden()
            .toggleStyle(SettingsSwitchStyle())
            .disabled(isLastVisible)
            .opacity(isLastVisible ? 0.45 : 1)
            .help(isLastVisible ? localized("At least one section stays visible.") : "")
        }
        .padding(.vertical, 8)
        .frame(minHeight: 40)
    }

    // MARK: Desktop Widget

    @ViewBuilder
    private var desktopWidgetPage: some View {
        SettingsSection(title: localized("Desktop Widget")) {
            SettingsToggleRow(
                symbol: "macwindow",
                color: .teal,
                title: localized("Show on Desktop"),
                subtitle: localized("Show CbarDuo on the desktop. Click it to switch modes, drag it to move it."),
                isOn: $showDesktopWidget
            )
            if showDesktopWidget {
                SettingsRowDivider()
                SettingsRow(symbol: "arrow.up.left.and.arrow.down.right", color: .orange, title: localized("Widget Size")) {
                    SettingsSegmentedControl(
                        selection: $desktopWidgetSize,
                        options: DesktopWidgetSize.allCases.map { ($0.rawValue, $0.title) }
                    )
                }
            }
        }

        if showDesktopWidget, DesktopWidgetMode.releasedModes.contains(.custom) {
            SettingsSection(title: localized("Custom Mode")) {
                SettingsRow(symbol: "circle.dashed", color: .green, title: localized("Custom Mode Ring")) {
                    menuPicker(localized("Custom Mode Ring"), selection: $desktopWidgetCustomRing) {
                        ForEach(DesktopWidgetRingSource.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                }
                SettingsRowDivider()
                SettingsRow(symbol: "circle.circle.fill", color: .blue, title: localized("Custom Mode Center")) {
                    menuPicker(localized("Custom Mode Center"), selection: $desktopWidgetCustomCenter) {
                        ForEach(DesktopWidgetCenterSource.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                }
                SettingsRowDivider()
                SettingsRow(symbol: "ellipsis", color: .pink, title: localized("Custom Mode Dots")) {
                    menuPicker(localized("Custom Mode Dots"), selection: $desktopWidgetCustomDots) {
                        ForEach(DesktopWidgetDotsSource.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                }
            }
        }
    }

    // MARK: General

    @ViewBuilder
    private var generalPage: some View {
        SettingsSection(title: localized("Startup")) {
            SettingsToggleRow(
                symbol: "power",
                color: .red,
                title: localized("Launch CbarDuo at login"),
                subtitle: launchAtLogin.requiresApproval
                    ? localized("Approval is required in System Settings → General → Login Items.")
                    : nil,
                isOn: Binding(get: { launchAtLogin.isEnabled }, set: launchAtLogin.setEnabled)
            )
            if let errorMessage = launchAtLogin.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.bottom, 10)
            }
            SettingsRowDivider()
            SettingsToggleRow(
                symbol: "dock.rectangle",
                color: .blue,
                title: localized("Show in Dock"),
                subtitle: localized("Show the CbarDuo icon in the Dock. Clicking it opens Settings."),
                isOn: $showInDock
            )
        }

        SettingsSection(title: localized("Language")) {
            SettingsRow(symbol: "globe", color: .blue, title: localized("Language")) {
                menuPicker(localized("Language"), selection: $appLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                }
            }
        }

        SettingsSection(title: localized("Updates")) {
            SettingsToggleRow(
                symbol: "arrow.triangle.2.circlepath",
                color: .green,
                title: localized("Automatically check for updates"),
                isOn: automaticUpdatesBinding
            )
            SettingsRowDivider()
            SettingsRow(symbol: "arrow.down.circle.fill", color: .blue, title: localized("Version %@", appVersion)) {
                Button(localized("Check for Updates…")) {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
            }
        }
    }

    #if DEBUG
    private var debugPage: some View {
        Form {
            if !MarketingCaptureMode.isEnabled {
                DebugPerformanceDiagnosticsView()
                DebugDuoGlyphTuningView()
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 700)
    }
    #endif

    // MARK: - Helpers

    private func menuPicker<Value: Hashable, Options: View>(
        _ title: String,
        selection: Binding<Value>,
        @ViewBuilder options: () -> Options
    ) -> some View {
        Picker(title, selection: selection, content: options)
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
    }

    private var previewStyle: IndicatorPreviewStyle {
        IndicatorPreviewStyle(
            showPercentage: showBatteryPercentageInMenuBar,
            colorCoding: batteryColorCoding
        )
    }

    private func previewStatus(percentage: Int, pluggedIn: Bool) -> SystemStatus {
        var status = statusStore?.status ?? Self.sampleStatus
        status.battery = BatteryStatus(
            percentage: percentage,
            isCharging: pluggedIn,
            isPluggedIn: pluggedIn,
            isFullyCharged: false,
            isAvailable: true
        )
        return status
    }

    static let sampleStatus = SystemStatus(
        battery: BatteryStatus(percentage: 80, isCharging: false, isPluggedIn: false, isFullyCharged: false, isAvailable: true),
        network: NetworkStatus(isAvailable: true, isConnected: true, transport: .wifi, interfaceName: "en0", isWiFiPoweredOn: true, ssid: nil, rssi: -45),
        audio: AudioStatus(
            isAvailable: true,
            defaultOutput: AudioDeviceStatus(uid: "preview", name: "Speakers", transport: .builtIn, isAlive: true),
            volume: OutputVolumeStatus(level: 0.6, isMuted: false, isSettable: true),
            connectedBluetoothOutputs: []
        ),
        bluetooth: BluetoothStatus(isAvailable: true, isPoweredOn: true)
    )

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var iconScalePercentText: String {
        localized("%d%%", Int((MenuBarIconSize.resolve(menuBarIconScale) * 100).rounded()))
    }

    private var iconSizePreset: Binding<Double> {
        Binding(
            get: { MenuBarIconSize.resolve(menuBarIconScale) },
            set: { menuBarIconScale = MenuBarIconSize.resolve($0) }
        )
    }

    private var automaticUpdatesBinding: Binding<Bool> {
        Binding(
            get: { updateController.automaticallyChecksForUpdates },
            set: { updateController.automaticallyChecksForUpdates = $0 }
        )
    }

    private var adaptiveRingPriority: Binding<PerformancePreference> {
        Binding(
            get: { PerformancePreference(rawValue: adaptiveRingPriorityRaw) ?? .automatic },
            set: { adaptiveRingPriorityRaw = $0.rawValue }
        )
    }

    private var resolvedMenuBarIconScale: Binding<Double> {
        Binding(
            get: { MenuBarIconSize.resolve(menuBarIconScale) },
            set: { menuBarIconScale = MenuBarIconSize.resolve($0) }
        )
    }

    private var showsAdaptiveRingSettings: Bool {
        #if DEBUG
        AdaptiveRingSettingsEligibility.isEligible(
            for: deviceContextService.current(),
            simulateDesktop: simulateDesktopMac
        )
        #else
        AdaptiveRingSettingsEligibility.isEligible(for: deviceContextService.current())
        #endif
    }

    private var showsBatteryRingSettings: Bool {
        #if DEBUG
        deviceContextService.current(simulateDesktop: simulateDesktopMac).ringBehavior == .batteryRing
        #else
        deviceContextService.current().ringBehavior == .batteryRing
        #endif
    }
}

// MARK: - Indicator preview

struct IndicatorPreviewStyle: Equatable {
    var showPercentage: Bool
    var colorCoding: Bool
}

struct IndicatorPreviewTile: View {
    let title: String
    let status: SystemStatus
    let style: IndicatorPreviewStyle
    var barValue: IndicatorBarValue?

    var body: some View {
        VStack(spacing: 4) {
            DuoGlyphView(
                status: status,
                metrics: DuoGlyphMetrics.standard.sized(42),
                animationsEnabled: false,
                batteryColorCodingEnabled: style.colorCoding,
                showBatteryPercentage: style.showPercentage,
                barValue: barValue
            )
            .frame(width: 42, height: 42)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// The "Live" preview tile, following the app's real status as it changes.
private struct LiveIndicatorPreviewTile: View {
    @ObservedObject var statusStore: SystemStatusStore
    let style: IndicatorPreviewStyle
    @ObservedObject var usageMonitor: SystemUsageMonitor
    @AppStorage(PreferenceKeys.barSlot) private var barSlotRaw = IndicatorBarSlot.volume.rawValue

    var body: some View {
        IndicatorPreviewTile(
            title: localized("Live"),
            status: statusStore.status,
            style: style,
            barValue: IndicatorBarValue.make(
                slot: IndicatorBarSlot(rawValue: barSlotRaw) ?? .volume,
                networkSpeed: statusStore.networkSpeed,
                memoryUsed: usageMonitor.memoryUsed,
                diskUsed: usageMonitor.diskUsed
            )
        )
    }
}
