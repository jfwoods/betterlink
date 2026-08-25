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

        // 1. Pinned schema: this exact JSON is what ships on users' disks.
        //    If a field rename breaks this decode, it orphans saved presets.
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
            let snapshot = decoded[0].snapshot
            expect(snapshot.pan == -522_000 && snapshot.tilt == 360_000 && snapshot.zoom == 150
                       && snapshot.hue == -5 && snapshot.powerLineFrequency == .auto
                       && snapshot.isAutoWhiteBalance && !snapshot.isAutoFocus && snapshot.focus == 30,
                   "pinned snapshot values survive")
        } catch {
            failures += 1
            print("FAIL pinned schema decode threw: \(error)")
        }

        // 2. Encode → decode round-trip at the extremes of every range.
        let snapshot = CameraSnapshot(
            pan: 145 * 3600, tilt: -90 * 3600, zoom: 400,
            brightness: 0, contrast: 100, saturation: 1, sharpness: 99,
            hue: 15, isAutoWhiteBalance: false, whiteBalanceTemperature: 2000,
            isAutoFocus: true, focus: 100, roll: -100, powerLineFrequency: .hz60)
        let preset = Preset(name: "Round trip",
                            createdAt: Date(timeIntervalSince1970: 1_755_777_600),
                            snapshot: snapshot)
        do {
            let data = try PresetStore.jsonEncoder().encode([preset])
            let back = try PresetStore.jsonDecoder().decode([Preset].self, from: data)
            expect(back == [preset], "encode/decode round-trip is lossless")
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
        store.delete(store.presets[1].id)
        expect(PresetStore(fileURL: url).presets.map(\.name) == ["A2"], "delete persists")
        try? FileManager.default.removeItem(at: dir)

        if failures > 0 {
            print("\(failures) check(s) FAILED")
            exit(1)
        }
        print("All preset persistence checks passed.")
    }
}
