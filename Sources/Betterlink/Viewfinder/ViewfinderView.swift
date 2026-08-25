import AppKit
import AVFoundation
import SwiftUI

/// The Dashboard centerpiece: a live preview of the camera, with graceful
/// fallbacks for missing permission, no camera, and capture failures.
struct ViewfinderView: View {
    let model: ViewfinderModel

    var body: some View {
        Group {
            switch model.status {
            case .checkingAccess:
                ProgressView("Preparing camera…")
            case .accessDenied:
                ContentUnavailableView {
                    Label("Camera Access Needed", systemImage: "video.slash")
                } description: {
                    Text("Allow camera access for Betterlink in System Settings, then relaunch the app.")
                } actions: {
                    Button("Open System Settings") { openCameraPrivacySettings() }
                }
            case .noCamera:
                ContentUnavailableView(
                    "No Camera Connected",
                    systemImage: "video.slash",
                    description: Text("Connect your Insta360 Link over USB. The viewfinder starts automatically.")
                )
            case .failed(let message):
                ContentUnavailableView(
                    "Camera Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .live(let cameraName, let isLink):
                CameraPreview(layer: model.previewLayer)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomLeading) {
                        cameraBadge(name: cameraName, isLink: isLink)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        RecordingControlsView(recorder: model.recorder)
                    }
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.start() }
    }

    private func cameraBadge(name: String, isLink: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isLink ? "video.fill" : "exclamationmark.triangle.fill")
            Text(isLink ? name : "\(name) — Insta360 Link not detected")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(12)
    }

    private func openCameraPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Hosts the model's shared AVCaptureVideoPreviewLayer as the NSView's backing
/// layer. The view deliberately does NOT own the layer — the layer's lifetime
/// must match the session's (see ViewfinderModel.previewLayer), so the view
/// only borrows it and hands it back implicitly on teardown.
struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> PreviewNSView {
        PreviewNSView(previewLayer: layer)
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        if nsView.layer !== layer {
            nsView.layer = layer
        }
    }

    final class PreviewNSView: NSView {
        init(previewLayer: AVCaptureVideoPreviewLayer) {
            super.init(frame: .zero)
            layer = previewLayer
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }
}
