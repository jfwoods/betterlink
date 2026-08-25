import Foundation

// Runnable check for the preset persistence logic: the pinned on-disk JSON
// schema, the encode/decode round-trip, and the store's disk round-trip with
// its at-most-one-default invariant. Not part of the app target — compile and
// run it with the bare toolchain:
//
//   swiftc -swift-version 6 -parse-as-library \
//     Sources/Betterlink/Transport/UVCTypes.swift \
//     Sources/Betterlink/Presets/Preset.swift \
//     Sources/Betterlink/Presets/PresetStore.swift \
//     Sources/Betterlink/Presets/PresetTransfer.swift \
//     Checks/PresetPersistenceCheck.swift \
//     -o /tmp/preset-check && /tmp/preset-check
//
// PresetTransfer.swift is in that list because the store's import methods
// return PresetMergeResult, which is declared there. Import/export itself is
// covered separately by Checks/PresetTransferCheck.swift.
//
// Dates in the fixtures are whole seconds because the ISO-8601 strategy does
// not keep sub-second precision.

@main
struct PresetPersistenceCheck {
    @MainActor
    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            if condition {
                print("ok   \(label)")
            } else {
                failures += 1
                print("FAIL \(label)")
            }
        }

        // 1. Pinned schema, as written before favorites existed. This exact
        //    JSON is what already sits on users' disks, and it has no
        //    "isFavorite" key. Decoding it MUST succeed and MUST default the
        //    flag to false: `PresetStore.load()` treats a decode error as an
        //    unreadable file and moves the whole thing aside, so a throw here
        //    would not lose one field, it would lose every saved preset.
        let pinned = """
        [{
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Desk",
          "createdAt": "2026-08-21T12:00:00Z",
          "isDefault": true,
          "snapshot": {
            "pan": -522000, "tilt": 360000, "zoom": 150,
            "brightness": 55, "contrast": 50, "saturation": 45, "sharpness": 60,
            "hue": -5,
            "isAutoWhiteBalance": true, "whiteBalanceTemperature": 6400,
            "isAutoFocus": false, "focus": 30,
            "roll": -10, "powerLineFrequency": 3
          }
        }]
        """
        do {
            let decoded = try PresetStore.jsonDecoder().decode([Preset].self, from: Data(pinned.utf8))
            expect(decoded.count == 1 && decoded[0].name == "Desk" && decoded[0].isDefault,
                   "pinned schema decodes")
            expect(!decoded[0].isFavorite,
                   "a preset saved before favorites existed decodes as not-favorite")
            let snapshot = decoded[0].snapshot
            expect(snapshot.pan == -522_000 && snapshot.tilt == 360_000 && snapshot.zoom == 150
                       && snapshot.hue == -5 && snapshot.powerLineFrequency == .auto
                       && snapshot.isAutoWhiteBalance && !snapshot.isAutoFocus && snapshot.focus == 30,
                   "pinned snapshot values survive")
        } catch {
            failures += 1
            print("FAIL pinned schema decode threw: \(error)")
        }

        // 1b. Pinned schema as written from here on: same file with the
        //     favorite mark present, so a future rename of the key is caught
        //     by CI rather than by a user losing their favorites row.
        let pinnedWithFavorite = """
        [{
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Desk",
          "createdAt": "2026-08-21T12:00:00Z",
          "isDefault": false,
          "isFavorite": true,
          "snapshot": {
            "pan": -522000, "tilt": 360000, "zoom": 150,
            "brightness": 55, "contrast": 50, "saturation": 45, "sharpness": 60,
            "hue": -5,
            "isAutoWhiteBalance": true, "whiteBalanceTemperature": 6400,
            "isAutoFocus": false, "focus": 30,
            "roll": -10, "powerLineFrequency": 3
          }
        }]
        """
        do {
            let decoded = try PresetStore.jsonDecoder()
                .decode([Preset].self, from: Data(pinnedWithFavorite.utf8))
            expect(decoded.count == 1 && decoded[0].isFavorite && !decoded[0].isDefault,
                   "current schema decodes the favorite mark")
        } catch {
            failures += 1
            print("FAIL pinned schema with favorite threw: \(error)")
        }

        // 2. Encode → decode round-trip at the extremes of every range.
        let snapshot = CameraSnapshot(
            pan: 145 * 3600, tilt: -90 * 3600, zoom: 400,
            brightness: 0, contrast: 100, saturation: 1, sharpness: 99,
            hue: 15, isAutoWhiteBalance: false, whiteBalanceTemperature: 2000,
            isAutoFocus: true, focus: 100, roll: -100, powerLineFrequency: .hz60)
        let preset = Preset(name: "Round trip",
                            createdAt: Date(timeIntervalSince1970: 1_755_777_600),
                            isFavorite: true,
                            snapshot: snapshot)
        do {
            let data = try PresetStore.jsonEncoder().encode([preset])
            let back = try PresetStore.jsonDecoder().decode([Preset].self, from: data)
            expect(back == [preset], "encode/decode round-trip is lossless")
            // The hand-written decoder tolerates a missing key; make sure the
            // encoder is still writing one, or new files would silently rely
            // on that tolerance forever.
            expect(String(decoding: data, as: UTF8.self).contains("\"isFavorite\" : true"),
                   "encoder writes the favorite mark")
        } catch {
            failures += 1
            print("FAIL round-trip threw: \(error)")
        }

        // 3. Store: persists across instances, keeps at most one default.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "preset-check-\(UUID().uuidString)")
        let url = dir.appending(path: "presets.json")
        let store = PresetStore(fileURL: url)
        let created = Date(timeIntervalSince1970: 1_755_777_601)
        store.add(Preset(name: "A", createdAt: created, isDefault: true, snapshot: snapshot))
        store.add(Preset(name: "B", createdAt: created, isDefault: true, snapshot: snapshot))
        expect(store.presets.filter(\.isDefault).map(\.name) == ["B"],
               "adding a second default demotes the first")
        store.rename(store.presets[0].id, to: "  A2  ")
        store.setDefault(store.presets[0].id)
        let reloaded = PresetStore(fileURL: url)
        expect(reloaded.presets == store.presets, "store round-trips through disk")
        expect(reloaded.presets.map(\.name) == ["A2", "B"], "rename trims and persists")
        expect(reloaded.defaultPreset?.name == "A2", "set-default persists and demotes")
        // Favorites: independent of the default flag, non-exclusive, persisted.
        expect(store.favorites.isEmpty, "presets start out not favorited")
        store.toggleFavorite(store.presets[0].id)
        store.toggleFavorite(store.presets[1].id)
        expect(store.favorites.map(\.name) == ["A2", "B"],
               "several presets can be favorites at once, in store order")
        expect(store.defaultPreset?.name == "A2",
               "favoriting does not disturb the default")
        expect(PresetStore(fileURL: url).favorites.map(\.name) == ["A2", "B"],
               "favorites persist through disk")
        store.toggleFavorite(store.presets[1].id)
        expect(PresetStore(fileURL: url).favorites.map(\.name) == ["A2"],
               "un-favoriting persists")

        store.delete(store.presets[1].id)
        expect(PresetStore(fileURL: url).presets.map(\.name) == ["A2"], "delete persists")
        try? FileManager.default.removeItem(at: dir)

        // 4. The data-loss path itself, end to end. Decoding correctly is not
        //    the claim that matters; what matters is that a presets.json
        //    written before favorites existed survives a real PresetStore
        //    load. `load()` treats any decode error as an unreadable file and
        //    moves the whole thing aside, so the failure mode this guards is
        //    not "one field is wrong", it is "every saved preset disappears
        //    on the first launch after upgrading".
        let legacyDir = FileManager.default.temporaryDirectory
            .appending(path: "preset-check-legacy-\(UUID().uuidString)")
        let legacyURL = legacyDir.appending(path: "presets.json")
        let asideURL = legacyURL.appendingPathExtension("unreadable")
        do {
            try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
            try Data(pinned.utf8).write(to: legacyURL)
        } catch {
            failures += 1
            print("FAIL could not stage the pre-favorites file: \(error)")
        }
        let legacyStore = PresetStore(fileURL: legacyURL)
        expect(legacyStore.presets.map(\.name) == ["Desk"],
               "a pre-favorites presets.json still loads through the store")
        expect(legacyStore.lastError == nil,
               "loading a pre-favorites file reports no error")
        expect(!FileManager.default.fileExists(atPath: asideURL.path),
               "a pre-favorites file is never moved aside as unreadable")
        expect(legacyStore.favorites.isEmpty,
               "a pre-favorites file starts with nothing favorited")
        // Upgrading in place: once such a file is re-saved it carries the key.
        // Guarded rather than subscripted, so that a regressed decoder reports
        // which assertion failed instead of trapping on an empty array and
        // taking the whole log with it.
        if let first = legacyStore.presets.first {
            legacyStore.toggleFavorite(first.id)
            expect(PresetStore(fileURL: legacyURL).favorites.map(\.name) == ["Desk"],
                   "favoriting upgrades a pre-favorites file in place")
        } else {
            failures += 1
            print("FAIL pre-favorites file did not load; the upgrade path is untested")
        }
        try? FileManager.default.removeItem(at: legacyDir)

        if failures > 0 {
            print("\(failures) check(s) FAILED")
            exit(1)
        }
        print("All preset persistence checks passed.")
    }
}
