import SwiftUI

/// The Preset Builder pane: name the camera's current state and save it as a
/// preset. Editing a saved preset's captured values is a later round — today
/// a preset is exactly what the camera looked like when it was captured.
struct PresetBuilderView: View {
    let model: PresetsModel

    @State private var name = ""

    var body: some View {
        Form {
            Section {
                TextField("Preset name", text: $name)
                    .onSubmit(capture)
                Button(action: capture) {
                    Label("Capture Current State", systemImage: "camera.aperture")
                }
                .disabled(!canCapture)
            } footer: {
                Text("Saves the camera's pan/tilt position, zoom, and image settings — "
                     + "brightness, contrast, saturation, sharpness, hue, white balance, "
                     + "focus, roll, and anti-flicker — as one preset you can re-apply "
                     + "from the Preset Menu.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { PresetActivityBanner(model: model) }
    }

    private var canCapture: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isBusy
    }

    private func capture() {
        guard canCapture else { return }
        Task {
            if await model.createPreset(named: name) {
                name = ""
            }
        }
    }
}
