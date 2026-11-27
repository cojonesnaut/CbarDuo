import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private static let hoverCloseDelay: TimeInterval = 0.25
    /// How long the popover's content stays loaded after it closes.
    static let popoverContentReleaseDelay: TimeInterval = 45

    private let statusItem: NSStatusItem
    private var popover: NSPopover?
    private var popoverResignObserver: NSObjectProtocol?
    private var hostingController: NSHostingController<StatusPopoverView>?
    private var isClosing = false
    private var closeWorkItem: DispatchWorkItem?
    private var contentReleaseWorkItem: DispatchWorkItem?
    private var isPanelVisible: Bool { popover?.isShown == true && !isClosing }
    private var popoverWindow: NSWindow? { popover?.contentViewController?.view.window }
    private let statusStore: SystemStatusStore
    private var hostingView: PassthroughHostingView<DuoStatusView>?
    private var popoverHoverTracker: PopoverHoverTracker?
    private var escapeKeyMonitor: Any?
    private var lengthAnimationTimer: Timer?
    private var pendingHoverClose: DispatchWorkItem?
    private var hoverCloseGeneration: UInt = 0
    private var defaultsObserver: NSObjectProtocol?
    private var applicationResignObserver: NSObjectProtocol?
    private var globalOutsideClickMonitor: Any?
    private var hoverInteraction = HoverPopoverInteraction(
        isEnabled: UserDefaults.standard.bool(forKey: PreferenceKeys.openOnHover)
    )
    private var isInvalidated = false

    init(statusStore: SystemStatusStore) {
        self.statusStore = statusStore
        statusItem = NSStatusBar.system.statusItem(
            withLength: MenuBarIconSize.statusItemWidth(for: MenuBarIconSize.storedScale())
        )
        super.init()
        configureStatusItem()
        configurePopover()
        observeHoverPreference()
        observeApplicationActivity()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        statusItem.isVisible = true
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = nil
        button.title = ""
        button.toolTip = localized("CbarDuo system status")

        let rootView = DuoStatusView(statusStore: statusStore) { [weak self] width in
            self?.setStatusItemLength(width)
        }
        let hostingView = PassthroughHostingView(rootView: rootView)
        hostingView.onHoverChanged = { [weak self] isInside in
            guard let self else { return }
            let commands = isInside
                ? self.hoverInteraction.statusItemEntered()
                : self.hoverInteraction.statusItemExited()
            self.perform(commands)
        }
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: button.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        self.hostingView = hostingView
    }

    private func configurePopover() {
        let hoverTracker = PopoverHoverTracker()
        hoverTracker.onHoverChanged = { [weak self] isInside in
            guard let self else { return }
            let commands = isInside
                ? self.hoverInteraction.popoverEntered()
                : self.hoverInteraction.popoverExited()
            self.perform(commands)
        }
        popoverHoverTracker = hoverTracker
    }

    /// Builds the popover and its SwiftUI content if they are not loaded.
    /// Both are created on demand rather than at launch: a hidden popover
    /// would otherwise keep its whole view tree in memory and keep
    /// re-rendering it on every status change.
    private func loadPopoverContentIfNeeded() {
        cancelPopoverContentRelease()
        guard popover == nil || hostingController == nil else { return }
        // A real NSPopover: the system draws its Liquid Glass, arrow and shadow.
        // Closing stays with this controller (outside clicks, hover, other
        // windows), so AppKit's own transient behavior is off.
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        let hostingController = NSHostingController(
            rootView: StatusPopoverView(
                statusStore: statusStore,
                onClose: { [weak self] in
                    self?.closePopoverFromContent()
                }
            )
        )
        // Report the SwiftUI size only as the preferred content size. The
        // default options also pin the view to its intrinsic size, which fights
        // the popover while it animates between tabs of different heights.
        hostingController.sizingOptions = [.preferredContentSize]
        popoverHoverTracker?.install(on: hostingController.view)
        // The SwiftUI controller is the popover's content directly, so AppKit
        // resizes (and animates) the popover from its preferred content size.
        popover.contentViewController = hostingController
        self.popover = popover
        self.hostingController = hostingController
    }

    /// Frees the popover and its content a while after it closes. Reopening
    /// within the grace period reuses the loaded content, so quick
    /// open/close cycles stay instant.
    private func schedulePopoverContentRelease() {
        cancelPopoverContentRelease()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.releasePopoverContent() }
        }
        contentReleaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.popoverContentReleaseDelay,
            execute: workItem
        )
    }

    private func cancelPopoverContentRelease() {
        contentReleaseWorkItem?.cancel()
        contentReleaseWorkItem = nil
    }

    private func releasePopoverContent() {
        contentReleaseWorkItem = nil
        guard !isInvalidated, let popover, !popover.isShown else { return }
        if let view = hostingController?.view, let area = popoverHoverTracker?.trackingArea {
            view.removeTrackingArea(area)
        }
        // Drop the whole popover, not only its content: NSPopover keeps the
        // last content view in its private window after
        // `contentViewController` is cleared, so the view tree would survive.
        popover.delegate = nil
        popover.contentViewController = nil
        self.popover = nil
        hostingController = nil
        MemoryRelief.releaseFreedPages()
    }

    @objc private func togglePopover() {
        // Never trust the state machine over what is actually on screen.
        if isPanelVisible {
            hoverInteraction.popoverShownExternally()
        }
        perform(hoverInteraction.statusItemClicked())
    }

    private func showPopover() {
        guard !isPanelVisible, statusItem.button != nil else { return }
        loadPopoverContentIfNeeded()
        guard let popover, let hostingController, let button = statusItem.button else { return }

        NSApp.activate(ignoringOtherApps: true)
        hostingController.view.layoutSubtreeIfNeeded()
        closeWorkItem?.cancel()
        closeWorkItem = nil
        isClosing = false
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverWindow?.makeKey()
        button.highlight(true)
        observePopoverResignKey()
        installEscapeKeyMonitor()
        PopoverPresentationState.shared.show()
        installOutsideClickMonitors()
        statusStore.setPopoverActive(true)
        // Let the accessory app finish activating and the popover become key
        // before asking CoreLocation to present its native authorization UI.
        DispatchQueue.main.async { [weak self] in
            self?.statusStore.requestWiFiSSIDAccess(trigger: .popoverOpened)
        }
    }

    private func closePopover() {
        guard isPanelVisible else {
            removeOutsideClickMonitors()
            return
        }
        dismissPanel()
    }

    // MARK: - Outside-click dismissal

    private static let outsideClickMask: NSEvent.EventTypeMask = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown
    ]

    /// Dismisses the popover when the user presses on another app or on another
    /// menu bar icon. Global monitors only observe events sent to other
    /// processes, so clicks inside CbarDuo (the popover, its Wi-Fi password
    /// sheet, and the status item itself) never reach this handler. Mouse
    /// events need no Accessibility permission.
    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()

        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: Self.outsideClickMask
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleOutsideClick()
            }
        }
    }

    private func removeOutsideClickMonitors() {
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }
    }

    private func handleOutsideClick() {
        guard !isInvalidated, isPanelVisible else { return }
        cancelHoverClose()
        _ = hoverInteraction.clickedOutside()
        // `close()` rather than `performClose(_:)`: an attached sheet or the
        // nested Nearby Networks popover can make `performClose` a no-op, which
        // would leave the popover on screen while the state says it is closed.
        dismissPanel()
    }

    /// True while a sheet (Wi-Fi password) or a nested popover (Nearby
    /// Networks) is attached to the popover window.
    private var popoverHasAttachedWindows: Bool {
        guard let window = popoverWindow else { return false }
        if window.attachedSheet != nil { return true }
        return window.childWindows?.contains(where: { $0.isVisible }) ?? false
    }

    private func closePopoverFromContent() {
        perform(hoverInteraction.popoverClosedExternally())
        closePopover()
    }

    private func perform(_ commands: [HoverPopoverCommand]) {
        guard !isInvalidated else { return }
        for command in commands {
            switch command {
            case .open:
                showPopover()
            case .close:
                closePopover()
            case .scheduleClose:
                scheduleHoverClose()
            case .cancelClose:
                cancelHoverClose()
            }
        }
    }

    private func scheduleHoverClose() {
        cancelHoverClose()
        let generation = hoverCloseGeneration
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.hoverCloseGeneration == generation else { return }
                self.pendingHoverClose = nil
                if self.popoverHasAttachedWindows {
                    self.perform(self.hoverInteraction.popoverEngaged())
                    return
                }
                self.perform(self.hoverInteraction.closeDelayElapsed())
            }
        }
        pendingHoverClose = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.hoverCloseDelay,
            execute: workItem
        )
    }

    private func cancelHoverClose() {
        hoverCloseGeneration &+= 1
        pendingHoverClose?.cancel()
        pendingHoverClose = nil
    }

    private func observeHoverPreference() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let enabled = UserDefaults.standard.bool(forKey: PreferenceKeys.openOnHover)
                let commands = self.hoverInteraction.setEnabled(enabled)
                self.perform(commands)
            }
        }
    }

    private func observeApplicationActivity() {
        applicationResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.perform(self.hoverInteraction.applicationResignedActive())
            }
        }
    }

    #if DEBUG
    func setPopoverVisibleForMarketingCapture(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        if visible {
            showPopover()
        } else {
            closePopoverFromContent()
        }
    }
    #endif

    private func setStatusItemLength(_ requestedLength: CGFloat) {
        guard !isInvalidated else { return }
        // A zero, negative, or non-finite width would leave a running app with
        // no visible menu bar item, so fall back to the stored icon size.
        let targetLength = requestedLength.isFinite && requestedLength > 1
            ? requestedLength
            : MenuBarIconSize.statusItemWidth(for: MenuBarIconSize.storedScale())
        lengthAnimationTimer?.invalidate()

        guard UserDefaults.standard.bool(forKey: PreferenceKeys.animationsEnabled) else {
            statusItem.length = targetLength
            return
        }

        let startLength = statusItem.length
        guard abs(startLength - targetLength) > 0.5 else { return }
        let startDate = Date()
        let duration: TimeInterval = 0.34

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }

                let elapsed = Date().timeIntervalSince(startDate)
                let progress = min(max(elapsed / duration, 0), 1)
                let eased = 1 - pow(1 - progress, 3)
                self.statusItem.length = startLength + (targetLength - startLength) * eased

                if progress >= 1 {
                    self.statusItem.length = targetLength
                    timer.invalidate()
                    self.lengthAnimationTimer = nil
                }
            }
        }
        lengthAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        removeOutsideClickMonitors()
        cancelHoverClose()
        cancelPopoverContentRelease()
        lengthAnimationTimer?.invalidate()
        lengthAnimationTimer = nil
        removePopoverResignObserver()
        popover?.close()
        popover = nil
        hostingController = nil
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        if let applicationResignObserver {
            NotificationCenter.default.removeObserver(applicationResignObserver)
            self.applicationResignObserver = nil
        }
        removeEscapeKeyMonitor()
        popoverHoverTracker = nil
        hostingView?.removeFromSuperview()
        hostingView = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    deinit {
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
        }
        pendingHoverClose?.cancel()
        contentReleaseWorkItem?.cancel()
        lengthAnimationTimer?.invalidate()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let applicationResignObserver {
            NotificationCenter.default.removeObserver(applicationResignObserver)
        }
        if let popoverResignObserver {
            NotificationCenter.default.removeObserver(popoverResignObserver)
        }
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
        }
        if !isInvalidated {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
}

