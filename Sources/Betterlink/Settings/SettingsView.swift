import Sparkle
import SwiftUI

/// The Settings pane.
///
/// A sidebar pane, not a `Settings` scene behind Cmd-comma: `specifications.md`
/// puts Settings in the sidebar alongside Dashboard and the preset panes, so it
/// is one of the split view's details and shares the window with everything
/// else.
///
/// Each section is its own view, and the body is just the running order. Adding
/// a section is a single line here and no other edit — which is how the REST API
/// section arrives.
struct SettingsView: View {
    let store: PresetStore
    let updater: SPUUpdater

    var body: some View {
        Form {
            GeneralSettingsSection()
            GimbalSettingsSection()
            PresetTransferSection(store: store)
            APISettingsSection()
            UpdatesSettingsSection(updater: updater)
        }
        .formStyle(.grouped)
    }
}
