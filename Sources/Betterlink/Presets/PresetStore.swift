import Foundation
import Observation

/// Owns the saved presets: an in-memory list the UI observes, persisted as
/// human-readable JSON in Application Support. All mutation goes through the
/// store so the "at most one default" invariant cannot be broken.
@MainActor
@Observable
final class PresetStore {
    private(set) var presets: [Preset] = []

    /// Most recent persistence problem, surfaced non-modally by the UI.
    /// Cleared by the next successful save.
    private(set) var lastError: String?

    private let fileURL: URL

    /// ~/Library/Application Support/Betterlink/presets.json.
    nonisolated static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support")
        return base.appending(path: "Betterlink/presets.json")
    }

    init(fileURL: URL = PresetStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    var defaultPreset: Preset? { presets.first { $0.isDefault } }

    func add(_ preset: Preset) {
        if preset.isDefault { clearDefault() }
        presets.append(preset)
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = presets.firstIndex(where: { $0.id == id }),
              presets[index].name != trimmed else { return }
        presets[index].name = trimmed
        persist()
    }

    func delete(_ id: UUID) {
        let before = presets.count
        presets.removeAll { $0.id == id }
        guard presets.count != before else { return }
        persist()
    }

    /// The presets promoted to the Dashboard's favorites row, in the same
    /// order the Preset Menu lists them — there is no separate ordering UI,
    /// so one order everywhere is the least surprising rule.
    var favorites: [Preset] { presets.filter(\.isFavorite) }

    /// Flips a preset's favorite mark. Unlike `setDefault` there is no
    /// exclusivity to enforce — any number of presets can be favorites — so
    /// this only has to persist the change.
    func toggleFavorite(_ id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].isFavorite.toggle()
        persist()
    }

    /// Marks `id` as the default (applied on connect), demoting any other.
    /// Passing false clears the flag without electing a new default.
    func setDefault(_ id: UUID, _ isDefault: Bool = true) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        if isDefault { clearDefault() }
        presets[index].isDefault = isDefault
        persist()
    }

    private func clearDefault() {
        for index in presets.indices {
            presets[index].isDefault = false
        }
    }

    // MARK: Persistence

    /// Shared coding config: pretty-printed, stable key order, ISO-8601 dates —
    /// the file stays readable and diffable by hand.
    nonisolated static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            presets = try Self.jsonDecoder().decode([Preset].self, from: data)
            // Defensive: a hand-edited file could carry several defaults;
            // keep the first so the invariant holds in memory too.
            var seenDefault = false
            for index in presets.indices where presets[index].isDefault {
                if seenDefault { presets[index].isDefault = false }
                seenDefault = true
            }
        } catch {
            // Don't silently overwrite what might be recoverable by hand:
            // move the unreadable file aside and start empty.
            let aside = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            lastError = "Saved presets could not be read and were moved to "
                + "\(aside.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try Self.jsonEncoder().encode(presets)
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Could not save presets: \(error.localizedDescription)"
        }
    }

    // MARK: Import
    //
    // Deliberately the last two methods in the class. Both take presets that
    // `PresetTransfer.decode` has already validated — neither re-checks value
    // ranges, because a half-validated import is worse than an obvious one.
    // Each builds the complete new list before assigning it and persists once,
    // so a rejected file cannot leave the list or the JSON on disk half-written.

    /// Adds `incoming` alongside the presets already saved.
    ///
    /// Merging is purely additive. A preset whose identifier is already present
    /// is the same preset arriving twice — typically a re-import of a file
    /// already merged — so it is skipped and the local copy kept; overwriting
    /// would destroy a local edit, and re-identifying it would quietly breed
    /// near-duplicates.
    ///
    /// An imported "apply on connect" flag is cleared when the user already
    /// has a default — a file from outside the app never displaces a choice
    /// they made. When no local default exists the slot is empty, nothing of
    /// theirs is overwritten, and the first imported default is allowed to
    /// fill it; importing onto a fresh machine is the main reason to import at
    /// all, and arriving with no connect preset would be the less useful
    /// outcome. Any further imported defaults are cleared regardless, so the
    /// at-most-one-default invariant holds either way.
    @discardableResult
    func merge(_ incoming: [Preset]) -> PresetMergeResult {
        var result = PresetMergeResult(added: 0, skipped: 0, demotedDefaults: 0)
        var known = Set(presets.map(\.id))
        var additions: [Preset] = []

        // Recomputed as we go: an empty slot can be filled by the first
        // imported default, but only once.
        var defaultTaken = defaultPreset != nil

        for var preset in incoming {
            guard known.insert(preset.id).inserted else {
                result.skipped += 1
                continue
            }
            if preset.isDefault {
                if defaultTaken {
                    preset.isDefault = false
                    result.demotedDefaults += 1
                } else {
                    defaultTaken = true
                    result.adoptedDefault = true
                }
            }
            additions.append(preset)
        }

        result.added = additions.count
        guard !additions.isEmpty else { return result }
        presets.append(contentsOf: additions)
        persist()
        return result
    }

    /// Discards every saved preset and installs `incoming` in their place.
    /// Destructive and unrecoverable — the caller is responsible for confirming
    /// it first.
    ///
    /// Unlike merge, the file's own default is honored: replacing means the
    /// file describes the whole preset list, defaults included. A hand-edited
    /// file could still name several, so the first wins and the rest are
    /// cleared — the same rule `load()` applies to the store's own JSON.
    func replaceAll(with incoming: [Preset]) {
        var replacement = incoming
        var seenDefault = false
        for index in replacement.indices where replacement[index].isDefault {
            if seenDefault { replacement[index].isDefault = false }
            seenDefault = true
        }
        presets = replacement
        persist()
    }
}
