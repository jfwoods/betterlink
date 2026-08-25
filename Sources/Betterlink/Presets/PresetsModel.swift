import Foundation
import Observation

/// Coordinates the preset panes: owns the store, shares the app's one
/// transport with the Dashboard, runs capture/apply off the main thread via
/// the transport actor, and publishes progress + outcomes for the shared
/// non-modal banner. One operation at a time — the camera is a single
/// physical resource.
@MainActor
@Observable
final class PresetsModel {
    let store: PresetStore
    private let transport: UVCTransport

    /// What the transport is doing right now, shown as non-modal progress.
    enum Activity: Equatable {
        case idle
        case capturing
        case applying(presetName: String)

        var label: String? {
            switch self {
            case .idle: nil
            case .capturing: "Reading camera state…"
            case .applying(let name): "Applying “\(name)”…"
            }
        }
    }

    /// How the last operation ended, shown until dismissed or replaced.
    enum Outcome: Equatable {
        case success(String)
        case partial(String, details: [String])
        case failure(String)
    }

    private(set) var activity: Activity = .idle
    private(set) var outcome: Outcome?

    /// Called after a preset's values reach the camera, so the Dashboard can
    /// re-read the controls the preset just changed instead of showing stale
    /// cached ones. Set by the app shell.
    @ObservationIgnored var onApplied: (@MainActor () -> Void)?

    var isBusy: Bool { activity != .idle }

    init(store: PresetStore = PresetStore(), transport: UVCTransport = UVCTransport()) {
        self.store = store
        self.transport = transport
    }

    func clearOutcome() {
        outcome = nil
    }

    /// Reads the camera's current state and saves it as a new preset.
    /// Returns true on success so the builder can clear its name field.
    @discardableResult
    func createPreset(named name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return false }
        activity = .capturing
        outcome = nil
        defer { activity = .idle }
        do {
            let snapshot = try await transport.captureSnapshot()
            store.add(Preset(name: trimmed, snapshot: snapshot))
            outcome = .success("Saved “\(trimmed)” from the camera's current state.")
            return true
        } catch {
            outcome = .failure(String(describing: error))
            return false
        }
    }

    /// Writes a preset's snapshot back to the camera, position first.
    func apply(_ preset: Preset) async {
        guard !isBusy else { return }
        activity = .applying(presetName: preset.name)
        outcome = nil
        defer { activity = .idle }
        do {
            let failures = try await transport.apply(preset.snapshot)
            if failures.isEmpty {
                outcome = .success("Applied “\(preset.name)”.")
            } else {
                outcome = .partial("Applied “\(preset.name)”, but \(failures.count) control(s) failed:",
                                   details: failures.map { "\($0.field): \($0.message)" })
            }
            // Partial counts too: whatever did land is now stale elsewhere.
            onApplied?()
        } catch {
            outcome = .failure(String(describing: error))
        }
    }
}
