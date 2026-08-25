import SwiftUI

/// The direct-manipulation strip under the viewfinder: the gimbal control
/// (joystick or pad, the user's choice) with its center button, the per-axis
/// speed ceilings, and zoom. Everything disables together while no Link is
/// connected.
struct CameraControlBar: View {
    @Bindable var model: CameraControlsModel

    /// The control style and the two ceilings are preferences, not model
    /// state: the Settings pane offers the same three keys, so both surfaces
    /// bind `Preferences` and neither owns them. The defaults here are only a
    /// formality — `Preferences.registerDefaults()` has already put a value
    /// behind every key by the time this view exists.
    @AppStorage(Preferences.gimbalControlStyle) private var controlStyle = GimbalControlStyle.joystick
    @AppStorage(Preferences.gimbalPanSpeed) private var panSpeedCap = 0.5
    @AppStorage(Preferences.gimbalTiltSpeed) private var tiltSpeedCap = 0.5
    @AppStorage(Preferences.gimbalSpeedLinked) private var speedsLinked = true

    /// What the chain link does is defined once, in LinkedGimbalSpeeds, so
    /// this bar and the Settings section cannot drift apart on it.
    private var speeds: LinkedGimbalSpeeds {
        LinkedGimbalSpeeds(pan: $panSpeedCap, tilt: $tiltSpeedCap, linked: $speedsLinked)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            gimbalControls
            Divider()
                .frame(height: 96)
            speedControls
            Divider()
                .frame(height: 96)
            zoomControls
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .disabled(!model.isReady)
    }

    /// The joystick is the default because it is analog; the pad stays for the
    /// single precise nudge, which is the one thing a joystick is worse at.
    private var gimbalControls: some View {
        VStack(spacing: 8) {
            Picker("Gimbal Control", selection: $controlStyle) {
                ForEach(GimbalControlStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Switch between the analog joystick and the directional pad")

            switch controlStyle {
            case .joystick:
                HStack(spacing: 12) {
                    GimbalJoystickWell(model: model)
                    // The pad carries the center button in its middle; the
                    // well's middle is the puck's home, so it sits alongside.
                    GimbalCenterButton(model: model)
                }
            case .pad:
                GimbalPad(model: model)
            }
        }
    }

    /// Ceilings, not speeds: a full joystick deflection reaches the value set
    /// here and anything less is a proportion of it, while the pad — having no
    /// analog range — always drives at it. The integers underneath are the
    /// speed bytes those ceilings come to, because those are what the camera
    /// is actually sent.
    private var speedControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Max Gimbal Speed")
                .font(.subheadline)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    speedSlider("Pan", value: speeds.pan)
                    speedSlider("Tilt", value: speeds.tilt)
                }
                linkToggle
            }
            Text("Pan \(model.panSpeed) · Tilt \(model.tiltSpeed)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func speedSlider(_ axis: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(axis)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
            Slider(value: value, in: 0.05...1.0)
                .frame(width: 130)
                .accessibilityLabel("Maximum \(axis.lowercased()) speed")
        }
    }

    private var linkToggle: some View {
        Toggle(isOn: speeds.link) {
            Image(systemName: "link")
        }
        .toggleStyle(.button)
        .help(speedsLinked ? "Pan and tilt maximums move together"
                           : "Pan and tilt maximums are set separately")
        .accessibilityLabel("Link pan and tilt maximums")
    }

    private var zoomControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Zoom")
                .font(.subheadline)
            HStack(spacing: 8) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.zoomFactor },
                                      set: { model.setZoom($0) }),
                       in: model.zoomRange, step: 0.1)
                    .frame(width: 200)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            Text(String(format: "%.1f×", model.zoomFactor))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// Analog gimbal control: how far the puck is from the center of the well
/// sets direction and speed together, and letting go snaps it home and stops
/// the head.
///
/// The stop guarantee is HoldButton's, for the same reason: `endIfNeeded`
/// fires exactly once, including from `.onDisappear` when the well leaves the
/// hierarchy mid-drag (switching to the pad, leaving the Dashboard), so a
/// drive of the Dashboard's can never be left running. Grabbing the puck also
/// marks the head as held, which refuses any API drive for as long as the
/// grip lasts (see `GimbalDriveOwnership`) — so letting go always stops what
/// the well started, rather than finding the move taken over by a script.
private struct GimbalJoystickWell: View {
    let model: CameraControlsModel

    @State private var puck: CGSize = .zero
    @State private var isDriving = false

    private let wellDiameter: CGFloat = 104
    private let puckDiameter: CGFloat = 34

    /// How far the puck's center may travel — far enough to keep the puck
    /// itself inside the well.
    private var travel: CGFloat { (wellDiameter - puckDiameter) / 2 }

    /// Tilt is silently ignored while the camera streams portrait (§9).
    private var allowsTilt: Bool { !model.streamsPortrait }

