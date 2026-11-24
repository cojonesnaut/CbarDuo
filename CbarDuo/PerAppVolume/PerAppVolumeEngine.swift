// Adapted from Fader (https://github.com/pantafive/fader).
// Copyright (c) 2026 pantafive. MIT License — see THIRD_PARTY_NOTICES.md.

import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os

/// Binds the process list to per-app volume state and owns one ProcessTap per
/// adjusted app. Apps at unity gain stay untouched — no tap, no processing,
/// bit-perfect native playback.
@MainActor
final class PerAppVolumeEngine: ObservableObject {
    static let shared = PerAppVolumeEngine()
    private static let logger = Logger(subsystem: "com.cojonesnaut.cbarduo", category: "PerAppVolume")

    let processMonitor = AudioProcessMonitor()

    /// Set when tap creation fails with a permission-shaped error.
    @Published private(set) var needsAudioCapturePermission = false
    @Published private(set) var volumes: [String: AppVolume] = [:]
    /// Output devices apps can be routed to.
    @Published private(set) var outputDevices: [TapOutputDevice] = []

    private var taps: [String: ProcessTap] = [:]
    /// One volume control per pinned-and-present device, keyed by UID.
    private var routeVolumes: [String: DeviceVolumeController] = [:]
    private let store = VolumeStore()
    private var isStarted = false
    private var defaultDeviceListener: HALListener?
    private var deviceListListener: HALListener?
    private var serviceRestartListener: HALListener?
    private var saveTask: Task<Void, Never>?
    private var rebuildPending: Set<String> = []
    private var tapFailures = 0
    private var retryTask: Task<Void, Never>?
    private var neutralTeardownTasks: [String: Task<Void, Never>] = [:]
    private var wakeResyncTask: Task<Void, Never>?
    private var appsSubscription: AnyCancellable?
    private var powerObservers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        volumes = store.load()
        outputDevices = TapOutputDevice.currentOutputs()
        processMonitor.start()
        installHALListeners()
        appsSubscription = processMonitor.$apps
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncTaps() }
            }
        observePower()
        syncTaps()
    }

    func volume(for app: AudioApp) -> AppVolume {
        volumes[app.bundleID] ?? AppVolume()
    }

    func setVolume(_ value: Float, for app: AudioApp) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        entry.volume = max(0, min(1, value))
        apply(entry, to: app)
    }

    func toggleMute(for app: AudioApp) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        entry.isMuted.toggle()
        apply(entry, to: app)
    }

    /// Drops the tap for an app, restoring its native audio path.
    func reset(_ app: AudioApp) {
        volumes[app.bundleID] = nil
        store.save(volumes)
        releaseTap(app.bundleID)
        syncRouteVolumes()
    }

    /// Ramps every attenuated tap back to unity before teardown so apps don't
    /// jump to full volume (with a click) when CbarDuo quits.
    func fadeOutAndStop() {
        let fading = taps.values.filter { !$0.isMuted && $0.volume < 0.999 }
        if !fading.isEmpty {
            for tap in fading { tap.volume = 1.0 }
            Thread.sleep(forTimeInterval: 0.15)
        }
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
    }

    // MARK: - HAL events

    private func installHALListeners() {
        // Each aggregate is pinned to a concrete device; rebuild on change.
        defaultDeviceListener = AudioObjectID.system.listen(kAudioHardwarePropertyDefaultOutputDevice) {
            Task { @MainActor [weak self] in self?.reconcileTapRouting() }
        }
        deviceListListener = AudioObjectID.system.listen(kAudioHardwarePropertyDevices) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                outputDevices = TapOutputDevice.currentOutputs()
                reconcileTapRouting()
            }
        }
        serviceRestartListener = AudioObjectID.system.listen(kAudioHardwarePropertyServiceRestarted) {
            Task { @MainActor [weak self] in self?.recoverAfterAudioServiceRestart() }
        }
    }

    private func recoverAfterAudioServiceRestart() {
        Self.logger.warning("Core Audio service restarted; rebuilding per-app volume state")
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
        rebuildPending.removeAll()
        routeVolumes.removeAll()
        processMonitor.recoverAfterServiceRestart()
        installHALListeners()
        outputDevices = TapOutputDevice.currentOutputs()
        syncTaps()
        recoverAfterWake()
    }

    private func observePower() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.recoverAfterWake() }
        })
        powerObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in
                self?.wakeResyncTask?.cancel()
                self?.wakeResyncTask = nil
            }
        })
    }

    /// Drivers often publish their final object IDs shortly after wake, so a
    /// second pass follows the immediate one.
    private func recoverAfterWake() {
        wakeResyncTask?.cancel()
        resync()
        wakeResyncTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(250))
            } catch {
                return
            }
            guard let self else { return }
            wakeResyncTask = nil
            resync()
        }
    }

    private func resync() {
        outputDevices = TapOutputDevice.currentOutputs()
        processMonitor.refresh()
        reconcileTapRouting()
    }

    // MARK: - Applying volumes

    private func apply(_ entry: AppVolume, to app: AudioApp) {
        volumes[app.bundleID] = entry
        scheduleSave()

        if let tap = taps[app.bundleID] {
            let routed = !entry.outputDeviceUIDs.isEmpty
            tap.volume = routed ? 1 : entry.volume
            tap.isMuted = routed ? false : entry.isMuted
            scheduleNeutralTeardown(for: app.bundleID)
        } else if !entry.isNeutral {
            installTap(for: app, entry: entry)
        }
    }

    /// Back at 100% the tap must go, so the app's audio stops flowing through
    /// CbarDuo's process. Waits for the slider to settle.
    private func scheduleNeutralTeardown(for bundleID: String) {
        neutralTeardownTasks.removeValue(forKey: bundleID)?.cancel()
        guard volumes[bundleID]?.isNeutral == true else { return }
        neutralTeardownTasks[bundleID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, volumes[bundleID]?.isNeutral == true else { return }
            neutralTeardownTasks[bundleID] = nil
            volumes[bundleID] = nil
            releaseTap(bundleID)
        }
    }

    /// Slider drags apply per pixel; coalesce the UserDefaults write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            store.save(volumes)
        }
    }

    // MARK: - Taps

    /// Ensures every non-neutral running app has a live tap covering its
    /// current process set, and every gone app's tap is released.
    func syncTaps() {
        let apps = AudioApp.coalescedByBundleID(processMonitor.apps)
        let running = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })

        for (bundleID, tap) in taps {
            guard let app = running[bundleID], let entry = volumes[bundleID] else {
                releaseTap(bundleID)
                continue
            }
            // A browser that spawns a new media child needs the tap rebuilt.
            if tap.processObjectIDs != app.objectIDs || rebuildPending.contains(bundleID) {
                installTap(for: app, entry: entry)
            } else {
                tap.updatePlaybackState(isPlaying: app.isPlaying)
            }
        }
        for (bundleID, entry) in volumes where !entry.isNeutral {
            guard taps[bundleID] == nil, let app = running[bundleID] else { continue }
            installTap(for: app, entry: entry)
        }
        syncRouteVolumes()
    }

    /// Make-before-break: the replacement starts before the old tap goes, so
    /// the app is never left on its native output at full volume in between.
    private func installTap(for app: AudioApp, entry: AppVolume) {
        let bundleID = app.bundleID
        let old = taps[bundleID]
        do {
            let tap = try makeTap(for: app, entry: entry, replacing: old)
            taps[bundleID] = tap
            if tap.isHeld {
                rebuildPending.insert(bundleID)
                scheduleTapRetry()
            } else {
                rebuildPending.remove(bundleID)
                tapFailures = 0
                needsAudioCapturePermission = false
            }
            if let old { retire(old) }
        } catch {
            Self.logger.error("Tap failed for \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if let halError = error as? HALError, halError.isPermissionDenied {
                needsAudioCapturePermission = true
                if old == nil { return }
            }
            scheduleTapRetry()
            guard let old else { return }
            switch TapRebuildPolicy.brokenTap(isAlive: old.isAlive, isHeld: old.isHeld) {
            case .hold:
                rebuildPending.insert(bundleID)
                old.holdSilent()
            case .keepPlaying:
                break
            }
        }
    }

    private func makeTap(for app: AudioApp, entry: AppVolume, replacing old: ProcessTap?) throws -> ProcessTap {
        let outputs = try resolvedOutputs(for: entry)
        // A routed app's loudness lives on its devices' own volume controls,
        // so its tap renders transparent.
        let routed = !entry.outputDeviceUIDs.isEmpty
        let tap = ProcessTap(
            processObjectIDs: app.objectIDs,
            volume: routed ? 1.0 : entry.volume,
            isMuted: routed ? false : entry.isMuted
        )
        if old != nil { tap.rampInFromSilence() }
        do {
            try tap.activate(outputs: outputs)
        } catch {
            guard old == nil, tap.tapID.isValid else { throw error }
            ProcessTap.logger.error("Tap activation failed; holding output silent: \(error.localizedDescription)")
            tap.holdSilent()
        }
        if tap.isHeld, old != nil {
            throw HALError.operation(kAudioDeviceUnsupportedFormatError, "verify aggregate stream format")
        }
        let bundleID = app.bundleID
        tap.onOutputResumed = { [weak self] in self?.processMonitor.refresh() }
        tap.onBroken = { [weak self] in
            self?.rebuildPending.insert(bundleID)
            self?.syncTaps()
        }
        tap.updatePlaybackState(isPlaying: app.isPlaying)
        return tap
    }

    /// Fades the replaced tap out under the new one's fade-in, then tears it down.
    private func retire(_ tap: ProcessTap) {
        tap.volume = 0
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            tap.invalidate()
        }
    }

    /// Releasing restores the app's native output at full volume.
    private func releaseTap(_ bundleID: String) {
        taps.removeValue(forKey: bundleID)?.invalidate()
        rebuildPending.remove(bundleID)
    }

    /// No HAL event is guaranteed to follow a failure, so retry on a timer.
    private func scheduleTapRetry() {
        guard retryTask == nil else { return }
        tapFailures += 1
        let delay = TapRebuildPolicy.retryDelay(afterFailures: tapFailures)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            retryTask = nil
            syncTaps()
        }
    }

    /// Rebuilds only the taps that no longer play where they should.
    private func reconcileTapRouting() {
        for (bundleID, tap) in taps {
            guard let entry = volumes[bundleID] else { continue }
            if let desired = try? resolvedOutputs(for: entry),
               desired == tap.activatedOutputs, tap.isAlive { continue }
            rebuildPending.insert(bundleID)
        }
        syncTaps()
    }

    /// The devices an app's tap plays through: its pinned route when present,
    /// otherwise the system default. A wired/built-in device clocks the
    /// aggregate in preference to Bluetooth.
    private func resolvedOutputs(for entry: AppVolume) throws -> [ProcessTap.Output] {
        let present = entry.outputDeviceUIDs.compactMap { uid in outputDevices.first { $0.uid == uid } }
        guard let clock = present.first(where: { !$0.isBluetooth }) ?? present.first else {
            let id = try AudioObjectID.readDefaultOutputDevice()
            return try [ProcessTap.Output(uid: id.readDeviceUID(), id: id)]
        }
        return ([clock] + present.filter { $0.uid != clock.uid })
            .map { ProcessTap.Output(uid: $0.uid, id: $0.id) }
    }

    // MARK: - Per-app routing

    func routeUIDs(for app: AudioApp) -> [String] {
        volumes[app.bundleID]?.outputDeviceUIDs ?? []
    }

    func routeDeviceName(forUID uid: String) -> String? {
        outputDevices.first { $0.uid == uid }?.name
    }

    func routeVolume(forUID uid: String) -> DeviceVolumeController? {
        routeVolumes[uid]
    }

    /// Adds an output device to the ones this app plays through. Routing
    /// forces a tap even at unity gain (the tap is the route).
    func route(_ app: AudioApp, to uid: String) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        guard !entry.outputDeviceUIDs.contains(uid) else { return }
        entry.outputDeviceUIDs.append(uid)
        volumes[app.bundleID] = entry
        scheduleSave()
        rebuildTap(for: app, entry: entry)
    }

    func unroute(_ app: AudioApp, from uid: String) {
        guard var entry = volumes[app.bundleID], entry.outputDeviceUIDs.contains(uid) else { return }
        entry.outputDeviceUIDs.removeAll { $0 == uid }
        volumes[app.bundleID] = entry.isNeutral ? nil : entry
        scheduleSave()
        rebuildTap(for: app, entry: entry)
    }

    /// Returns the app to the default output.
    func clearRoute(for app: AudioApp) {
        guard var entry = volumes[app.bundleID], !entry.outputDeviceUIDs.isEmpty else { return }
        entry.outputDeviceUIDs.removeAll()
        volumes[app.bundleID] = entry.isNeutral ? nil : entry
        scheduleSave()
        rebuildTap(for: app, entry: entry)
    }

    private func rebuildTap(for app: AudioApp, entry: AppVolume) {
        if entry.isNeutral {
            releaseTap(app.bundleID)
        } else {
            installTap(for: app, entry: entry)
        }
        syncRouteVolumes()
    }

    /// Keeps one DeviceVolumeController per pinned-and-present device.
    private func syncRouteVolumes() {
        let pinned = Set(volumes.values.flatMap(\.outputDeviceUIDs))
            .filter { uid in outputDevices.contains { $0.uid == uid } }
        for uid in routeVolumes.keys where !pinned.contains(uid) {
            routeVolumes[uid] = nil
        }
        for uid in pinned where routeVolumes[uid] == nil {
            guard let device = outputDevices.first(where: { $0.uid == uid }) else { continue }
            routeVolumes[uid] = DeviceVolumeController(deviceID: device.id)
        }
        objectWillChange.send()
    }
}

