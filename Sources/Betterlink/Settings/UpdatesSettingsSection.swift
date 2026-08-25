import Sparkle
import SwiftUI

/// Settings › Updates.
///
/// There are no `Preferences` keys here on purpose. `SPUUpdater` persists
/// `automaticallyChecksForUpdates` and `updateCheckInterval` into the host
/// bundle's user defaults itself, and Sparkle reads its own copies when it
/// schedules a check. A parallel `@AppStorage` key would be a second source of
/// truth that Sparkle never consults, and writing `SUEnableAutomaticChecks`
/// by hand would fight the framework for the same slot.
///
/// Per Sparkle's own guidance the updater's properties are written *only* when
/// the user changes a control: local state is seeded from the updater at init,
/// and `onChange` pushes it back. Rendering the view never writes.
struct UpdatesSettingsSection: View {
    private let updater: SPUUpdater

    /// Reuses the KVO-to-@Published adapter the "Check for Updates…" menu item
    /// uses, so the button here disables while a check is in flight for the
    /// same reason and by the same mechanism. `@StateObject`, not
    /// `@ObservedObject`: the adapter installs a KVO observation, and it should
    /// outlive the redraws of this view rather than be rebuilt by each one.
    @StateObject private var model: UpdaterViewModel

    @State private var automaticallyChecks: Bool
    @State private var interval: UpdateCheckInterval

    init(updater: SPUUpdater) {
        self.updater = updater
        _model = StateObject(wrappedValue: UpdaterViewModel(updater: updater))
        _automaticallyChecks = State(initialValue: updater.automaticallyChecksForUpdates)
        _interval = State(initialValue: UpdateCheckInterval.closest(to: updater.updateCheckInterval))
    }

    var body: some View {
        Section {
            Toggle("Check for Updates Automatically", isOn: $automaticallyChecks)
                .onChange(of: automaticallyChecks) { _, isOn in
                    updater.automaticallyChecksForUpdates = isOn
                }

            Picker("Frequency", selection: $interval) {
                ForEach(UpdateCheckInterval.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .disabled(!automaticallyChecks)
            .onChange(of: interval) { _, newValue in
                updater.updateCheckInterval = newValue.rawValue
            }

            Button("Check for Updates Now") { updater.checkForUpdates() }
                .disabled(!model.canCheckForUpdates)

            LabeledContent("Version", value: Self.versionDescription)
        } header: {
            Text("Updates")
        } footer: {
            Text("""
                 Betterlink downloads updates from its release feed and installs \
                 only those carrying a valid signature from the developer. \
                 Checking now works whether or not automatic checks are on.
                 """)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Marketing version plus build, the pair a bug report needs.
    private static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

/// The intervals offered in the picker, in the seconds `SPUUpdater` stores.
/// Sparkle's own minimum is an hour, and `SUScheduledCheckInterval` in
/// Info.plist ships as one day.
enum UpdateCheckInterval: TimeInterval, CaseIterable, Identifiable {
    case hourly = 3600
    case daily = 86400
    case weekly = 604_800

    var id: TimeInterval { rawValue }

    var label: String {
        switch self {
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }

    /// `updateCheckInterval` is a free-form `TimeInterval`, so a value that
    /// came from a hand-edited defaults entry need not be one of these three.
    /// Snapping to the nearest option shows the user something true about how
    /// often the app will check, and because the picker only writes back
    /// `onChange`, an odd stored value survives untouched until they pick.
    static func closest(to seconds: TimeInterval) -> UpdateCheckInterval {
        allCases.min { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) } ?? .daily
    }
}
