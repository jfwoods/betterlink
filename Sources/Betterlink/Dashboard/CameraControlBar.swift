import SwiftUI

/// The direct-manipulation strip under the viewfinder: gimbal pad with
/// center button, gimbal speed, and zoom. Everything disables together while
/// no Link is connected.
struct CameraControlBar: View {
    @Bindable var model: CameraControlsModel

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            GimbalPad(model: model)
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

    private var speedControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Gimbal Speed")
                .font(.subheadline)
            Slider(value: $model.gimbalSpeed, in: 0.05...1.0)
                .frame(width: 160)
            Text("Pan \(model.panSpeed) · Tilt \(model.tiltSpeed)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
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

/// Directional pad driving XU relative pan/tilt, with a center button in the
/// middle. Arrows are press-and-hold: the drive starts on press and the stop
/// is sent on release (see CameraControlsModel.beginGimbalDrive for the
/// ordering guarantee).
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
                centerButton
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
            model.beginGimbalDrive(direction)
        } onRelease: {
            model.endGimbalDrive()
        }
        .disabled(model.streamsPortrait && direction.tilt != .stop)
        .help(model.streamsPortrait && direction.tilt != .stop
              ? "Tilt is unavailable while the camera streams portrait"
              : label)
    }

    private var centerButton: some View {
        Button {
            model.centerGimbal()
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
