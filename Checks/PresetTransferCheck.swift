import Foundation

// Runnable check for preset import/export: the wrapper format, the export →
// import round-trip, every rejection path, and the store mutations that a
// validated import performs. Not part of the app target — compile and run it
// with the bare toolchain:
//
//   swiftc -swift-version 6 -parse-as-library \
//     Sources/Betterlink/Transport/UVCTypes.swift \
//     Sources/Betterlink/Presets/Preset.swift \
//     Sources/Betterlink/Presets/PresetStore.swift \
//     Sources/Betterlink/Presets/PresetTransfer.swift \
//     Checks/PresetTransferCheck.swift \
//     -o /tmp/preset-transfer-check && /tmp/preset-transfer-check
//
// Nothing here needs the camera, and deliberately nothing here imports the
// transport: `PresetTransfer` keeps its accepted ranges as literals precisely
// so this stays compilable without IOKit and USB. Section 2 pins those literals
// against `UVCTransport`'s envelope — if this check fails there, the transport
// is the side that moved and the side to reconcile against.
//
// Dates in the fixtures are whole seconds because the ISO-8601 strategy does
// not keep sub-second precision.

@main
struct PresetTransferCheck {
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

        let created = Date(timeIntervalSince1970: 1_755_777_600)

        func snapshot(zoom: UInt16 = 150, pan: Int32 = -522_000, tilt: Int32 = 360_000,
                      brightness: UInt16 = 55, hue: Int16 = -5,
                      whiteBalance: UInt16 = 6400, focus: UInt16 = 30,
                      roll: Int16 = -10) -> CameraSnapshot {
            CameraSnapshot(pan: pan, tilt: tilt, zoom: zoom,
                           brightness: brightness, contrast: 50, saturation: 45, sharpness: 60,
                           hue: hue, isAutoWhiteBalance: true, whiteBalanceTemperature: whiteBalance,
                           isAutoFocus: false, focus: focus, roll: roll,
                           powerLineFrequency: .auto)
        }

        /// The real import sequence, exactly as the Settings pane runs it:
        /// decode and validate everything first, and only then touch the store.
        /// Returns the error text when the file was rejected.
        func attemptImport(_ data: Data, into store: PresetStore,
                           replacing: Bool = false) -> String? {
            do {
                let presets = try PresetTransfer.decode(data)
                if replacing {
                    store.replaceAll(with: presets)
                } else {
                    store.merge(presets)
                }
                return nil
            } catch {
                return String(describing: error)
            }
        }

        // 1. Export → import round-trip, including the flags and identifiers.
        let alpha = Preset(name: "Desk", createdAt: created, isDefault: true,
                           snapshot: snapshot())
        let beta = Preset(name: "Whiteboard", createdAt: created, isDefault: false,
                          snapshot: snapshot(zoom: 400, pan: 522_000, tilt: -324_000,
                                             brightness: 0, hue: 15, whiteBalance: 2000,
                                             focus: 100, roll: 100))
        do {
            let data = try PresetTransfer.encode([alpha, beta], exportedAt: created)
            let back = try PresetTransfer.decode(data)
            expect(back == [alpha, beta], "export/import round-trip is lossless")

            // The wrapper is self-describing on disk, not just in memory.
            let text = String(decoding: data, as: UTF8.self)
            expect(text.contains("\"format\" : \"betterlink.presets\""),
                   "exported file carries the format marker")
            expect(text.contains("\"version\" : 1"),
                   "exported file carries the version field")
            expect(text.contains("\"presets\""), "exported file nests presets under a key")
        } catch {
            failures += 1
            print("FAIL round-trip threw: \(error)")
        }

