import Foundation

// Capture and restore of whole-camera snapshots, built entirely on the typed
// transport API (UVCTransport+Controls.swift) — no new USB code here.

/// One control that refused a write while the rest of the restore carried on.
struct PresetApplyFailure: Identifiable, Sendable {
    let id = UUID()
    let field: String
    let message: String
}

enum SnapshotError: Error, CustomStringConvertible {
    /// A GET failed mid-capture. Unlike apply, capture aborts on the first
    /// failure — a preset missing half its values is worse than no preset.
    case captureFailed(field: String, underlying: String)

    var description: String {
        switch self {
        case .captureFailed(let field, let underlying):
            "Could not read \(field) from the camera: \(underlying)"
        }
    }
}

extension UVCTransport {
    /// Signs applied to the stored pan/tilt when a preset is restored. GET_CUR
    /// and SET_CUR agree on this hardware, so a round-trip needs no correction
    /// (verified 2026-08-21); these stay as the one-line escape hatch if another
    /// unit or firmware turns out to mirror an axis.
    static let panRestoreSign: Int32 = 1
    static let tiltRestoreSign: Int32 = 1

    /// The §4-verified absolute envelope (pan ±145°, tilt −90°…+100°), used to
    /// clamp persisted values so a hand-edited preset cannot put an arbitrary
    /// Int32 on the wire (`setPanTilt` itself deliberately does not clamp).
    static let panRestoreRange: ClosedRange<Int32> = -522_000...522_000
    static let tiltRestoreRange: ClosedRange<Int32> = -324_000...360_000

    /// Reads the camera's complete current state — the "save current state as
    /// preset" primitive. Every value comes from a GET_CUR on the typed API.
    func captureSnapshot() throws -> CameraSnapshot {
        func reading<Value>(_ field: String, _ body: () throws -> Value) throws -> Value {
            do { return try body() }
            catch { throw SnapshotError.captureFailed(field: field,
                                                      underlying: String(describing: error)) }
        }
        let position = try reading("pan/tilt") { try panTilt() }
        return CameraSnapshot(
            pan: position.pan,
            tilt: position.tilt,
            zoom: try reading("zoom") { try zoom() },
            brightness: try reading("brightness") { try brightness() },
            contrast: try reading("contrast") { try contrast() },
            saturation: try reading("saturation") { try saturation() },
            sharpness: try reading("sharpness") { try sharpness() },
            hue: try reading("hue") { try hue() },
            isAutoWhiteBalance: try reading("auto white balance") { try isAutoWhiteBalanceEnabled() },
            whiteBalanceTemperature: try reading("white balance temperature") { try whiteBalanceTemperature() },
            isAutoFocus: try reading("auto focus") { try isAutoFocusEnabled() },
            focus: try reading("focus") { try focus() },
            roll: try reading("roll") { try roll() },
            powerLineFrequency: try reading("anti-flicker") { try powerLineFrequency() })
    }

    /// Restores a snapshot: roll first, then position (pan/tilt, then zoom),
    /// then the image parameters. Error-tolerant — one stubborn control does not abort
    /// the rest; every failure comes back named so the UI can report them
    /// non-modally. Auto modes are written before their manual counterparts,
    /// and a manual value is skipped entirely while its auto mode is on (a
    /// preset saved with auto WB on must not push a manual temperature).
    ///
    /// Throws only when the camera cannot be reached at all — one clean error
    /// beats every write below reporting the same discovery failure.
    func apply(_ snapshot: CameraSnapshot) throws -> [PresetApplyFailure] {
        try connect()
        var failures: [PresetApplyFailure] = []
        // Once the device stops answering, every remaining write would fail the
        // same way (the transport drops its handle on any error and would try
        // a full rediscovery per control) — stop instead of piling on noise.
        //
        // "Stops answering" is broader than "unplugged": a timing-out camera
        // qualifies too, and since transfers now time out rather than hanging,
        // carrying on would cost the timeout per remaining control and turn one
        // stuck camera into a restore that grinds for over a minute. See
        // UVCError.stopsBatch.
        var deviceGone = false
        func attempt(_ field: String, _ body: () throws -> Void) {
            guard !deviceGone else { return }
            do { try body() }
            catch {
                failures.append(PresetApplyFailure(field: field,
                                                   message: String(describing: error)))
                if let uvc = error as? UVCError, uvc.stopsBatch { deviceGone = true }
            }
        }

        // Roll before position, not after: a CT_ROLL_ABSOLUTE write lands on the
        // same gimbal and aborts an in-flight pan/tilt move, sending the head
        // back where it started — which is why applying a preset used to report
        // success and change nothing (verified on hardware 2026-08-21, §9).
        attempt("roll") { try setRoll(snapshot.roll) }

        // Position. Clamping before the sign multiply also keeps
        // `sign * Int32.min` from ever trapping.
        attempt("pan/tilt") {
            try setPanTilt(PanTiltPosition(
                pan: Self.panRestoreSign * snapshot.pan.clamped(to: Self.panRestoreRange),
                tilt: Self.tiltRestoreSign * snapshot.tilt.clamped(to: Self.tiltRestoreRange)))
        }
        attempt("zoom") { try setZoom(snapshot.zoom) }

        // Image parameters.
        attempt("brightness") { try setBrightness(snapshot.brightness) }
        attempt("contrast") { try setContrast(snapshot.contrast) }
        attempt("saturation") { try setSaturation(snapshot.saturation) }
        attempt("sharpness") { try setSharpness(snapshot.sharpness) }
        attempt("hue") { try setHue(snapshot.hue) }
        attempt("auto white balance") { try setAutoWhiteBalance(snapshot.isAutoWhiteBalance) }
        if !snapshot.isAutoWhiteBalance {
            attempt("white balance temperature") {
                try setWhiteBalanceTemperature(snapshot.whiteBalanceTemperature)
            }
        }
        attempt("auto focus") { try setAutoFocus(snapshot.isAutoFocus) }
        if !snapshot.isAutoFocus {
            attempt("focus") { try setFocus(snapshot.focus) }
        }
        attempt("anti-flicker") { try setPowerLineFrequency(snapshot.powerLineFrequency) }
        return failures
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
