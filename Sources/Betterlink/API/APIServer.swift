import Foundation
import Network
import Observation

// The listening socket, and the only thing in the app that opens one.
//
// Apple's Network framework rather than a third-party HTTP server: Betterlink
// ships signed, notarized and hardened-runtime with Sparkle as its single
// dependency, and pulling a web framework into a webcam utility to serve a
// dozen routes is a supply-chain and review cost out of all proportion to the
// job. `NWListener` plus the hand-rolled parser in HTTPRequestParser.swift is
// a few hundred reviewable lines with no third-party code on the trust path.
//
// No entitlement is needed to listen: the app declares no App Sandbox key in
// Betterlink.entitlements (only the Hardened Runtime's camera and microphone
// exceptions), and the Hardened Runtime does not restrict sockets — it
// restricts code injection, library loading and JIT. macOS will still show the
// firewall prompt the first time this binds, and on recent macOS a non-loopback
// bind can also raise the Local Network privacy prompt. Both are the user's to
// answer; neither is suppressed.

/// One process-wide server, because there is one socket. Wired to the app's
/// models by `run(...)` from `ContentView`'s task, so the whole integration
/// into BetterlinkApp.swift is a single line.
@MainActor
@Observable
final class APIServer {
    static let shared = APIServer()

    enum State: Equatable {
        case disabled
        case starting
        case listening(host: String, port: UInt16)
        case failed(message: String)

        var isListening: Bool { if case .listening = self { true } else { false } }
    }

    private(set) var state: State = .disabled
    /// The bearer token currently in force, once the server has one. Held so
    /// the Settings pane can reveal and copy it without re-reading the
    /// Keychain on every keystroke.
    private(set) var token: String?

    // MARK: Internals

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var router: APIRouter?
    @ObservationIgnored private var models: Models?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?
    /// The configuration the current listener was started with, so a defaults
    /// change that does not affect us is a no-op rather than a socket bounce.
    @ObservationIgnored private var activeConfiguration: Configuration?
    /// Live connections, keyed by an id so each can remove itself when it
    /// finishes. Capped: a listening socket is an unbounded source of file
    /// descriptors otherwise.
    @ObservationIgnored private var connections: [UUID: APIConnection] = [:]
    /// Bumped every time a listener is created. State callbacks carry the
    /// generation they were armed with, so a late callback from a listener we
    /// have already replaced cannot overwrite the current one's state — which
    /// would otherwise leave Settings reporting "Not listening" on a socket
    /// that is in fact serving.
    @ObservationIgnored private var listenerGeneration = 0

    private static let maxConcurrentConnections = 16

    private struct Models {
        let transport: UVCTransport
        let viewfinder: ViewfinderModel
        let controls: CameraControlsModel
        let presets: PresetsModel
    }

    private struct Configuration: Equatable {
        var port: UInt16
        var bindsLAN: Bool
    }

    /// Serial queue for every `NWListener` and `NWConnection` callback. One
    /// queue for the whole server keeps connection bookkeeping off the main
    /// actor while the camera work hops onto it explicitly.
    @ObservationIgnored
    private let queue = DispatchQueue(label: "me.jfwoods.Betterlink.api", qos: .userInitiated)

    private init() {}

    // MARK: - Lifecycle