extension MenuBarController {
    /// Closes the popover and runs the cleanup; `popoverDidClose` finishes it.
    func dismissPanel() {
        guard isPanelVisible else { return }
        closeWorkItem?.cancel()
        closeWorkItem = nil
        // Set before anything else so re-entrant close requests (for example
        // from `perform` below) see the popover as already closing.
        isClosing = true
        removeOutsideClickMonitors()
        removeEscapeKeyMonitor()
        statusStore.setPopoverActive(false)
        perform(hoverInteraction.popoverClosedExternally())
        PopoverPresentationState.shared.hide()
        statusItem.button?.highlight(false)
        // `close()` rather than `performClose(_:)`: an attached sheet or the
        // nested Nearby Networks popover can make `performClose` a no-op.
        popover?.close()
    }

    /// Key moving to another window of this app (for example Settings) closes
    /// the popover, like `.transient` would.
    func observePopoverResignKey() {
        removePopoverResignObserver()
        guard let window = popoverWindow else { return }
        popoverResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panelDidResignKey() }
        }
    }

    /// Escape pressed in the popover closes it. Only events for the popover's
    /// own window are taken, so Escape in the Wi-Fi password sheet still
    /// cancels the sheet.
    func installEscapeKeyMonitor() {
        removeEscapeKeyMonitor()
        weak var popoverWindow = self.popoverWindow
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let popoverWindow, event.window === popoverWindow else { return event }
            Task { @MainActor in self?.handleOutsideClick() }
            return nil
        }
    }

    func removeEscapeKeyMonitor() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
    }

    func removePopoverResignObserver() {
        if let popoverResignObserver {
            NotificationCenter.default.removeObserver(popoverResignObserver)
            self.popoverResignObserver = nil
        }
    }

    /// Stands in for `.transient`: closes when key moves to another window of
    /// this app (for example Settings). Clicks in other apps are handled by the
    /// global outside-click monitor.
    func panelDidResignKey() {
        #if DEBUG
        if MarketingCaptureMode.isEnabled { return }
        #endif
        guard !hoverInteraction.isEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPanelVisible, !self.isInvalidated else { return }
            // A click on the status item is handled by its own action.
            guard !self.hoverInteraction.isPointerOverStatusItem else { return }
            guard NSApp.isActive,
                  self.popoverWindow?.isKeyWindow != true,
                  !self.popoverHasAttachedWindows else { return }
            self.handleOutsideClick()
        }
    }
}

extension MenuBarController: NSPopoverDelegate {
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.popoverFinishedClosing() }
    }

    private func popoverFinishedClosing() {
        let closedByController = isClosing
        isClosing = false
        removePopoverResignObserver()
        statusItem.button?.highlight(false)
        removeEscapeKeyMonitor()
        if !isInvalidated { schedulePopoverContentRelease() }
        guard !closedByController, !isInvalidated else { return }
        removeOutsideClickMonitors()
        statusStore.setPopoverActive(false)
        perform(hoverInteraction.popoverClosedExternally())
        PopoverPresentationState.shared.hide()
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Reports the pointer entering and leaving the popover content through a
/// tracking area on the content view itself (no wrapper view, which would
/// break the popover's automatic sizing).
final class PopoverHoverTracker: NSResponder {
    var onHoverChanged: ((Bool) -> Void)?
    private(set) var trackingArea: NSTrackingArea?

    func install(on view: NSView) {
        if let trackingArea {
            view.removeTrackingArea(trackingArea)
        }
        // `.inVisibleRect` keeps the area matched to the view as the popover
        // resizes, so it never needs to be rebuilt.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}
