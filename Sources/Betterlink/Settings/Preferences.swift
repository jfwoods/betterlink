import Foundation

/// The UserDefaults keys shared between the Settings pane and the models that
/// read them. Views bind with `@AppStorage(Preferences.<key>)`; non-View types
/// read `UserDefaults.standard` directly. Having the strings in one place is
/// the whole point — a typo in a key is a silently dead preference.
///
/// ponytail: no wrapper object. @AppStorage + UserDefaults is the native path;
/// add an @Observable settings store only if something needs to observe a
/// preference change from outside SwiftUI.
enum Preferences {
    /// `GimbalControlStyle.rawValue`. Which control the Dashboard shows.
    static let gimbalControlStyle = "gimbal.controlStyle"
    /// 0.05...1.0 — the fraction of the camera's max pan speed (30) that a
    /// full joystick deflection reaches. Also the D-pad's fixed speed.
    static let gimbalPanSpeed = "gimbal.panSpeed"
    /// 0.05...1.0 — same, against the max tilt speed (20).
    static let gimbalTiltSpeed = "gimbal.tiltSpeed"
    /// Pan and tilt sliders move together. Default true, which reproduces the
    /// single-slider behavior this replaced.
    static let gimbalSpeedLinked = "gimbal.speedLinked"

    /// `SidebarItem.rawValue` of the pane to restore on launch.
    static let lastPane = "ui.lastPane"
    /// Restore `lastPane` on launch instead of always opening the Dashboard.
    /// On by default: reopening where you left off is the ordinary Mac
    /// behavior, and anyone who lives in the Preset Menu or Settings pays for
    /// the alternative on every launch. The toggle exists for the opposite
    /// preference — always land on the camera — not as an opt-in to the useful
    /// case.
    static let restoresLastPane = "ui.restoresLastPane"

    /// The local REST API is listening.
    static let apiEnabled = "api.enabled"
    /// TCP port for the REST API.
    static let apiPort = "api.port"
    /// Bind 0.0.0.0 (reachable over the LAN) instead of 127.0.0.1.
    static let apiBindsLAN = "api.bindsLAN"

    /// Registered once at launch so every read has a sane value without every
    /// call site repeating a fallback.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            gimbalControlStyle: GimbalControlStyle.joystick.rawValue,
            gimbalPanSpeed: 0.5,
            gimbalTiltSpeed: 0.5,
            gimbalSpeedLinked: true,
            lastPane: SidebarItem.dashboard.rawValue,
            restoresLastPane: true,
            apiEnabled: false,
            apiPort: 8787,
            apiBindsLAN: false,
        ])
    }
}

/// How the Dashboard drives the gimbal. The joystick is analog — displacement
/// from center sets direction and speed together, scaled into the per-axis
/// caps above. The pad is the original press-and-hold arrows, kept because
/// it is better for a single precise nudge.
enum GimbalControlStyle: String, CaseIterable, Identifiable, Sendable {
    case joystick
    case pad

    var id: String { rawValue }

    var label: String {
        switch self {
        case .joystick: "Joystick"
        case .pad: "D-Pad"
        }
    }

    var icon: String {
        switch self {
        case .joystick: "circle.circle"
        case .pad: "dpad"
        }
    }
}