    var body: some View {
        ZStack {
            Circle()
                .fill(.quaternary)
            travelGuide
            Circle()
                .fill(isDriving ? AnyShapeStyle(Color.accentColor)
                                : AnyShapeStyle(.tertiary))
                .frame(width: puckDiameter, height: puckDiameter)
                .offset(puck)
        }
        .frame(width: wellDiameter, height: wellDiameter)
        .contentShape(Circle())
        .gesture(driveGesture)
        .onDisappear { endIfNeeded() }
        .accessibilityLabel("Gimbal joystick")
        .help(allowsTilt
              ? "Drag to pan and tilt — further from the center is faster"
              : "Tilt is unavailable while the camera streams portrait")
    }

    /// Where the puck can go. A ring while both axes work; a bare horizontal
    /// track while tilt is locked out, so the reason the puck refuses to
    /// leave the center line is visible before the user tries.
    @ViewBuilder private var travelGuide: some View {
        if allowsTilt {
            Circle()
                .strokeBorder(.separator, lineWidth: 1)
                .padding(puckDiameter / 2)
        } else {
            Capsule()
                .fill(.separator)
                .frame(width: travel * 2, height: 2)
        }
    }

    private var driveGesture: some Gesture {
        // Zero minimum distance so a click that lands away from the center
        // deflects immediately, the same detector HoldButton uses.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDriving {
                    isDriving = true
                    model.beginJoystickDrive()
                }
                // The puck follows the pointer rather than the press point:
                // pressing anywhere in the well is a deflection to there.
                let offset = CGSize(width: value.location.x - wellDiameter / 2,
                                    height: value.location.y - wellDiameter / 2)
                puck = GimbalJoystick.puckOffset(for: offset, radius: travel,
                                                 allowsTilt: allowsTilt)
                model.updateJoystickDrive(offset: offset, radius: travel,
                                          owner: .dashboard)
            }
            .onEnded { _ in endIfNeeded() }
    }

    private func endIfNeeded() {
        guard isDriving else { return }
        isDriving = false
        withAnimation(.snappy) { puck = .zero }
        model.endGimbalDrive(owner: .dashboard)
    }
}

/// Directional pad driving XU relative pan/tilt, with a center button in the
/// middle. Arrows are press-and-hold: the drive starts on press and the stop
/// is sent on release (see CameraControlsModel.beginGimbalDrive for the
/// ordering guarantee). Kept alongside the joystick because a single precise
/// nudge is easier to aim with a button than with a puck.
private struct GimbalPad: View {
    let model: CameraControlsModel

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                padSpacer
                holdButton(.up, systemImage: "chevron.up", label: "Tilt up")
                padSpacer
            }
            GridRow {
                holdButton(.left, systemImage: "chevron.left", label: "Pan left")
                GimbalCenterButton(model: model)
                holdButton(.right, systemImage: "chevron.right", label: "Pan right")
            }
            GridRow {
                padSpacer
                holdButton(.down, systemImage: "chevron.down", label: "Tilt down")
                padSpacer
            }
        }
    }

    private var padSpacer: some View {
        Color.clear.frame(width: 36, height: 36)
    }

    /// Tilt is dead while the camera streams portrait (§9), so those two
    /// buttons switch off rather than failing silently.
    private func holdButton(_ direction: GimbalPadDirection,
                            systemImage: String, label: String) -> some View {
        HoldButton(systemImage: systemImage, label: label) {
            model.beginGimbalDrive(direction, owner: .dashboard)
        } onRelease: {
            model.endGimbalDrive(owner: .dashboard)
        }
        .disabled(model.streamsPortrait && direction.tilt != .stop)
        .help(model.streamsPortrait && direction.tilt != .stop
              ? "Tilt is unavailable while the camera streams portrait"
              : label)
    }
}

/// Sends the head home. Shared so the pad can keep it in the middle of the
/// grid while the joystick puts it beside the well.
private struct GimbalCenterButton: View {
    let model: CameraControlsModel

    var body: some View {
        Button {
            model.centerGimbal(owner: .dashboard)
        } label: {
            Image(systemName: "scope")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Center the gimbal")
        .accessibilityLabel("Center gimbal")
    }
}

/// Press-and-hold button: `onPress` fires once when the press begins and
/// `onRelease` exactly once when it ends — including when the button leaves
/// the hierarchy mid-hold, so a gimbal drive can never be left running.
private struct HoldButton: View {
    let systemImage: String
    let label: String
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 36, height: 36)
            .background(isPressed ? AnyShapeStyle(Color.accentColor.opacity(0.5))
                                  : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .gesture(holdGesture)
            .onDisappear { endIfNeeded() }
            .accessibilityLabel(label)
            .help(label)
    }

    private var holdGesture: some Gesture {
        // A zero-distance drag is the standard press-and-hold detector:
        // onChanged fires on mouse-down, onEnded on mouse-up.
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                onPress()
            }
            .onEnded { _ in endIfNeeded() }
    }

    private func endIfNeeded() {
        guard isPressed else { return }
        isPressed = false
        onRelease()
    }
}
