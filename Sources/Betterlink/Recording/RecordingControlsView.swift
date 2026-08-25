import SwiftUI

/// Record start/stop control with an elapsed-time readout, shown as a capsule
/// overlay on the viewfinder. Deliberately a single compact component so the
/// Dashboard layout can move it around freely.
struct RecordingControlsView: View {
    let recorder: RecordingController

    var body: some View {
        HStack(spacing: 10) {
            switch recorder.state {
            case .idle:
                recordButton(help: "Start recording")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 240)
                    .help(message)
                recordButton(help: "Try recording again")
            case .starting:
                ProgressView()
                    .controlSize(.small)
                Text("Starting…")
            case .recording(let startedAt):
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(startedAt, style: .timer)
                    .monospacedDigit()
                stopButton
            case .stopping:
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(12)
    }

    private func recordButton(help: String) -> some View {
        Button {
            recorder.startRecording()
        } label: {
            Image(systemName: "record.circle")
                .font(.title3)
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var stopButton: some View {
        Button {
            recorder.stopRecording()
        } label: {
            Image(systemName: "stop.circle.fill")
                .font(.title3)
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .help("Stop recording")
    }
}
