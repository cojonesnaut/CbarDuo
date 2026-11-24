import SwiftUI

/// Output or input devices, laid out like Fader: a card with the current
/// device (accent icon, bold name, checkmark) and its level slider, then the
/// other devices as a plain list where one click switches to that device.
struct AudioDevicePanel<Slider: View>: View {
    let title: String
    let current: AudioDeviceStatus?
    let devices: [AudioDeviceStatus]
    let isInput: Bool
    let emptyText: String
    let failureText: String
    let onSelect: (String) -> Bool
    let onOpenSoundSettings: () -> Void
    @ViewBuilder let slider: Slider

    @State private var switchFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(PopoverFont.title)
                    .accessibilityAddTraits(.isHeader)

                if let current {
                    HStack(spacing: 10) {
                        AudioDeviceIcon(device: current, isInput: isInput)
                            .foregroundStyle(SettingsStyle.accent)
                            .frame(width: 20)
                        Text(current.name)
                            .font(PopoverFont.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(SettingsStyle.accent)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isSelected)
                } else {
                    Text(emptyText)
                        .font(PopoverFont.detail)
                        .foregroundStyle(.secondary)
                }

                slider
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PopoverCardBackground())

            VStack(alignment: .leading, spacing: 0) {
                ForEach(otherDevices) { device in
                    Button {
                        switchFailed = !onSelect(device.uid)
                    } label: {
                        HStack(spacing: 10) {
                            AudioDeviceIcon(device: device, isInput: isInput)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(device.name)
                                .font(PopoverFont.body)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if switchFailed {
                    Text(failureText)
                        .font(PopoverFont.detail)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }

                Button(action: onOpenSoundSettings) {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape")
                            .font(PopoverFont.listIcon)
                            .frame(width: 20)
                        Text(localized("Sound Settings…"))
                            .font(PopoverFont.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: current?.uid) { switchFailed = false }
    }

    private var otherDevices: [AudioDeviceStatus] {
        devices.filter { $0.uid != current?.uid }
    }
}

/// Icon for a device by how it connects, like Fader: laptop for built-in,
/// plug for USB, waveform for virtual devices, display, headphones, etc.
struct AudioDeviceIcon: View {
    let device: AudioDeviceStatus
    let isInput: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(PopoverFont.listIcon)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch device.transport {
        case .builtIn: return "laptopcomputer"
        case .usb: return isInput ? "mic" : "cable.connector"
        case .virtual: return "waveform"
        case .hdmi, .displayPort: return "display"
        case .airPlay: return "airplayaudio"
        case .bluetooth, .bluetoothLE:
            if device.category == .airPods { return "airpodspro" }
            if device.category == .headphones || isInput { return "headphones" }
            return "hifispeaker"
        case .other: return isInput ? "mic" : "speaker.wave.2"
        }
    }
}

/// Thick Fader / Control Center style level slider: a white fill with the
/// device glyph inside and a round knob at its end.
struct FaderSlider: View {
    let level: Double
    var isMuted = false
    let symbol: String
    let onChange: (Double) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }
    /// Clicking the glyph (for example to mute); nil makes it part of the track.
    var onIconTap: (() -> Void)?

    @State private var isDragging = false
    /// The finger's value while dragging. The slider shows this rather than
    /// the level read back from the device, so it tracks the pointer 1:1 even
    /// when the device reports slightly different (stepped) values.
    @State private var dragLevel: Double?
    private let height: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let travel = max(width - height, 1)
            let clamped = CGFloat(min(max(dragLevel ?? level, 0), 1))
            let fillWidth = height + clamped * travel
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isMuted ? 0.55 : 1))
                    .frame(width: fillWidth)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 0.5)
                    .frame(width: height, height: height)
                    .offset(x: fillWidth - height)
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.65))
                    .frame(width: height + 8, height: height)
            }
            .compositingGroup()
            // Direct drags stay 1:1; changes from elsewhere (volume keys,
            // Control Center) glide in.
            .animation(isDragging ? nil : .easeOut(duration: 0.12), value: level)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let raw = (value.location.x - height / 2) / travel
                        let newLevel = Double(min(max(raw, 0), 1))
                        guard newLevel != dragLevel else { return }
                        dragLevel = newLevel
                        onChange(newLevel)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragLevel = nil
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: height)
        .overlay(alignment: .leading) {
            if let onIconTap {
                Button(action: onIconTap) {
                    Color.clear
                        .frame(width: height + 8, height: height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(level + 0.1, 1))
            case .decrement: onChange(max(level - 0.1, 0))
            @unknown default: break
            }
        }
    }
}
