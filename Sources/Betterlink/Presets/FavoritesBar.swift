import SwiftUI

/// The Dashboard's one-click preset strip: every preset starred in the Preset
/// Menu, rendered as a row of named buttons directly under the viewfinder so
/// the handful the user reaches for constantly never costs a trip to the
/// sidebar.
///
/// Deliberately a thin skin over `PresetsModel.apply` — the same call the
/// Preset Menu makes. The camera is one physical resource, so there is exactly
/// one apply path, one busy flag, and one banner reporting how it went; this
/// view adds a second way to *reach* that path, never a second copy of it.
struct FavoritesBar: View {
    let model: PresetsModel

    var body: some View {
        // Nothing starred means no strip at all, not an empty one. A blank
        // band between the viewfinder and the controls is pure dead space,
        // and it would push the picture up for no benefit.
        if !model.store.favorites.isEmpty {
            VStack(spacing: 0) {
                strip
                // Owned here rather than by DashboardView so the separator
                // disappears along with the row it separates.
                Divider()
            }
        }
    }

    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.store.favorites) { preset in
                    button(for: preset)
                }
            }
            // Matches CameraControlBar's insets so the two strips line up.
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        // Horizontal scrolling is what keeps a long favorites list from
        // squeezing its buttons or clipping the last one. The vertical
        // fixedSize is not cosmetic: a ScrollView is greedy in both axes, so
        // without it this strip would claim height from the viewfinder.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func button(for preset: Preset) -> some View {
        Button {
            Task { await model.apply(preset) }
        } label: {
            Text(preset.name)
                .lineLimit(1)
        }
        // One camera operation at a time: PresetsModel silently drops an apply
        // that arrives while another is in flight, so the buttons have to look
        // unavailable rather than look live and do nothing.
        .disabled(model.isBusy)
        .help("Apply “\(preset.name)”")
    }
}
