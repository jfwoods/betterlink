import Foundation
import Observation
import ServiceManagement

/// The app's "open at login" registration, read back from the system rather
/// than mirrored into a preference.
///
/// There is deliberately no `Preferences` key behind this. `SMAppService` is
/// the only authority on whether macOS will actually launch us, and the user
/// can revoke the registration from System Settings › General › Login Items
/// while the app is not running. A stored boolean would drift from the real
/// state the first time that happened, and the toggle would then confidently
/// show the wrong thing.
///
/// Nothing notifies us when the registration changes underneath us, so
/// `refresh()` is called when the Settings pane appears and again whenever the
/// app comes back to the foreground.
@MainActor
@Observable
final class LaunchAtLogin {
    /// True when macOS holds a registration for the app. `.requiresApproval`
    /// counts as enabled: the registration exists and it is the user's consent
    /// that is missing, so reporting it as off would hide that half-finished
    /// state instead of explaining it.
    private(set) var isEnabled = false

    /// Registered, but the user has to allow it in System Settings before
    /// macOS will actually launch it.
    private(set) var needsApproval = false

    /// Why the last register/unregister did not take. Cleared by the next one
    /// that does.
    private(set) var lastError: String?

    init() {
        refresh()
    }

    /// Re-reads the live registration state from the system.
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    /// Registers or unregisters the app, then reports what the system actually
    /// did rather than what was asked of it.
    ///
    /// Both calls throw when the state is already the requested one —
    /// `register()` on an already-registered app returns `kSMErrorAlreadyRegistered`,
    /// `unregister()` on an unregistered one returns `kSMErrorJobNotFound` —
    /// so a throw on its own does not mean failure. The outcome is judged by
    /// re-reading `status` afterwards, which also avoids matching on `SMError`
    /// codes that Swift does not surface as typed constants.
    func setEnabled(_ enabled: Bool) {
        var thrown: Error?
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            thrown = error
        }
        refresh()

        if isEnabled == enabled {
            lastError = nil
        } else {
            // The toggle springs back by itself, because it reads `isEnabled`
            // rather than holding its own copy. Without a message alongside it
            // that revert would be silent and read as a glitch.
            lastError = Self.message(for: thrown, enabling: enabled)
        }
    }

    /// Opens System Settings › General › Login Items, where the user grants the
    /// approval that `register()` cannot grant on its own.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func message(for error: Error?, enabling: Bool) -> String {
        let action = enabling ? "Could not turn on Open at Login"
                              : "Could not turn off Open at Login"
        guard let error else { return "\(action)." }
        return "\(action): \(error.localizedDescription)"
    }
}
