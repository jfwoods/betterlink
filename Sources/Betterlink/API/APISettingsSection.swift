import AppKit
import SwiftUI

/// The Settings pane's local-API section. A standalone `Section` so it drops
/// into whatever `Form` the Settings pane ends up being, with no wiring to
/// thread through: it reads and writes the shared `Preferences` keys, and the
/// server follows those keys on its own.
///
/// The token is never shown by default. A settings pane sits open on screen
/// while people share it, screenshot it and screen-share over it, and a bearer
/// token that grants control of the camera does not belong in any of those by
/// accident. Reveal is deliberate, per view, and never sticky.
struct APISettingsSection: View {
    @AppStorage(Preferences.apiEnabled) private var isEnabled = false
    @AppStorage(Preferences.apiPort) private var storedPort = 8787
    @AppStorage(Preferences.apiBindsLAN) private var bindsLAN = false

    @State private var portText = ""
    @State private var portError: String?
    @State private var isTokenRevealed = false
    @State private var isConfirmingRegenerate = false
    @State private var tokenError: String?
    @State private var copiedNotice: String?
    @State private var copyGeneration = 0
    @FocusState private var isPortFieldFocused: Bool

    private var server: APIServer { APIServer.shared }

    var body: some View {
        Section {
            Toggle("Enable the local control API", isOn: $isEnabled)
                .help("Lets a Stream Deck or a script drive the camera over HTTP.")

            if isEnabled {
                portField
                statusRow
                addressRow
                lanToggle
                tokenRow
            }
        } header: {
            Text("Local Control API")
        } footer: {
            footer
        }
        .onAppear {
            portText = String(storedPort)
            server.refreshTokenFromKeychain()
        }
        .confirmationDialog("Generate a new API token?",
                            isPresented: $isConfirmingRegenerate) {
            Button("Generate New Token", role: .destructive, action: regenerateToken)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current token stops working immediately. Every Stream Deck key "
                 + "and script using it must be updated with the new one.")
        }
    }

    // MARK: - Rows

    private var portField: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Committed on Return or when focus leaves, not on every
            // keystroke: the server rebinds its socket whenever the port
            // preference changes, and "878" is not a port anybody meant.
            TextField("Port", text: $portText)
                .focused($isPortFieldFocused)
                .frame(maxWidth: 120)
                .onSubmit(commitPort)
                .onChange(of: isPortFieldFocused) { _, focused in
                    if !focused { commitPort() }
                }
            if let portError {
                Text(portError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusTint)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var addressRow: some View {
        let urls = server.reachableURLs()
        if server.state.isListening, let primary = urls.first {
            LabeledContent("Address") {
                HStack(spacing: 8) {
                    Text(primary)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Button("Copy") { copy(primary, as: "Address") }
                        .buttonStyle(.link)
                }
            }
            if urls.count > 1 {
                Text("Also reachable at " + urls.dropFirst().joined(separator: ", ") + ".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var lanToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Allow connections from other devices on this network", isOn: $bindsLAN)
            if bindsLAN {
                // Plainly worded on purpose. This is the setting that turns a
                // loopback-only socket into one anything on the Wi-Fi can
                // reach, and the user should be able to picture what that
                // means without knowing what "bind 0.0.0.0" is.
                Label("Any device on your Wi-Fi or Ethernet network can now reach this "
                      + "port. Anyone who has the token below can move your camera, change "
                      + "the picture, and start and stop recordings. On a shared or public "
                      + "network, leave this off.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var tokenRow: some View {
        LabeledContent("Token") {
            HStack(spacing: 8) {
                Group {
                    if isTokenRevealed, let token = server.token {
                        Text(token)
                            .textSelection(.enabled)
                    } else {
                        Text(String(repeating: "•", count: 24))
                    }
                }
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

                Button(isTokenRevealed ? "Hide" : "Reveal") {
                    isTokenRevealed.toggle()
                }
                .buttonStyle(.link)
                .disabled(server.token == nil)

                Button("Copy") {
                    guard let token = server.token else { return }
                    copy(token, as: "Token", concealed: true)
                }
                .buttonStyle(.link)
                .disabled(server.token == nil)

                Button("Regenerate") { isConfirmingRegenerate = true }
                    .buttonStyle(.link)
            }
        }
        if let tokenError {
            Text(tokenError)
                .font(.caption)
                .foregroundStyle(.red)
        }
        if let copiedNotice {
            Text("\(copiedNotice) copied to the clipboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Every request must carry an Authorization: Bearer <token> header — "
                 + "on this Mac as well as over the network. There is no way to turn "
                 + "authentication off.")
            if isEnabled {
                Text("macOS asks for firewall permission the first time Betterlink listens. "
                     + "Allowing it is what lets the port answer.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Presentation helpers

    private var statusText: String {
        switch server.state {
        case .disabled: "Not listening."
        case .starting: "Starting…"
        case .listening(let host, let port): "Listening on \(host):\(port)."
        case .failed(let message): message
        }
    }

    private var statusIcon: String {
        switch server.state {
        case .disabled: "circle"
        case .starting: "clock"
        case .listening: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch server.state {
        case .disabled: .secondary
        case .starting: .secondary
        case .listening: .green
        case .failed: .red
        }
    }

    // MARK: - Actions

    private func commitPort() {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)),
              APIServer.validatedPort(value) != nil else {
            portError = "Enter a port between \(APIServer.portRange.lowerBound) and "
                + "\(APIServer.portRange.upperBound)."
            portText = String(storedPort)
            return
        }
        portError = nil
        storedPort = value
    }

    private func regenerateToken() {
        do {
            _ = try server.regenerateToken()
            tokenError = nil
            // Never leave a freshly minted credential on screen.
            isTokenRevealed = false
            copiedNotice = nil
        } catch {
            tokenError = "Could not save a new token to the Keychain: \(error)"
        }
    }

    /// The convention clipboard managers honour to skip an entry. Not a
    /// security boundary — nothing can stop another process reading the
    /// general pasteboard — but it keeps the token out of clipboard history
    /// and out of Universal Clipboard's sync to the user's other devices,
    /// which is most of what makes a pasteboard copy worse than the Keychain
    /// item it came from.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private func copy(_ value: String, as label: String, concealed: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        if concealed {
            NSPasteboard.general.setString(value, forType: Self.concealedType)
        }
        copiedNotice = label
        // The notice is confirmation, not status: leaving "Token copied" on
        // screen indefinitely says nothing true a minute later.
        copyGeneration += 1
        let generation = copyGeneration
        Task {
            try? await Task.sleep(for: .seconds(4))
            if copyGeneration == generation { copiedNotice = nil }
        }
    }
}

#Preview {
    // Shown inside a Form because that is where it is meant to live — the
    // Settings pane's own container.
    Form {
        APISettingsSection()
    }
    .formStyle(.grouped)
    .frame(width: 520)
}