        // 2. Pinned validation ranges. These mirror UVCTransport.panRestoreRange /
        //    .tiltRestoreRange and the clamps in UVCTransport+Controls.swift.
        //    A failure here means the transport's envelope moved and
        //    PresetTransfer was not updated to match.
        expect(PresetTransfer.panRange == -522_000...522_000, "pan range pinned to the transport")
        expect(PresetTransfer.tiltRange == -324_000...360_000, "tilt range pinned to the transport")
        expect(PresetTransfer.zoomRange == 100...400, "zoom range pinned to the transport")
        expect(PresetTransfer.percentRange == 0...100, "percent range pinned to the transport")
        expect(PresetTransfer.hueRange == -15...15, "hue range pinned to the transport")
        expect(PresetTransfer.whiteBalanceRange == 2000...10000, "white balance range pinned")
        expect(PresetTransfer.rollRange == -100...100, "roll range pinned to the transport")

        // 3. Rejection paths. Each of these must throw, and section 4 proves
        //    that throwing leaves the store and its file untouched.
        func encodedFile(format: String = "betterlink.presets", version: Int = 1,
                         presets: [Preset]) -> Data {
            let file = PresetTransferFile(format: format, version: version,
                                          exportedAt: created, presets: presets)
            return (try? PresetStore.jsonEncoder().encode(file)) ?? Data()
        }

        func rejects(_ data: Data, _ label: String) {
            do {
                _ = try PresetTransfer.decode(data)
                failures += 1
                print("FAIL \(label) — was accepted")
            } catch {
                print("ok   \(label)")
            }
        }