    /// Binds the server to the app's models and keeps it in step with the
    /// `api.*` preferences for as long as the caller's task lives. Cancelling
    /// that task (the window going away) stops the listener and closes every
    /// connection.
    func run(transport: UVCTransport, viewfinder: ViewfinderModel,
             controls: CameraControlsModel, presets: PresetsModel) async {
        guard !isRunning else { return }
        isRunning = true
        models = Models(transport: transport, viewfinder: viewfinder,
                        controls: controls, presets: presets)
        defer { shutDown() }

        // UserDefaults is the shared contract with the Settings pane (see
        // Preferences.swift), so the server follows it rather than being
        // handed a toggle. That is what lets APISettingsSection stand alone
        // with no wiring for the orchestrator to thread through.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        reconcile()

        // Park until the task is cancelled. Everything from here on is driven
        // by the listener's and the observer's own callbacks; this only exists
        // so `defer` above runs when the window closes.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// Brings the listener into line with the current preferences. Cheap and
    /// idempotent — it runs on every UserDefaults change in the app.
    func reconcile() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Preferences.apiEnabled) else {
            stopListening()
            activeConfiguration = nil
            state = .disabled
            return
        }
        let rawPort = defaults.integer(forKey: Preferences.apiPort)
        guard let port = Self.validatedPort(rawPort) else {
            stopListening()
            // Clear the attempt too, or correcting the port back to a value
            // that was previously active would compare equal below and be
            // skipped, leaving the API stopped with a stale error on screen.
            activeConfiguration = nil
            state = .failed(message: "Port \(rawPort) is not usable. Choose a port between "
                + "\(Self.portRange.lowerBound) and \(Self.portRange.upperBound).")
            return
        }
        let wanted = Configuration(port: port, bindsLAN: defaults.bool(forKey: Preferences.apiBindsLAN))
        // `activeConfiguration` is the last configuration we *attempted*, not
        // the last one that worked. This runs on every UserDefaults write
        // anywhere in the app, so comparing against the attempt is what keeps
        // an unrelated write from bouncing a healthy socket — and keeps a
        // failed bind (port already in use) from being retried in a loop.
        // Toggling the API off and on clears it, which is the retry gesture.
        if wanted == activeConfiguration { return }
        startListening(wanted)
    }

    /// Ports below 1024 need root, and 0 would pick an arbitrary one the user
    /// could not predict. Both are refused rather than substituted.
    static let portRange: ClosedRange<Int> = 1024...65_535

    static func validatedPort(_ raw: Int) -> UInt16? {
        guard portRange.contains(raw) else { return nil }
        return UInt16(raw)
    }

    private func startListening(_ configuration: Configuration) {
        stopListening()
        // Not recorded as the active configuration until the listener is
        // actually started. Recording it up front would make every failure
        // below compare equal on the next reconcile and refuse to retry,
        // wedging the API until the user toggled it off and on.
        activeConfiguration = nil
        listenerGeneration += 1
        let generation = listenerGeneration
        guard let models else {
            state = .failed(message: "The API server is not connected to the app yet.")
            return
        }
        state = .starting

        let token: String
        do {
            // Enabling the API is what mints the credential, from
            // SecRandomCopyBytes, into the Keychain. There is no
            // unauthenticated mode to fall back to, so a Keychain failure
            // stops the server rather than opening it up.
            token = try APITokenStore.loadOrCreateToken()
        } catch {
            state = .failed(message: "Could not read the API token from the Keychain: \(error)")
            return
        }
        self.token = token

        let router = APIRouter(transport: models.transport, viewfinder: models.viewfinder,
                               controls: models.controls, presets: models.presets, token: token)
        self.router = router

        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            state = .failed(message: "Port \(configuration.port) is not a valid TCP port.")
            return
        }
        do {
            // Parameters and listener are built by APIListenerFactory, which
            // takes no models and so can be constructed by a check. That is
            // deliberate: that construction used to live here, where nothing
            // without a camera could reach it, and it drifted into a
            // combination Network.framework refuses outright.
            let listener = try APIListenerFactory.makeListener(
                bindsLAN: configuration.bindsLAN, port: port)
            listener.stateUpdateHandler = { [weak self] listenerState in
                Task { @MainActor in
                    self?.listenerStateChanged(listenerState, configuration,
                                               generation: generation)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, router: router) }
            }
            self.listener = listener
            listener.start(queue: queue)
            // From here on the listener owns its own fate: a bind failure
            // arrives asynchronously through `listenerStateChanged`, and the
            // attempt stays recorded so an unrelated defaults write does not
            // retry a port that is already in use, over and over.
            activeConfiguration = configuration
        } catch {
            state = .failed(message: "Could not listen on port \(configuration.port): \(error.localizedDescription)")
        }
    }

    private func listenerStateChanged(_ listenerState: NWListener.State,
                                      _ configuration: Configuration,
                                      generation: Int) {
        // Detaching the handler in `stopListening()` stops new callbacks, but
        // one already hopping to the main actor can still land after a
        // replacement listener is up. Ignore it.
        guard generation == listenerGeneration else { return }
        switch listenerState {
        case .ready:
            state = .listening(host: configuration.bindsLAN ? "0.0.0.0" : "127.0.0.1",
                               port: configuration.port)
        case .failed(let error):
            state = .failed(message: "Port \(configuration.port): \(error.localizedDescription)")
            stopListening()
        case .cancelled:
            if case .failed = state { return }
            state = .disabled
        case .waiting(let error):
            // Most often the port is already taken by something else.
            state = .failed(message: "Waiting on port \(configuration.port): \(error.localizedDescription)")
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection, router: APIRouter) {
        // A listening socket is an unbounded source of file descriptors. Past
        // the cap, new connections are closed immediately rather than queued.
        guard connections.count < Self.maxConcurrentConnections else {
            connection.cancel()
            return
        }
        let id = UUID()
        let handler = APIConnection(id: id, connection: connection, router: router, queue: queue)
        connections[id] = handler
        handler.start { [weak self] finishedID in
            Task { @MainActor in self?.connections[finishedID] = nil }
        }
    }

    /// Tears down the socket and every live connection. Deliberately leaves
    /// `activeConfiguration` alone — see `reconcile()`.
    private func stopListening() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for handler in connections.values { handler.cancel() }
        connections.removeAll()
    }

    private func shutDown() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = nil
        stopListening()
        activeConfiguration = nil
        // If the API left the gimbal driving, this is the last moment anything
        // can stop it — the dead-man timer lives on the router we are about to
        // release.
        router?.stopGimbalIfDriving()
        router = nil
        models = nil
        isRunning = false
        // Do not leave a credential resident for a server that is gone; the
        // Settings pane reads this to decide what it can reveal and copy.
        token = nil
        state = .disabled
    }

    // MARK: - Token

    /// Mints a new token, replaces the stored one and puts it in force for the
    /// next request. Every client configured with the old token stops working
    /// immediately — that is the point.
    @discardableResult
    func regenerateToken() throws -> String {
        let fresh = try APITokenStore.regenerateToken()
        token = fresh
        router?.token = fresh
        return fresh
    }

    /// Reads the stored token without creating one, for the Settings pane.
    /// A failed read leaves whatever is already in force alone rather than
    /// blanking the Copy button on a token that is still working.
    func refreshTokenFromKeychain() {
        guard let stored = try? APITokenStore.existingToken() else { return }
        token = stored
        // The router has to move with it. Otherwise the Settings pane could
        // reveal and copy a token that the running router would answer 401 to.
        router?.token = stored
    }

    // MARK: - Reachability

    /// The URL a client should be pointed at. In LAN mode the loopback address
    /// is useless to the machine that actually needs it, so the host's own
    /// name is shown instead.
    func reachableURLs() -> [String] {
        let port = Self.validatedPort(UserDefaults.standard.integer(forKey: Preferences.apiPort))
            ?? UInt16(8787)
        guard UserDefaults.standard.bool(forKey: Preferences.apiBindsLAN) else {
            return ["http://127.0.0.1:\(port)"]
        }
        var urls = Self.localIPv4Addresses().map { "http://\($0):\(port)" }
        let hostName = ProcessInfo.processInfo.hostName
        if !hostName.isEmpty { urls.append("http://\(hostName):\(port)") }
        urls.append("http://127.0.0.1:\(port)")
        return urls
    }

    /// Non-loopback IPv4 addresses of up, running interfaces. Used only to
    /// show the user where to point their Stream Deck.
    static func localIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var addresses: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &hostBuffer, socklen_t(hostBuffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let characters = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let text = String(decoding: characters, as: UTF8.self)
            if !text.isEmpty, !addresses.contains(text) { addresses.append(text) }
        }
        return addresses
    }
}
