import Sparkle
import SwiftUI

@main
struct BetterlinkApp: App {
    // Sparkle auto-updater. `startingUpdater: true` schedules the on-launch
    // check plus the SUScheduledCheckInterval recurrence using the SUFeedURL
    // declared in Info.plist (both set in project.yml). Owned here so its
    // lifetime matches the app's.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        Preferences.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            // The updater is handed down so Settings › Updates can bind to the
            // same instance the menu item drives; it stays owned here.
            ContentView(updater: updaterController.updater)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}

/// "Check for Updates…" menu item, placed under the application menu where
/// every Mac app puts it. Disables itself while a check is already in flight
/// by mirroring the updater's KVO-observable `canCheckForUpdates`.
struct CheckForUpdatesView: View {
    @ObservedObject private var model: UpdaterViewModel

    init(updater: SPUUpdater) {
        self.model = UpdaterViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            model.updater.checkForUpdates()
        }
        .disabled(!model.canCheckForUpdates)
    }
}

/// KVO-to-@Published adapter: Sparkle exposes `canCheckForUpdates` via KVO;
/// the @Published mirror is what SwiftUI redraws against.
///
/// Not private: `UpdatesSettingsSection` reuses it for its "Check for Updates
/// Now" button, which has to disable under exactly the same condition as the
/// menu item. A second copy of the same observer would be the same bug waiting
/// to be fixed twice.
@MainActor
final class UpdaterViewModel: ObservableObject {
    let updater: SPUUpdater
    @Published var canCheckForUpdates: Bool

    private var observation: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        self.updater = updater
        self.canCheckForUpdates = updater.canCheckForUpdates
        self.observation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor in
                self?.canCheckForUpdates = newValue
            }
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case presetMenu = "Preset Menu"
    case presetBuilder = "Preset Builder"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: "video"
        case .presetMenu: "list.star"
        case .presetBuilder: "slider.horizontal.3"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem?
    @State private var viewfinder = ViewfinderModel()
    // Owned here (not by DashboardView) so control values, the USB handle,
    // and the discovery mirroring survive sidebar navigation.
    @State private var cameraControls: CameraControlsModel
    @State private var presets: PresetsModel

    /// Handed to Settings › Updates. Owned by `BetterlinkApp`, not by this view.
    private let updater: SPUUpdater

    /// Recorded on every navigation, whether or not the restore preference is
    /// on right now — so turning it on later has something to restore rather
    /// than whatever pane was showing the day the user last switched it off.
    @AppStorage(Preferences.lastPane) private var lastPane = SidebarItem.dashboard.rawValue

    init(updater: SPUUpdater) {
        self.updater = updater
        // One transport for the whole app: two actors meant two open USB
        // handles and two panes that never saw each other's writes.
        let transport = UVCTransport()
        let cameraControls = CameraControlsModel(transport: transport)
        let presets = PresetsModel(transport: transport)
        // A preset writes zoom/image values behind the Dashboard's back, so
        // its cached copies have to be re-read once the preset lands.
        presets.onApplied = { cameraControls.reloadFromCamera() }
        _cameraControls = State(initialValue: cameraControls)
        _presets = State(initialValue: presets)

        // Read through UserDefaults rather than the @AppStorage properties:
        // a property wrapper is not readable until init has returned. An
        // unrecognized saved value (a pane that no longer exists) falls back to
        // the Dashboard instead of leaving the detail side empty.
        let defaults = UserDefaults.standard
        let restores = defaults.bool(forKey: Preferences.restoresLastPane)
        let saved = defaults.string(forKey: Preferences.lastPane)
            .flatMap(SidebarItem.init(rawValue:))
        _selection = State(initialValue: restores ? (saved ?? .dashboard) : .dashboard)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("OVERVIEW") {
                    row(.dashboard)
                }
                Section("PRESETS") {
                    row(.presetMenu)
                    row(.presetBuilder)
                }
                row(.settings)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .dashboard {
            case .dashboard:
                DashboardView(viewfinder: viewfinder, controls: cameraControls)
            case .presetMenu:
                PresetMenuView(model: presets)
            case .presetBuilder:
                PresetBuilderView(model: presets)
            case .settings:
                SettingsView(store: presets.store, updater: updater)
            }
        }
        .navigationTitle(selection?.rawValue ?? "Dashboard")
        // Camera controls mirror the viewfinder's Link discovery instead of
        // running their own; keep tracking for the life of the window.
        .task { cameraControls.track(viewfinder) }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            lastPane = newValue.rawValue
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.rawValue, systemImage: item.icon).tag(item)
    }
}

#Preview {
    // startingUpdater: false — a canvas preview must not schedule real update
    // checks or reach the network.
    ContentView(updater: SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil).updater)
}
