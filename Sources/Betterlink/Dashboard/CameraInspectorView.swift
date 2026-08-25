import SwiftUI

/// The Dashboard's trailing inspector: image adjustments, white balance,
/// focus, roll, anti-flicker, and the resolution/fps picker. Values and
/// ranges come from the camera on connect; every section disables while no
/// Link is attached.
struct CameraInspectorView: View {
    @Bindable var model: CameraControlsModel

    var body: some View {
        Form {
            if !model.isReady {
                Section {
                    Label(model.statusMessage
                            ?? "Connect an Insta360 Link to adjust camera settings.",
                          systemImage: "video.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Image") {
                sliderRow("Brightness", control: model.brightness,
                          value: Binding(get: { model.brightness.value },
                                         set: { model.setBrightness($0) }))
                sliderRow("Contrast", control: model.contrast,
                          value: Binding(get: { model.contrast.value },
                                         set: { model.setContrast($0) }))
                sliderRow("Saturation", control: model.saturation,
                          value: Binding(get: { model.saturation.value },
                                         set: { model.setSaturation($0) }))
                sliderRow("Sharpness", control: model.sharpness,
                          value: Binding(get: { model.sharpness.value },
                                         set: { model.setSharpness($0) }))
                sliderRow("Hue", control: model.hue,
                          value: Binding(get: { model.hue.value },
                                         set: { model.setHue($0) }))
            }
            .disabled(!model.isReady)

            Section("White Balance") {
                Toggle("Auto White Balance",
                       isOn: Binding(get: { model.autoWhiteBalance },
                                     set: { model.setAutoWhiteBalance($0) }))
                sliderRow("Temperature", control: model.whiteBalanceTemperature, unit: " K",
                          value: Binding(get: { model.whiteBalanceTemperature.value },
                                         set: { model.setWhiteBalanceTemperature($0) }))
                    .disabled(model.autoWhiteBalance)
            }
            .disabled(!model.isReady)

            Section("Focus") {
                Toggle("Autofocus",
                       isOn: Binding(get: { model.autoFocus },
                                     set: { model.setAutoFocus($0) }))
                sliderRow("Focus", control: model.focus,
                          value: Binding(get: { model.focus.value },
                                         set: { model.setFocus($0) }))
                    .disabled(model.autoFocus)
            }
            .disabled(!model.isReady)

            Section("Orientation") {
                sliderRow("Roll", control: model.roll,
                          value: Binding(get: { model.roll.value },
                                         set: { model.setRoll($0) }))
            }
            .disabled(!model.isReady)

            Section("Anti-Flicker") {
                Picker("Power Line",
                       selection: Binding(get: { model.antiFlicker },
                                          set: { model.setAntiFlicker($0) })) {
                    Text("Auto").tag(PowerLineFrequency.auto)
                    Text("50 Hz").tag(PowerLineFrequency.hz50)
                    Text("60 Hz").tag(PowerLineFrequency.hz60)
                    Text("Off").tag(PowerLineFrequency.disabled)
                }
            }
            .disabled(!model.isReady)

            Section {
                Picker("Resolution", selection: $model.selectedVideoFormatID) {
                    ForEach(model.videoFormats) { format in
                        Text(format.label).tag(String?.some(format.id))
                    }
                }
                Picker("Frame Rate", selection: $model.selectedFrameRate) {
                    ForEach(model.availableFrameRates, id: \.self) { rate in
                        Text("\(rate) fps").tag(Int?.some(rate))
                    }
                }
                LabeledContent("Current Mode", value: model.currentVideoModeDescription)
                Toggle("Portrait (9:16)", isOn: Binding(get: { model.streamsPortrait },
                                                        set: { model.setStreamsPortrait($0) }))
                    .disabled(!model.canChangeVideoFormat)
                Button("Apply Video Mode") { model.applyVideoMode() }
                    .disabled(!model.canApplyVideoMode)
            } header: {
                Text("Video Mode")
            } footer: {
                Text("4K has to fit down the Link's USB 2.0 connection, so it is heavily compressed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .disabled(!model.isReady)

            Section {
                Button("Reload From Camera") { model.reloadFromCamera() }
                    .disabled(!model.isCameraPresent)
                    .help("Re-read every control from the camera")
            }
        }
        .formStyle(.grouped)
    }

    private func sliderRow(_ title: String, control: AdjustableControl,
                           unit: String = "", value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: control.range, step: control.step)
                    .controlSize(.small)
                    .frame(minWidth: 110)
                Text("\(Int(control.value))\(unit)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .trailing)
            }
        }
    }
}