/// A routed device's own volume, for the slider under a routed app.
@MainActor
final class DeviceVolumeController: ObservableObject {
    let deviceID: AudioDeviceID
    @Published private(set) var volume: Float = 1
    @Published private(set) var isMuted = false
    @Published private(set) var canSetVolume = false
    @Published private(set) var canMute = false

    private var listeners: [HALListener] = []
    private lazy var writer = VolumeWriteCoalescer(label: "com.cojonesnaut.cbarduo.route-volume") { [weak self] in
        Task { @MainActor in self?.readBack() }
    }

    init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
        canSetVolume = deviceID.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        canMute = deviceID.isSettable(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        listeners = [
            deviceID.listen(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput) {
                Task { @MainActor [weak self] in self?.readBack() }
            },
            deviceID.listen(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) {
                Task { @MainActor [weak self] in self?.readBack() }
            },
        ]
        readBack()
    }

    func setVolume(_ value: Float) {
        guard canSetVolume else { return }
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        volume = max(0, min(1, value))
        writer.submit(.init(device: deviceID, addresses: [address], level: volume))
    }

    func toggleMute() {
        guard canMute else { return }
        try? deviceID.write(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, value: UInt32(isMuted ? 0 : 1))
        readBack()
    }

    private func readBack() {
        var value: Float32 = 1
        if (try? deviceID.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                               scope: kAudioDevicePropertyScopeOutput, into: &value)) != nil {
            volume = value
        }
        var muted: UInt32 = 0
        if (try? deviceID.read(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, into: &muted)) != nil {
            isMuted = muted != 0
        }
    }
}
