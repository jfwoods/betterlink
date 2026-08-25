import SwiftUI

/// The Dashboard pane. The viewfinder stays the visual centerpiece; the
/// direct-manipulation controls (gimbal pad, speed, zoom) sit in a bar
/// beneath it, and the attribute-style adjustments (image, white balance,
/// focus, anti-flicker, video mode) live in a trailing inspector — the HIG
/// split between content controls and inspectors.
///
/// The favorites strip sits between the two: starred presets, one click from
/// the live picture, in the control-bar area rather than over the viewfinder —
/// a preset applied while you are framing a shot is exactly when you least
/// want something covering the shot.
///
/// ViewfinderView itself is deliberately untouched (a recording overlay for
/// it lives on another branch); everything here wraps around it.
struct DashboardView: View {
    let viewfinder: ViewfinderModel
    let controls: CameraControlsModel
    /// Owned by ContentView and shared with the preset panes, so a preset
    /// applied from here reports through the same banner and respects the
    /// same one-operation-at-a-time rule as one applied from the Preset Menu.
    let presets: PresetsModel

    @State private var isInspectorPresented = true

    var body: some View {
        VStack(spacing: 0) {
            ViewfinderView(model: viewfinder)
                .overlay {
                    // Mounted only while the Link is live so the NSView never
                    // sits over the viewfinder's interactive fallback states
                    // (their buttons would be unreachable behind it).
                    if showsZoomOverlay {
                        ScrollWheelZoomView { delta in
                            controls.nudgeZoom(by: delta)
                        }
                    }
                }
            Divider()
            FavoritesBar(model: presets)
            CameraControlBar(model: controls)
        }
        // The preset panes' banner, reused verbatim: applying from the
        // favorites row has to be able to report a failure, and a second
        // error-reporting style for the same operation would be worse than
        // an extra strip. A bottom safe-area inset keeps it out of the
        // viewfinder rather than over it.
        .safeAreaInset(edge: .bottom, spacing: 0) { PresetActivityBanner(model: presets) }
        .inspector(isPresented: $isInspectorPresented) {
            CameraInspectorView(model: controls)
                .inspectorColumnWidth(min: 270, ideal: 320, max: 400)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label("Camera Adjustments", systemImage: "slider.horizontal.3")
                }
                .help("Show or hide camera adjustments")
            }
        }
    }

    private var showsZoomOverlay: Bool {
        guard controls.isReady, case .live = viewfinder.status else { return false }
        return true
    }
}

#Preview {
    DashboardView(viewfinder: ViewfinderModel(),
                  controls: CameraControlsModel(),
                  presets: PresetsModel())
}
