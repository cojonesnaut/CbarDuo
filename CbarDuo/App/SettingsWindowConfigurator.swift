import AppKit
import SwiftUI

/// The window policy every regular CbarDuo window should have. SwiftUI's
/// Settings scene creates its window fixed to the content size: no
/// resizable flag, and content size limits that clamp resizing even if the
/// flag is added. Both have to be lifted, and AppDelegate re-applies this
/// whenever a non-panel window becomes key in case the scene's layout
/// pass strips it again.
enum SettingsWindowPolicy {
    static func configure(_ window: NSWindow) {
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.miniaturizable)
        window.minSize = SettingsPresenter.minimumSize
        window.contentMinSize = SettingsPresenter.minimumSize
        window.contentMaxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        // The decisive part: SettingsView observes live objects
        // (AdaptiveRingMonitor), so the scene re-renders on its own while
        // the window sits open — and every render makes the hosting
        // controller push the view's preferred content size back into the
        // window, silently re-locking it. That is why resizing worked
        // briefly after opening (and once per resize) and then died.
        // Empty sizingOptions stops the controller from pushing sizes at
        // all; the frame minimums above remain the only floor.
        if let hosting = window.contentViewController as? NSHostingController<SettingsView> {
            hosting.sizingOptions = []
            applyChrome(to: window)
        }
    }

    /// No visible title: the sidebar runs under the traffic lights. Re-applied with the
    /// rest of the policy because SwiftUI can restore a visible title on re-render.
    static func applyChrome(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
    }
}

/// Owns the app's real Settings window, created and managed by hand.
///
/// The SwiftUI Settings scene cannot be used for this window: its scene
/// machinery re-asserts the window's style mask after the view's frequent
/// re-renders (SettingsView observes AdaptiveRingMonitor), silently
/// stripping `.resizable` — visibly, the green traffic-light button
/// disappears a little while after the window opens and resizing dies
/// with it. Policy re-application from outside could never win that
/// fight reliably, so the window the app actually presents is this one;
/// the declared Settings scene remains only as structural plumbing.
@MainActor
enum SettingsPresenter {
    static let minimumSize = NSSize(width: 640, height: 460)
    static let defaultSize = NSSize(width: 720, height: 580)

    /// The app's live status, handed to the Indicator preview. Set once at launch.
    static weak var statusStore: SystemStatusStore?
    private static var window: NSWindow?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(statusStore: statusStore))
        let window = NSWindow(contentViewController: hosting)
        window.title = localized("CbarDuo Settings")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        SettingsWindowPolicy.applyChrome(to: window)
        window.isMovableByWindowBackground = true
        window.minSize = minimumSize
        window.isReleasedWhenClosed = false
        window.setContentSize(defaultSize)
        if !window.setFrameUsingName("CbarDuoSettingsWindowV2") {
            window.center()
        }
        window.setFrameAutosaveName("CbarDuoSettingsWindowV2")
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}

/// Applies the policy from inside the Settings view as a first pass (the
/// AppDelegate observer is the persistent one). The configuration must
/// happen when the view actually enters the window
/// (`viewDidMoveToWindow`): configuring from `makeNSView` races window
/// assignment and silently no-ops.
struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView {
        ConfiguratorView()
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.configure()
    }

    final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        func configure() {
            guard let window else { return }
            SettingsWindowPolicy.configure(window)
        }
    }
}
