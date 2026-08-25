import Foundation

// The on-disk interchange format for sharing presets between machines, and the
// validation that stands between a file the user picked and the preset store.
//
// Everything here is pure: it turns `[Preset]` into `Data` and `Data` back into
// a validated `[Preset]`, and touches neither the store nor the filesystem. The
// store mutations live on `PresetStore`; the panels live in the Settings pane.
// That split is what lets `Checks/PresetTransferCheck.swift` exercise the whole
// format with the bare toolchain, no USB and no UI.

/// The exported file. A self-describing wrapper rather than a bare `[Preset]`
/// array: the array alone gives a future schema change nothing to branch on,
/// and gives an import no way to tell a preset file from any other JSON the
/// user happened to select.
///
/// `presets` is `[Preset]`, encoded and decoded through `Preset`'s own
/// `Codable` conformance rather than a parallel struct mirroring its fields.
/// A hand-mirrored copy would silently stop carrying any field added to
/// `Preset` later — the export would still succeed, and the user would lose the
/// new value with no error to tell them so. `Preset` stays the single
/// definition of its own shape; `version` below is what absorbs a change to it.
struct PresetTransferFile: Codable, Equatable, Sendable {
    /// Fixed marker, checked on import. Cheap insurance against a JSON file
    /// that decodes structurally but means something else entirely.
    var format: String
    /// Bumped when the shape changes. `PresetTransfer.decode` refuses anything
    /// it does not recognize rather than guessing.
    var version: Int
    /// Informational: never read back on import, but it makes a file that has
    /// been sitting in a Downloads folder for a year self-explanatory.
    var exportedAt: Date
    var presets: [Preset]
}

/// What a merge did, so the UI can tell the user rather than silently
/// dropping presets on the floor.
struct PresetMergeResult: Equatable, Sendable {
    /// Presets actually added to the store.
    var added: Int
    /// Skipped because their identifier was already present — the same preset
    /// arriving a second time, typically a re-import of a file already merged.
    var skipped: Int
    /// Imported presets that were marked "apply on connect" and were stored
    /// with the flag cleared, because the user already had a default of their
    /// own — or because an earlier preset in the same file had already taken
    /// the empty slot. See `PresetStore.merge(_:)`.
    var demotedDefaults: Int
    /// An imported preset was allowed to keep its "apply on connect" mark
    /// because the user had no default of their own. Worth reporting: it
    /// changes what happens on the next connect, and nothing in the UI asked
    /// the user to approve it.
    var adoptedDefault: Bool = false
}

enum PresetTransferError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)
    case notAPresetFile
    case unsupportedVersion(found: Int, supported: Int)
    case duplicateIdentifier(name: String)
    case emptyName
    case valueOutOfRange(preset: String, field: String, value: String, allowed: String)

    /// Written for the user, not the log: each case says what is wrong with
    /// *their* file and, where it helps, which preset in it.
    var description: String {
        switch self {
        case .unreadable(let detail):
            "This file is not readable as JSON: \(detail)"
        case .notAPresetFile:
            "This is not a Betterlink preset file."
        case .unsupportedVersion(let found, let supported):
            found > supported
                ? "This preset file was written by a newer version of Betterlink "
                    + "(format \(found); this copy understands \(supported)). Update Betterlink and try again."
                : "This preset file uses an old format (\(found)) that this copy of Betterlink no longer reads."
        case .duplicateIdentifier(let name):
            "This preset file is damaged: it lists “\(name)” twice under the same identifier."
        case .emptyName:
            "This preset file is damaged: it contains a preset with no name."
        case .valueOutOfRange(let preset, let field, let value, let allowed):
            "“\(preset)” has a \(field) of \(value), which is outside the range the "
                + "Insta360 Link accepts (\(allowed)). The file was not imported."
        }
    }
}

enum PresetTransfer {
    /// Current wrapper version. Bump only alongside a change to what `presets`
    /// decodes into, and teach `decode` how to read the older number.
    static let version = 1
    /// The `format` marker. Never change this string — files already on users'
    /// disks carry it.
    static let formatMarker = "betterlink.presets"

    /// Plain `.json`, matching the store's own file. No custom UTType is
    /// declared: a document type is Launch Services registration, an icon and a
    /// commitment that outlives the decision, for no benefit here.
    static let fileExtension = "json"
    static let suggestedFilename = "Betterlink Presets.json"

    // MARK: Accepted value ranges
    //
    // `UVCTransport` is the source of truth for all of these — pan and tilt
    // mirror `UVCTransport.panRestoreRange` / `.tiltRestoreRange`, the rest
    // mirror the clamps in `UVCTransport+Controls.swift` that `CameraSnapshot`
    // documents. They are repeated here as literals, rather than referenced,
    // so this file and its check compile without dragging in IOKit and USB: a
    // standalone check that needs the transport to build is a check that
    // quietly stops being run. `Checks/PresetTransferCheck.swift` pins these
    // same numbers, so if the transport's envelope ever moves, CI fails here
    // and points at the transport as the side to reconcile against.

