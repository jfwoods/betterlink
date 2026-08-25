import AppKit
import SwiftUI

/// Transparent overlay that turns scroll-wheel / trackpad scrolling over the
/// viewfinder into zoom nudges, without touching ViewfinderView internals.
/// DashboardView mounts it only while the Link is live, so it never covers
/// the viewfinder's interactive fallback states (their buttons would be
/// unreachable behind an NSView).
struct ScrollWheelZoomView: NSViewRepresentable {
    /// Called with a delta in zoom-factor units (positive = zoom in).
    let onZoomDelta: (Double) -> Void

    func makeNSView(context: Context) -> CatcherView {
        CatcherView(onZoomDelta: onZoomDelta)
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onZoomDelta = onZoomDelta
    }

    final class CatcherView: NSView {
        var onZoomDelta: (Double) -> Void

        init(onZoomDelta: @escaping (Double) -> Void) {
            self.onZoomDelta = onZoomDelta
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Only scroll events belong to this view. Returning nil for anything
        /// else lets clicks (the record button sits under this overlay) reach
        /// the SwiftUI content behind it, which an NSView otherwise swallows.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .scrollWheel else { return nil }
            return super.hitTest(point)
        }

        override func scrollWheel(with event: NSEvent) {
            // Trackpads report precise per-point deltas; wheels report lines,
            // so they get a larger multiplier. Scrolling up zooms in; if that
            // feels backwards in real use, flip the sign here.
            let scale = event.hasPreciseScrollingDeltas ? 0.003 : 0.05
            let delta = event.scrollingDeltaY * scale
            guard delta != 0 else { return }
            onZoomDelta(delta)
        }
    }
}
