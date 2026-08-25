import SwiftUI

/// Shared non-modal status strip for the preset panes: a spinner while the
/// transport is busy, then the latest outcome with a dismiss control. Sits in
/// a bottom safe-area inset so it never blocks the content above it.
struct PresetActivityBanner: View {
    let model: PresetsModel

    var body: some View {
        if let label = model.activity.label {
            banner {
                ProgressView().controlSize(.small)
                Text(label)
            }
        } else if let outcome = model.outcome {
            banner {
                outcomeContent(outcome)
                Spacer()
                Button("Dismiss") { model.clearOutcome() }
                    .buttonStyle(.borderless)
            }
        } else if let storeError = model.store.lastError {
            banner {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(storeError)
            }
        }
    }

    @ViewBuilder
    private func outcomeContent(_ outcome: PresetsModel.Outcome) -> some View {
        switch outcome {
        case .success(let message):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message)
        case .partial(let message, let details):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                Text(details.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failure(let message):
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message)
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .bottom], 12)
    }
}
