import SwiftUI

/// Settings › General: the two preferences that are about the app itself
/// rather than the camera.
struct GeneralSettingsSection: View {
    // Matches the registered default. The registration wins either way —
    // @AppStorage only falls back when the key is absent, and
    // register(defaults:) makes it present — but a literal that disagreed
    // with Preferences would read as the real default to anyone here.
    @AppStorage(Preferences.restoresLastPane) private var restoresLastPane = true

    /// Owned here because nothing outside this section reads the login-item
    /// state; it is re-read on appear and on every return to the foreground,
    /// since System Settings can change it behind the app's back.
    @State private var launchAtLogin = LaunchAtLogin()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section {
            Toggle("Open Betterlink at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }))

            // Only meaningful in the `.requiresApproval` state, where the
            // registration exists but macOS is waiting on the user.
            if launchAtLogin.needsApproval {
                LabeledContent("Approval Needed") {
                    Button("Open Login Items…") { launchAtLogin.openSystemSettings() }
                }
            }

            if let error = launchAtLogin.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Toggle("Reopen the Last Pane on Launch", isOn: $restoresLastPane)
        } header: {
            Text("General")
        } footer: {
            Text("""
                 Opening at login is registered with macOS, so System Settings › \
                 General › Login Items can turn it off again — this switch shows \
                 whatever macOS currently has on file. Reopening the last pane \
                 restores whichever sidebar item was showing when you last quit, \
                 instead of always starting on the Dashboard.
                 """)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear { launchAtLogin.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { launchAtLogin.refresh() }
        }
    }
}
