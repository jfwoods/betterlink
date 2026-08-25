import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Presets: moving the saved preset list on and off this machine.
///
/// `NSSavePanel` / `NSOpenPanel` are used directly rather than SwiftUI's
/// `fileExporter` / `fileImporter`. The app is not sandboxed, so a plain panel
/// needs no entitlement and no security-scoped bookmark, and it gives the
/// filename field and content-type filtering for free.
///
/// The order of operations on import is the point of this whole view: choose,
/// read, validate, *then* ask what to do with it. Nothing reaches the store
/// until `PresetTransfer.decode` has accepted the entire file, so a bad file
/// leaves both the in-memory list and the JSON on disk exactly as they were.
struct PresetTransferSection: View {
    let store: PresetStore

    /// A validated file waiting on the user's merge-or-replace decision.
    private struct PendingImport: Identifiable {
        let id = UUID()
        let filename: String
        let presets: [Preset]
    }

    private enum Status {
        case success(String)
        case failure(String)
    }

    @State private var pending: PendingImport?
    @State private var status: Status?

    var body: some View {
        Section {
            LabeledContent("Saved Presets", value: "\(store.presets.count)")

            Button("Export Presets…") { export() }
                .disabled(store.presets.isEmpty)
                .help("Write every saved preset to a file you can copy to another Mac")

            Button("Import Presets…") { chooseFileToImport() }
                .help("Read presets from a file exported by Betterlink")

            switch status {
            case .success(let message):
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        } header: {
            Text("Presets")
        } footer: {
            Text("""
                 Exported presets are plain JSON, so they can be kept in version \
                 control or edited by hand. Importing checks every value before \
                 anything is saved: if a file is damaged or was written by a \
                 different version, nothing changes.
                 """)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            pending.map { "Import \(Self.count($0.presets.count)) from “\($0.filename)”?" } ?? "",
            isPresented: Binding(get: { pending != nil },
                                 set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { item in
            Button("Merge") { merge(item) }
            Button("Replace All", role: .destructive) { replaceAll(item) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { item in
            Text(Self.choiceExplanation(importing: item.presets.count,
                                        existing: store.presets.count))
        }
    }

    // MARK: Export

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export Presets"
        panel.message = "Choose where to save your Betterlink presets."
        panel.nameFieldStringValue = PresetTransfer.suggestedFilename
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PresetTransfer.encode(store.presets)
            // Atomic for the same reason the store writes atomically: a failed
            // write must not leave a truncated file where a good one was.
            try data.write(to: url, options: .atomic)
            status = .success("Exported \(Self.count(store.presets.count)) to \(url.lastPathComponent).")
        } catch {
            status = .failure("Could not export presets: \(error.localizedDescription)")
        }
    }

    // MARK: Import

    private func chooseFileToImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Presets"
        panel.message = "Choose a preset file exported by Betterlink."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let presets = try PresetTransfer.decode(try Data(contentsOf: url))
            // A file that validates but holds nothing has no useful merge and a
            // genuinely destructive replace, so there is no question worth
            // asking about it.
            guard !presets.isEmpty else {
                status = .failure("“\(url.lastPathComponent)” contains no presets.")
                return
            }
            status = nil
            pending = PendingImport(filename: url.lastPathComponent, presets: presets)
        } catch let error as PresetTransferError {
            status = .failure(error.description)
        } catch {
            status = .failure("Could not read “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    private func merge(_ item: PendingImport) {
        pending = nil
        let result = store.merge(item.presets)

        var parts = ["Merged \(Self.count(result.added))"]
        if result.skipped > 0 {
            parts.append("\(result.skipped) skipped (already present)")
        }
        if result.adoptedDefault {
            parts.append("""
                         one is marked Apply on Connect, which you had not \
                         set for any preset
                         """)
        }
        if result.demotedDefaults > 0 {
            parts.append("""
                         \(Self.count(result.demotedDefaults)) marked Apply on Connect \
                         in the file kept your existing setting instead
                         """)
        }
        status = .success(parts.joined(separator: "; ") + ".")
    }

    private func replaceAll(_ item: PendingImport) {
        pending = nil
        let discarded = store.presets.count
        store.replaceAll(with: item.presets)
        status = .success("""
                          Replaced \(Self.count(discarded)) with \
                          \(Self.count(item.presets.count)) from “\(item.filename)”.
                          """)
    }

    // MARK: Wording

    private static func count(_ n: Int) -> String {
        n == 1 ? "1 preset" : "\(n) presets"
    }

    private static func choiceExplanation(importing: Int, existing: Int) -> String {
        let merge = "Merge adds them to the \(count(existing)) you already have, "
            + "skipping any that are already saved."
        let replace = existing == 0
            ? "Replace All saves only the imported presets."
            : "Replace All permanently deletes your \(count(existing)) first. "
                + "This cannot be undone."
        return merge + " " + replace
    }
}
