import SwiftUI

/// The gimbal's settings, as one `Section` for the Settings pane's `Form`.
/// Drop it in with `GimbalSettingsSection()`; it carries its own header and
/// footer, in the style of `CameraInspectorView`.
///
/// Nothing here is a launch default: these are the same `Preferences` keys
/// the Dashboard's control bar binds, so the style toggle in the bar and this
/// picker are two views of one value, live in both directions.
struct GimbalSettingsSection: View {
    @AppStorage(Preferences.gimbalControlStyle) private var controlStyle = GimbalControlStyle.joystick
    @AppStorage(Preferences.gimbalPanSpeed) private var panSpeedCap = 0.5
    @AppStorage(Preferences.gimbalTiltSpeed) private var tiltSpeedCap = 0.5
    @AppStorage(Preferences.gimbalSpeedLinked) private var speedsLinked = true

    private var speeds: LinkedGimbalSpeeds {
        LinkedGimbalSpeeds(pan: $panSpeedCap, tilt: $tiltSpeedCap, linked: $speedsLinked)
    }

    var body: some View {
        Section {
            Picker("Control", selection: $controlStyle) {
                ForEach(GimbalControlStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            Toggle("Link Pan and Tilt Maximums", isOn: speeds.link)
            speedRow("Max Pan Speed", value: speeds.pan,
                     byte: GimbalSpeedCaps.speedByte(panSpeedCap, of: UVCTransport.maxPanSpeed))
            speedRow("Max Tilt Speed", value: speeds.tilt,
                     byte: GimbalSpeedCaps.speedByte(tiltSpeedCap, of: UVCTransport.maxTiltSpeed))
        } header: {
            Text("Gimbal")
        } footer: {
            Text("""
                 A full joystick deflection reaches the maximum speed; the \
                 D-pad, having no analog range, always drives at it. The \
                 numbers are the speed values sent to the camera, which \
                 accepts 0–30 for pan and 0–20 for tilt.
                 """)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func speedRow(_ title: String, value: Binding<Double>, byte: UInt8) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: 0.05...1.0)
                    .controlSize(.small)
                    .frame(minWidth: 110)
                Text("\(byte)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .trailing)
            }
        }
        .accessibilityLabel(title)
    }
}

#Preview {
    // Wrapped the way SettingsView composes it — a grouped Form. A bare
    // Section outside a Form renders nothing like the shipping layout.
    Form {
        GimbalSettingsSection()
    }
    .formStyle(.grouped)
    .frame(width: 420)
}
