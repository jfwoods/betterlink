import SwiftUI

/// The Preset Menu pane: every saved preset with apply / rename / delete /
/// apply-on-connect controls. Applying reports progress and errors through
/// the shared non-modal banner, never a blocking sheet.
struct PresetMenuView: View {
    let model: PresetsModel

    @State private var renaming: Preset?
    @State private var renameText = ""

    var body: some View {
        Group {
            if model.store.presets.isEmpty {
                ContentUnavailableView {
                    Label("No Presets Yet", systemImage: "list.star")
                } description: {
                    Text("Point the camera, then save its state from the Preset Builder.")
                }
            } else {
                List(model.store.presets) { preset in
                    row(preset)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { PresetActivityBanner(model: model) }
        .alert("Rename Preset", isPresented: renameAlertShown, presenting: renaming) { preset in
            TextField("Name", text: $renameText)
            Button("Rename") { model.store.rename(preset.id, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var renameAlertShown: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private func row(_ preset: Preset) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(preset.name).font(.headline)
                    if preset.isDefault {
                        Label("On connect", systemImage: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(summary(of: preset.snapshot)) · saved \(preset.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.apply(preset) }
            } label: {
                Label("Apply", systemImage: "play.fill")
            }
            .disabled(model.isBusy)
            Menu {
                menuItems(preset)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contextMenu { menuItems(preset) }
    }

    @ViewBuilder
    private func menuItems(_ preset: Preset) -> some View {
        Button("Rename…") {
            renameText = preset.name
            renaming = preset
        }
        if preset.isDefault {
            Button("Stop Applying on Connect") { model.store.setDefault(preset.id, false) }
        } else {
            Button("Apply on Connect") { model.store.setDefault(preset.id) }
        }
        Divider()
        Button("Delete", role: .destructive) { model.store.delete(preset.id) }
    }

    private func summary(of snapshot: CameraSnapshot) -> String {
        String(format: "pan %.0f°, tilt %.0f°, zoom %.1f×",
               snapshot.panDegrees, snapshot.tiltDegrees, snapshot.zoomFactor)
    }
}
