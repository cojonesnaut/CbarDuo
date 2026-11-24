// Adapted from Fader (https://github.com/pantafive/fader).
// Copyright (c) 2026 pantafive. MIT License — see THIRD_PARTY_NOTICES.md.

import AppKit
import CoreAudio
import os

/// Watches the HAL's audio process list and publishes the running apps
/// that can play sound. Helper processes (browser media children, Electron
/// renderers) group under their responsible application.
///
/// Reading a process's playing/recording state is a synchronous call into
/// coreaudiod, so polling is scoped to what is needed: every process while
/// the Volume or Mic tab is on screen, only the apps with a custom volume
/// while it is not, and none at all when no app has one. App launches and
/// quits arrive through the process-list listener either way.
@MainActor
final class AudioProcessMonitor: ObservableObject {
    private static let logger = Logger(subsystem: "com.cojonesnaut.cbarduo", category: "AudioProcessMonitor")
    static let pollInterval: Duration = .seconds(2)

    @Published private(set) var apps: [AudioApp] = []

    private var listListener: HALListener?
    private var pendingRefresh: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var isStarted = false

    /// Mixer lists (Volume and Mic tabs) currently on screen.
    private var visibleViews = 0
    /// Apps whose playing state matters while no list is visible.
    private var trackedBundleIDs: Set<String> = []

    /// A process object's PID never changes, nor does a PID's owner while it lives.
    private var pidByObject: [AudioObjectID: pid_t] = [:]
    private var ownerByPID: [pid_t: NSRunningApplication] = [:]

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installListListener()
        refresh()
        updatePolling()
    }

    /// A mixer list appeared: read every process now and keep it current.
    func viewAppeared() {
        visibleViews += 1
        if visibleViews == 1 {
            refresh()
            updatePolling()
        }
    }

    func viewDisappeared() {
        visibleViews = max(visibleViews - 1, 0)
        if visibleViews == 0 { updatePolling() }
    }

    /// The engine's apps with a custom volume (or a live tap).
    func setTrackedBundleIDs(_ bundleIDs: Set<String>) {
        guard bundleIDs != trackedBundleIDs else { return }
        trackedBundleIDs = bundleIDs
        updatePolling()
    }

    nonisolated static func needsPolling(visibleViews: Int, trackedApps: Int) -> Bool {
        visibleViews > 0 || trackedApps > 0
    }

    private var readsEveryProcess: Bool { visibleViews > 0 }

    private func updatePolling() {
        let needed = isStarted && Self.needsPolling(visibleViews: visibleViews, trackedApps: trackedBundleIDs.count)
        if !needed {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        // Per-process IsRunningOutput flips do not reliably arrive, so the
        // playing state is polled while someone needs it.
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.pollInterval, tolerance: .milliseconds(500))
                } catch {
                    break
                }
                guard let self else { break }
                refresh()
            }
        }
    }

    /// Core Audio resets discard listeners and invalidate process object IDs.
    func recoverAfterServiceRestart() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        apps = []
        pidByObject = [:]
        ownerByPID = [:]
        installListListener()
        refresh()
    }

    deinit {
        pollTask?.cancel()
        pendingRefresh?.cancel()
    }

    private func installListListener() {
        listListener = AudioObjectID.system.listen(kAudioHardwarePropertyProcessObjectList) {
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
    }

    /// Coalesces listener bursts (one per process and per state flip).
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        guard let objectIDs = try? AudioObjectID.readProcessList() else {
            Self.logger.error("Failed to read HAL process list")
            return
        }

        struct Group {
            let app: NSRunningApplication
            var objects: [AudioObjectID] = []
            var playing = false
            var recording = false
        }
        var groups: [pid_t: Group] = [:]
        let readAll = readsEveryProcess
        let currentObjects = Set(objectIDs)
        pidByObject = pidByObject.filter { currentObjects.contains($0.key) }

        for objectID in objectIDs {
            guard let pid = cachedPID(of: objectID),
                  let running = owner(of: pid),
                  let bundleID = running.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier
            else { continue }

            let key = running.processIdentifier
            var group = groups[key] ?? Group(app: running)
            group.objects.append(objectID)
            if readAll || trackedBundleIDs.contains(bundleID) {
                group.playing = group.playing || objectID.readProcessIsRunningOutput()
                // Recording is only shown in the Mic tab.
                if readAll {
                    group.recording = group.recording || objectID.readProcessIsRunningInput()
                }
            }
            groups[key] = group
        }
        let livePIDs = Set(pidByObject.values)
        ownerByPID = ownerByPID.filter { livePIDs.contains($0.key) }

        var nextApps = groups.compactMap { pid, group -> AudioApp? in
            // Regular apps always; agents and helpers only while they play or record.
            guard group.app.activationPolicy == .regular || group.playing || group.recording
            else { return nil }
            return AudioApp(
                id: pid,
                bundleID: group.app.bundleIdentifier ?? "",
                name: group.app.localizedName ?? group.app.bundleIdentifier ?? "pid \(pid)",
                objectIDs: group.objects.sorted(),
                isPlaying: group.playing,
                isRecording: group.recording
            )
        }
        nextApps = AudioApp.coalescedByBundleID(nextApps)

        // Playing apps first, then alphabetical.
        nextApps.sort {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if nextApps != apps {
            apps = nextApps
        }
    }

    private func cachedPID(of objectID: AudioObjectID) -> pid_t? {
        if let pid = pidByObject[objectID] { return pid }
        guard let pid = try? objectID.readProcessPID() else { return nil }
        pidByObject[objectID] = pid
        return pid
    }

    /// The app responsible for a process (helpers map to their parent app).
    private func owner(of pid: pid_t) -> NSRunningApplication? {
        if let cached = ownerByPID[pid] { return cached }
        let ownerPID = Self.responsiblePID(for: pid)
        // A miss is not cached: an app still launching registers moments later.
        guard let app = NSRunningApplication(processIdentifier: ownerPID) ?? NSRunningApplication(processIdentifier: pid)
        else { return nil }
        ownerByPID[pid] = app
        return app
    }

    // MARK: - Responsible process lookup

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` maps helper processes to
    /// the app that spawned them (the attribution TCC uses). Not in a public
    /// header but stable since macOS 10.14; without it the lookup degrades to
    /// per-helper attribution.
    private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let function = responsiblePIDFunction else { return pid }
        let owner = function(pid)
        return owner > 0 ? owner : pid
    }
}