    static let panRange: ClosedRange<Int32> = -522_000...522_000
    static let tiltRange: ClosedRange<Int32> = -324_000...360_000
    static let zoomRange: ClosedRange<UInt16> = 100...400
    static let percentRange: ClosedRange<UInt16> = 0...100
    static let hueRange: ClosedRange<Int16> = -15...15
    static let whiteBalanceRange: ClosedRange<UInt16> = 2000...10000
    static let rollRange: ClosedRange<Int16> = -100...100

    // MARK: Export

    /// Serializes `presets` into the wrapper format, using the store's shared
    /// encoder so an exported file is byte-for-byte as readable as the store's
    /// own — pretty-printed, stable key order, ISO-8601 dates.
    static func encode(_ presets: [Preset], exportedAt: Date = .now) throws -> Data {
        let file = PresetTransferFile(format: formatMarker,
                                      version: version,
                                      exportedAt: exportedAt,
                                      presets: presets)
        return try PresetStore.jsonEncoder().encode(file)
    }

    // MARK: Import

    /// Decodes and fully validates a file the user chose.
    ///
    /// Every check happens here, before the caller is handed anything it could
    /// write to the store. Either this returns a list that is safe to store or
    /// it throws and the store is never touched — there is no partial success
    /// to unwind, which is the whole reason validation is separated from the
    /// mutation.
    static func decode(_ data: Data) throws -> [Preset] {
        let file: PresetTransferFile
        do {
            file = try PresetStore.jsonDecoder().decode(PresetTransferFile.self, from: data)
        } catch let error as DecodingError {
            // A missing `format`/`version` means "not our file" far more often
            // than it means "our file, corrupted", so say the friendlier thing.
            if case .keyNotFound(let key, _) = error,
               key.stringValue == "format" || key.stringValue == "version" {
                throw PresetTransferError.notAPresetFile
            }
            throw PresetTransferError.unreadable(Self.explain(error))
        } catch {
            throw PresetTransferError.unreadable(error.localizedDescription)
        }

        guard file.format == formatMarker else { throw PresetTransferError.notAPresetFile }
        guard file.version == version else {
            throw PresetTransferError.unsupportedVersion(found: file.version, supported: version)
        }

        // Duplicate identifiers inside one file would put two presets with the
        // same `id` into the store, which is undefined behavior for every
        // SwiftUI list that iterates them by identity.
        var seen = Set<UUID>()
        for preset in file.presets {
            guard seen.insert(preset.id).inserted else {
                throw PresetTransferError.duplicateIdentifier(name: preset.name)
            }
            try validate(preset)
        }
        return file.presets
    }

    /// Range-checks one preset's snapshot. `PowerLineFrequency` needs no check
    /// here: it is `RawRepresentable`, so an unknown raw value already fails
    /// the decode above.
    private static func validate(_ preset: Preset) throws {
        guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PresetTransferError.emptyName
        }

        func check<V: BinaryInteger>(_ value: V, _ range: ClosedRange<V>, _ field: String) throws {
            guard range.contains(value) else {
                throw PresetTransferError.valueOutOfRange(
                    preset: preset.name,
                    field: field,
                    value: "\(value)",
                    allowed: "\(range.lowerBound) to \(range.upperBound)")
            }
        }

        let snapshot = preset.snapshot
        try check(snapshot.pan, panRange, "pan")
        try check(snapshot.tilt, tiltRange, "tilt")
        try check(snapshot.zoom, zoomRange, "zoom")
        try check(snapshot.brightness, percentRange, "brightness")
        try check(snapshot.contrast, percentRange, "contrast")
        try check(snapshot.saturation, percentRange, "saturation")
        try check(snapshot.sharpness, percentRange, "sharpness")
        try check(snapshot.hue, hueRange, "hue")
        try check(snapshot.whiteBalanceTemperature, whiteBalanceRange, "white balance temperature")
        try check(snapshot.focus, percentRange, "focus")
        try check(snapshot.roll, rollRange, "roll")
    }

    /// Turns a `DecodingError` into something a person can act on. The default
    /// `localizedDescription` for these is the useless "The data couldn't be
    /// read because it isn't in the correct format."
    private static func explain(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            "a required field, “\(key.stringValue)”, is missing"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            {
                let path = context.codingPath.map(\.stringValue).joined(separator: " › ")
                return path.isEmpty ? "a value has the wrong type" : "“\(path)” has the wrong type"
            }()
        case .dataCorrupted(let context):
            context.debugDescription
        @unknown default:
            "the file could not be decoded"
        }
    }
}
