// Adapted from Fader (https://github.com/pantafive/fader).
// Copyright (c) 2026 pantafive. MIT License — see THIRD_PARTY_NOTICES.md.

import AppKit
import CoreAudio
import os

/// Watches the HAL's audio process list and publishes the running apps
/// that can play sound. Helper processes (browser media children, Electron
/// renderers) group under their responsible application.
@MainActor
final class AudioProcessMonitor: ObservableObject {
    private static let logger = Logger(subsystem: "com.cojonesnaut.cbarduo", category: "AudioProcessMonitor")

    @Published private(set) var apps: [AudioApp] = []

    private var listListener: HALListener?
    private var pendingRefresh: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        installListListener()
        // Per-process IsRunningOutput flips do not reliably arrive, so the
        // playing state is polled. Reading a few dozen flags costs microseconds.
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2), tolerance: .milliseconds(500))
                } catch {
                    break
                }
                guard let self else { break }
                refresh()
            }
        }
        refresh()
    }

    /// Core Audio resets discard listeners and invalidate process object IDs.
    func recoverAfterServiceRestart() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        apps = []
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

        for objectID in objectIDs {
            guard let pid = try? objectID.readProcessPID() else { continue }
            let ownerPID = Self.responsiblePID(for: pid)
            guard let running = NSRunningApplication(processIdentifier: ownerPID)
                ?? NSRunningApplication(processIdentifier: pid),
                let bundleID = running.bundleIdentifier,
                bundleID != Bundle.main.bundleIdentifier
            else { continue }

            let key = running.processIdentifier
            var group = groups[key] ?? Group(app: running)
            group.objects.append(objectID)
            group.playing = group.playing || objectID.readProcessIsRunningOutput()
            group.recording = group.recording || objectID.readProcessIsRunningInput()
            groups[key] = group
        }

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
