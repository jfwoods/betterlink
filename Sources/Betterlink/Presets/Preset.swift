import Foundation

// The unified preset model (ROADMAP scope decision): ONE preset is ONE
// snapshot of PTZ position + zoom + image/color parameters, captured and
// restored together — deliberately not the first-party app's three separate
// systems (investigation-findings.md §3.4).

/// A named, timestamped camera snapshot the user can restore later.
struct Preset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    /// Marked to apply automatically when the camera connects. `PresetStore`
    /// enforces at most one default; the connect-time hook itself lands with
    /// device-connection observation in a later phase — the flag persists now.
    var isDefault: Bool
    /// Promoted to the Dashboard's favorites row, one click from the live
    /// viewfinder. Independent of `isDefault`: any number of presets can be
    /// favorites, and being the connect-time default says nothing about
    /// whether the user wants it on the row.
    var isFavorite: Bool
    var snapshot: CameraSnapshot

    init(id: UUID = UUID(), name: String, createdAt: Date = .now,
         isDefault: Bool = false, isFavorite: Bool = false, snapshot: CameraSnapshot) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.isDefault = isDefault
        self.isFavorite = isFavorite
        self.snapshot = snapshot
    }

    // Decoding is hand-written for exactly one reason: `isFavorite` did not
    // exist when users' presets.json files were written, and the *synthesized*
    // Decodable throws `keyNotFound` for a missing key even when the property
    // has a default value in the memberwise init — the default is not
    // consulted. That throw would not cost one field, it would cost the file:
    // `PresetStore.load()` treats any decode error as an unreadable file and
    // moves the whole thing aside, so a synthesized decode here would empty a
    // real user's preset list on first launch after upgrading.
    //
    // Every other key stays a strict `decode` so a genuinely corrupt file is
    // still caught rather than silently rebuilt from defaults.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        snapshot = try container.decode(CameraSnapshot.self, forKey: .snapshot)
    }
}

/// Everything the transport can read back from the camera, in the exact wire
/// units the typed API uses (`UVCTransport+Controls.swift`), so restore writes
/// back precisely what capture read.
///
/// Field names are the on-disk JSON schema — renaming one orphans users' saved
/// presets (Checks/PresetPersistenceCheck.swift pins them).
struct CameraSnapshot: Codable, Equatable, Sendable {
    // Position — restored first.
    /// CT_PANTILT_ABSOLUTE, arc-seconds (3600 per degree), sign exactly as
    /// GET_CUR reported it. Restore applies `UVCTransport.panRestoreSign` /
    /// `.tiltRestoreSign` and clamps to the verified envelope.
    var pan: Int32
    var tilt: Int32
    /// CT_ZOOM_ABSOLUTE: 100...400 = 1.00x...4.00x.
    var zoom: UInt16

    // Image / color parameters — restored after position.
    var brightness: UInt16              // 0...100
    var contrast: UInt16                // 0...100
    var saturation: UInt16              // 0...100
    var sharpness: UInt16               // 0...100
    var hue: Int16                      // -15...15
    var isAutoWhiteBalance: Bool
    var whiteBalanceTemperature: UInt16 // 2000...10000 K; applied only when auto WB is off
    var isAutoFocus: Bool
    var focus: UInt16                   // 0...100; applied only when auto focus is off
    var roll: Int16                     // CT_ROLL_ABSOLUTE, -100...100
    var powerLineFrequency: PowerLineFrequency

    var panDegrees: Double { Double(pan) / PanTiltPosition.arcSecondsPerDegree }
    var tiltDegrees: Double { Double(tilt) / PanTiltPosition.arcSecondsPerDegree }
    var zoomFactor: Double { Double(zoom) / 100 }
}

/// Codable for free through RawRepresentable (raw UInt8, the UVC wire value).
extension PowerLineFrequency: Codable {}

extension PowerLineFrequency {
    /// The first-party app calls this control "Anti-Flicker".
    var label: String {
        switch self {
        case .disabled: "Off"
        case .hz50: "50 Hz"
        case .hz60: "60 Hz"
        case .auto: "Auto"
        }
    }
}
