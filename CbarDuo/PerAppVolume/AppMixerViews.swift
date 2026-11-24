// Adapted from Fader (https://github.com/pantafive/fader).
// Copyright (c) 2026 pantafive. MIT License — see THIRD_PARTY_NOTICES.md.

import AppKit
import SwiftUI

/// Per-app volume under the output devices: playing apps (and any app with a
/// saved level) with their own sliders, like Fader's mixer.
struct AppMixerSection: View {
    @ObservedObject private var engine = PerAppVolumeEngine.shared
    @ObservedObject private var monitor = PerAppVolumeEngine.shared.processMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if engine.needsAudioCapturePermission {
                AudioCapturePermissionBanner()
            }
            let apps = mixerApps
            if apps.isEmpty {
                MixerEmptyState(symbol: "speaker.slash", text: localized("Nothing is playing"))
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(apps) { app in
                            AppMixerRow(app: app, engine: engine)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 280)
            }
        }
    }

    /// Apps audible now, plus silent ones the user has adjusted — hiding those
    /// would strand their saved level.
    private var mixerApps: [AudioApp] {
        monitor.apps.filter { $0.isPlaying || !engine.volume(for: $0).isNeutral }
    }
}

/// Apps currently using the microphone (indicator only: Core Audio offers no
/// per-app input gain).
struct RecordingAppsSection: View {
    @ObservedObject private var monitor = PerAppVolumeEngine.shared.processMonitor

    var body: some View {
        let apps = monitor.apps.filter(\.isRecording)
        VStack(alignment: .leading, spacing: 6) {
            if apps.isEmpty {
                MixerEmptyState(symbol: "mic.slash", text: localized("Nothing is using the microphone"))
            } else {
                ForEach(apps) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(app.name)
                            .font(PopoverFont.body.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "mic.fill")
                            .font(PopoverFont.listIcon)
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 4)
                    .frame(height: 26)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// One mixer row: icon, name, level, and a slider (or, for an app routed to
/// specific devices, a card with one slider per device).
private struct AppMixerRow: View {
    let app: AudioApp
    @ObservedObject var engine: PerAppVolumeEngine

    var body: some View {
        let entry = engine.volume(for: app)
        let routes = engine.routeUIDs(for: app)
        let dim: Double = app.isPlaying ? 1 : 0.5

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(app.name)
                    .font(PopoverFont.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if routes.isEmpty {
                    Text(entry.isMuted ? localized("Muted") : localized("%d%%", Int((entry.volume * 100).rounded())))
                        .font(PopoverFont.detail)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Menu {
                    menuItems(routes: routes)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(PopoverFont.listIcon)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(localized("Options"))
                .accessibilityLabel(localized("Options"))
            }
            .opacity(dim)

            if routes.isEmpty {
                FaderSlider(
                    level: Double(entry.volume),
                    isMuted: entry.isMuted,
                    symbol: sliderSymbol(entry),
                    onChange: { engine.setVolume(Float($0), for: app) },
                    onIconTap: { engine.toggleMute(for: app) }
                )
                .opacity((entry.isMuted ? 0.55 : 1) * dim)
                .accessibilityLabel(app.name)
                .accessibilityValue(entry.isMuted ? localized("Muted") : localized("%d%%", Int((entry.volume * 100).rounded())))
            } else {
                routeCard(routes)
            }
        }
        .padding(.horizontal, 4)
        .contextMenu { menuItems(routes: routes) }
    }

    @ViewBuilder
    private func menuItems(routes: [String]) -> some View {
        Button(localized("Reset to 100%")) { engine.reset(app) }
        Menu(localized("Play On")) {
            ForEach(engine.outputDevices) { device in
                Toggle(device.name, isOn: Binding(
                    get: { routes.contains(device.uid) },
                    set: { on in
                        if on { engine.route(app, to: device.uid) } else { engine.unroute(app, from: device.uid) }
                    }
                ))
            }
        }
        if !routes.isEmpty {
            Button(localized("Play on Default Output")) { engine.clearRoute(for: app) }
        }
    }

    /// The devices this app is pinned to, each with its own volume slider.
    private func routeCard(_ uids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(uids, id: \.self) { uid in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(PopoverFont.accessory)
                        Text(engine.routeDeviceName(forUID: uid) ?? localized("Unavailable"))
                            .font(PopoverFont.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Button {
                            engine.unroute(app, from: uid)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(PopoverFont.listIcon)
                        }
                        .buttonStyle(.plain)
                        .help(localized("Stop playing to this device"))
                        .accessibilityLabel(localized("Stop playing to this device"))
                    }
                    .foregroundStyle(SettingsStyle.accent)
                    if let volume = engine.routeVolume(forUID: uid) {
                        RouteDeviceSlider(controller: volume)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func sliderSymbol(_ entry: AppVolume) -> String {
        if entry.isMuted { return "speaker.slash.fill" }
        switch entry.volume {
        case 0: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// A routed device's own volume; dimmed and frozen when the device has none.
private struct RouteDeviceSlider: View {
    @ObservedObject var controller: DeviceVolumeController

    var body: some View {
        FaderSlider(
            level: Double(controller.volume),
            isMuted: controller.isMuted,
            symbol: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill",
            onChange: { controller.setVolume(Float($0)) },
            onIconTap: controller.canMute ? { controller.toggleMute() } : nil
        )
        .disabled(!controller.canSetVolume)
        .opacity(controller.canSetVolume ? 1 : 0.4)
    }
}

private struct MixerEmptyState: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18))
            Text(text)
                .font(PopoverFont.body)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// Shown when macOS blocks audio capture, which per-app volume needs.
private struct AudioCapturePermissionBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(localized("Allow CbarDuo to adjust app volumes"), systemImage: "exclamationmark.triangle.fill")
                .font(PopoverFont.body.weight(.semibold))
                .foregroundStyle(.orange)
            Text(localized("macOS needs your permission for CbarDuo to process app audio. Audio never leaves your Mac."))
                .font(PopoverFont.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(localized("Open Privacy Settings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(PopoverFont.body)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
