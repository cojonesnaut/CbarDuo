enum PreferenceKeys {
    static let showBatteryPercentage = "showBatteryPercentage"
    static let animationsEnabled = "animationsEnabled"
    static let menuBarIconScale = MenuBarIconSize.preferenceKey
    static let batteryColorCoding = "batteryColorCoding"
    static let adaptiveRingPriority = "adaptiveRingPriority"
    static let adaptiveRingColorCoding = "adaptiveRingColorCoding"
    static let openOnHover = "cbarDuo.openOnHover"
    static let showInDock = "cbarDuo.showInDock"
    static let showBatteryPercentageInMenuBar = "showBatteryPercentageInMenuBar"
    static let appLanguage = "cbarDuo.appLanguage"
    static let showDesktopWidget = "cbarDuo.showDesktopWidget"
    static let desktopWidgetMode = "cbarDuo.desktopWidget.mode"
    static let desktopWidgetCustomDots = "cbarDuo.desktopWidget.customDots"
    static let desktopWidgetCustomCenter = "cbarDuo.desktopWidget.customCenter"
    static let desktopWidgetCustomRing = "cbarDuo.desktopWidget.customRing"
    static let desktopWidgetSize = "cbarDuo.desktopWidget.size"
    static let desktopWidgetFrameX = "cbarDuo.desktopWidget.frameX"
    static let desktopWidgetFrameY = "cbarDuo.desktopWidget.frameY"
    static let liquidGlassEnabled = "cbarDuo.liquidGlassEnabled"

    #if DEBUG
    static let simulateDesktopMac = "debug.simulateDesktopMac"
    #endif
}