        rejects(Data("{ this is not json".utf8), "malformed JSON is rejected")
        rejects(Data("[]".utf8), "a bare array (the old shape) is rejected")
        rejects(Data("{}".utf8), "an empty object is rejected")
        rejects(Data(#"{"format":"something.else","version":1,"exportedAt":"2025-08-21T12:00:00Z","presets":[]}"#.utf8),
                "a wrong format marker is rejected")
        rejects(encodedFile(version: 0, presets: [alpha]), "an older version is rejected")
        rejects(encodedFile(version: 2, presets: [alpha]), "a newer version is rejected")

        // Every documented range, at the first value outside it.
        rejects(encodedFile(presets: [Preset(name: "Bad zoom", createdAt: created,
                                             snapshot: snapshot(zoom: 401))]),
                "zoom above 400 is rejected")
        rejects(encodedFile(presets: [Preset(name: "Bad zoom", createdAt: created,
                                             snapshot: snapshot(zoom: 99))]),
                "zoom below 100 is rejected")
        rejects(encodedFile(presets: [Preset(name: "Bad pan", createdAt: created,
                                             snapshot: snapshot(pan: 522_001))]),
                "pan outside the envelope is rejected")
        rejects(encodedFile(presets: [Preset(name: "Bad tilt", createdAt: created,
                                             snapshot: snapshot(tilt: -324_001))]),
                "tilt outside the envelope is rejected")
        rejects(encodedFile(presets: [Preset(name: "Bad brightness", createdAt: created,
                                             snapshot: snapshot(brightness: 101))]),
                "brightness above 100 is rejected")
        rejects(encodedFile(presets: [Preset(name: "Bad hue", createdAt: created,
                                             snapshot: snapshot(hue: 16))]),
                "hue outside -15...15 is rejected")
        rejects(encodedFile(presets: [Preset(name: "Bad WB", createdAt: created,
                                             snapshot: snapshot(whiteBalance: 1999))]),
                "white balance below 2000 K is rejected")
        rejects(encodedFile(presets: [Preset(name: "Bad roll", createdAt: created,
                                             snapshot: snapshot(roll: 101))]),
                "roll outside -100...100 is rejected")
        rejects(encodedFile(presets: [Preset(name: "  ", createdAt: created,
                                             snapshot: snapshot())]),
                "a preset with a blank name is rejected")

        // An unknown PowerLineFrequency raw value fails the decode itself.
        rejects(Data("""
        {"format":"betterlink.presets","version":1,"exportedAt":"2025-08-21T12:00:00Z",
         "presets":[{"id":"11111111-2222-3333-4444-555555555555","name":"Bad enum",
         "createdAt":"2025-08-21T12:00:00Z","isDefault":false,
         "snapshot":{"pan":0,"tilt":0,"zoom":150,"brightness":50,"contrast":50,
         "saturation":50,"sharpness":50,"hue":0,"isAutoWhiteBalance":true,
         "whiteBalanceTemperature":6400,"isAutoFocus":true,"focus":50,"roll":0,
         "powerLineFrequency":9}}]}
        """.utf8), "an unknown anti-flicker value is rejected")

        // Two presets sharing one identifier would break every SwiftUI list
        // that iterates them by identity.
        let twin = Preset(id: alpha.id, name: "Twin", createdAt: created, snapshot: snapshot())
        rejects(encodedFile(presets: [alpha, twin]), "duplicate identifiers in one file are rejected")

        // 4. A rejected import changes nothing — not the list, not the file.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "preset-transfer-check-\(UUID().uuidString)")
        let url = dir.appending(path: "presets.json")
        let store = PresetStore(fileURL: url)
        store.add(alpha)
        store.add(beta)
        let before = store.presets
        let bytesBefore = try? Data(contentsOf: url)

        let badFiles: [(Data, String)] = [
            (Data("{ this is not json".utf8), "malformed JSON"),
            (encodedFile(version: 2, presets: [twin]), "wrong version"),
            (encodedFile(presets: [Preset(name: "Bad zoom", createdAt: created,
                                          snapshot: snapshot(zoom: 401))]), "out-of-range value"),
        ]
        var allRejectedCleanly = true
        for (data, label) in badFiles {
            let error = attemptImport(data, into: store)
            let unchanged = store.presets == before && (try? Data(contentsOf: url)) == bytesBefore
            expect(error != nil, "\(label) import reports an error")
            expect(unchanged, "\(label) import leaves the store and its file untouched")
            allRejectedCleanly = allRejectedCleanly && error != nil && unchanged
        }
        expect(allRejectedCleanly, "no rejected import half-wrote the store")
        expect(store.lastError == nil, "a rejected import does not raise a persistence error")

        // 5. Merge: additive, skips identifiers already present, and never lets
        //    an imported file displace a default the user already set.
        let fresh = Preset(name: "Sofa", createdAt: created, isDefault: true, snapshot: snapshot())
        let mergeFile = encodedFile(presets: [alpha, fresh])
        expect(attemptImport(mergeFile, into: store) == nil, "a valid merge is accepted")
        expect(store.presets.count == 3, "merge adds only the presets not already present")
        expect(store.presets.map(\.name) == ["Desk", "Whiteboard", "Sofa"],
               "merge appends and keeps the local copy of a duplicate")
        expect(store.presets.filter(\.isDefault).map(\.name) == ["Desk"],
               "merge never displaces a default the user already set")
        expect(store.presets.filter(\.isDefault).count <= 1,
               "merge preserves the at-most-one-default invariant")

        let result = store.merge([alpha, beta])
        expect(result == PresetMergeResult(added: 0, skipped: 2, demotedDefaults: 0),
               "re-merging the same file adds nothing and reports both as skipped")

        // 5b. The empty-slot exception: with no local default, the first
        //     imported default is allowed to fill it. Nothing of the user's is
        //     overwritten, and importing onto a fresh machine is the main
        //     reason to import at all. Any further defaults in the same file
        //     are still cleared, so the invariant holds either way.
        let emptyURL = dir.appending(path: "no-default.json")
        let emptyStore = PresetStore(fileURL: emptyURL)
        emptyStore.add(Preset(name: "Local", createdAt: created, snapshot: snapshot()))
        expect(emptyStore.defaultPreset == nil, "the empty-slot store starts with no default")

        let twoIncoming = [
            Preset(name: "Imported first", createdAt: created, isDefault: true, snapshot: snapshot()),
            Preset(name: "Imported second", createdAt: created, isDefault: true, snapshot: snapshot()),
        ]
        let adopted = emptyStore.merge(twoIncoming)
        expect(adopted == PresetMergeResult(added: 2, skipped: 0, demotedDefaults: 1,
                                            adoptedDefault: true),
               "merging into an empty slot adopts one default and demotes the rest")
        expect(emptyStore.defaultPreset?.name == "Imported first",
               "the first imported default fills the empty slot")
        expect(emptyStore.presets.filter(\.isDefault).count == 1,
               "adopting a default still leaves at most one")

        let secondMerge = emptyStore.merge([
            Preset(name: "Imported third", createdAt: created, isDefault: true, snapshot: snapshot())
        ])
        expect(secondMerge.adoptedDefault == false && secondMerge.demotedDefaults == 1,
               "once the slot is filled a later import cannot take it")
        expect(emptyStore.defaultPreset?.name == "Imported first",
               "the adopted default survives a second merge")
        expect(PresetStore(fileURL: emptyURL).defaultPreset?.name == "Imported first",
               "the adopted default persists to disk")

        // 5c. UVCError.stopsBatch decides whether a preset restore abandons its
        //     remaining writes. It matters more than it looks: transfers now
        //     time out instead of hanging, so a batch that fails to stop costs
        //     the full timeout per remaining control.
        let stops: [(UVCError, String)] = [
            (.deviceNotFound, "the device being gone"),
            (.transferFailed(request: 0x81, entity: 1, selector: 0x0B,
                             code: Int32(bitPattern: 0xe000_4051)), "kIOUSBTransactionTimeout"),
            (.transferFailed(request: 0x81, entity: 1, selector: 0x0B,
                             code: Int32(bitPattern: 0xe000_02d6)), "kIOReturnTimeout"),
            (.transferFailed(request: 0x81, entity: 1, selector: 0x0B,
                             code: Int32(bitPattern: 0xe000_02ed)), "kIOReturnNotResponding"),
            (.transferFailed(request: 0x81, entity: 1, selector: 0x0B,
                             code: Int32(bitPattern: 0xe000_02c0)), "kIOReturnNoDevice"),
        ]
        for (error, label) in stops {
            expect(error.stopsBatch, "a restore stops on \(label)")
        }

        // A control the camera merely refuses must NOT abandon the rest —
        // preset restore is deliberately forgiving about individual controls.
        let continues: [(UVCError, String)] = [
            (.transferFailed(request: 0x01, entity: 1, selector: 0x0B,
                             code: Int32(bitPattern: 0xe000_2c00)), "an ordinary transfer failure"),
            (.shortResponse(expected: 4, received: 2), "a short response"),
            (.unexpectedResponse(entity: 1, selector: 0x0B, bytes: [0xFF]), "an unexpected response"),
        ]
        for (error, label) in continues {
            expect(!error.stopsBatch, "a restore carries on past \(label)")
        }



        // 6. Replace: destructive, honors the file's own default, and still
        //    collapses a hand-edited file that names several.
        let twoDefaults = [
            Preset(name: "First", createdAt: created, isDefault: true, snapshot: snapshot()),
            Preset(name: "Second", createdAt: created, isDefault: true, snapshot: snapshot()),
        ]
        expect(attemptImport(encodedFile(presets: twoDefaults), into: store, replacing: true) == nil,
               "a valid replace is accepted")
        expect(store.presets.map(\.name) == ["First", "Second"],
               "replace discards the previous presets entirely")
        expect(store.presets.filter(\.isDefault).map(\.name) == ["First"],
               "replace keeps the file's first default and demotes the rest")

        // 7. Everything above survives a reload from disk.
        let reloaded = PresetStore(fileURL: url)
        expect(reloaded.presets == store.presets, "an imported store round-trips through disk")
        try? FileManager.default.removeItem(at: dir)

        if failures > 0 {
            print("\(failures) check(s) FAILED")
            exit(1)
        }
        print("All preset transfer checks passed.")
    }
}
