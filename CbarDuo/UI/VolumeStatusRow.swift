import SwiftUI

struct VolumeStatusRow: View {
    let volume: OutputVolumeStatus
    let hasOutputDevice: Bool
    let playbackDeviceIdentifier: String?
    let onSetVolume: (Double) -> Bool
    let onSetMuted: (Bool) -> Bool

    @State private var feedbackInteraction = VolumeFeedbackInteraction()

    var body: some View {
        // Fader-style thick slider; clicking the speaker glyph mutes/unmutes.
        if volume.isSettable, let level = volume.level {
            FaderSlider(
                level: level,
                isMuted: volume.isMuted,
                symbol: speakerSymbol,
                onChange: handleUserVolumeChange,
                onEditingChanged: handleSliderEditingChanged,
                onIconTap: volume.isMuteSettable ? handleUserMuteChange : nil
            )
            .help(volume.isMuted ? localized("Unmute") : localized("Mute"))
            .accessibilityLabel(localized("Output volume"))
            .accessibilityValue(stateText)
        } else {
            Text(hasOutputDevice ? localized("Controlled by device") : localized("Volume unavailable"))
                .font(PopoverFont.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        }
    }

    private var speakerSymbol: String {
        guard !volume.isMuted, let level = volume.level, level > 0 else { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var stateText: String {
        if volume.isMuted { return localized("Muted") }
        return volume.percentage.map { localized("%d%%", $0) } ?? "—"
    }

    private func handleUserVolumeChange(_ level: Double) {
        beginSliderInteractionIfNeeded()
        var interaction = feedbackInteraction
        guard feedbackInteraction.allowsVolumeUpdates else {
            interaction.recordVolumeUpdate(
                previousStatus: volume,
                requestedLevel: level,
                writeSucceeded: false
            )
            $feedbackInteraction.wrappedValue = interaction
            return
        }

        let writeSucceeded = onSetVolume(level)
        interaction.recordVolumeUpdate(
            previousStatus: volume,
            requestedLevel: level,
            writeSucceeded: writeSucceeded
        )
        $feedbackInteraction.wrappedValue = interaction
    }

    private func handleSliderEditingChanged(_ isEditing: Bool) {
        if isEditing {
            beginSliderInteractionIfNeeded()
            return
        }
        var interaction = feedbackInteraction
        guard interaction.endEditing() else {
            $feedbackInteraction.wrappedValue = interaction
            return
        }
        $feedbackInteraction.wrappedValue = interaction
        VolumeFeedbackSound.play(on: playbackDeviceIdentifier)
    }

    private func beginSliderInteractionIfNeeded() {
        var interaction = feedbackInteraction
        interaction.beginEditing(previousStatus: volume) {
            onSetMuted(false)
        }
        $feedbackInteraction.wrappedValue = interaction
    }

    private func handleUserMuteChange() {
        let writeSucceeded = onSetMuted(!volume.isMuted)
        var interaction = feedbackInteraction
        guard interaction.shouldPlayForUnmute(
            previousStatus: volume,
            writeSucceeded: writeSucceeded
        ) else {
            $feedbackInteraction.wrappedValue = interaction
            return
        }
        $feedbackInteraction.wrappedValue = interaction

        VolumeFeedbackSound.play(on: playbackDeviceIdentifier)
    }
}
