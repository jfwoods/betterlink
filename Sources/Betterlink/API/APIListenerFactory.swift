import Foundation
import Network

// Building the listening socket, lifted out of `APIServer` so that something
// without a camera, a window, or a set of models can construct one.
//
// This exists because of a bug that shipped on this branch: the port was named
// twice — positionally to `NWListener(using:on:)` and again inside
// `requiredLocalEndpoint` — and Network.framework refuses that combination with
// NWError 22 (EINVAL). The loopback listener, which is the default and the only
// mode most people will ever use, failed to bind at all. Four check suites and
// a 60,000-input fuzz passed over it, because not one of them could construct a
// listener.
//
// Foundation and Network only: no models, no SwiftUI, no Keychain, so
// Checks/APIProtocolCheck.swift can call `makeListener` for both modes and
// prove neither one throws.
enum APIListenerFactory {
    /// The transport parameters for one configuration.
    ///
    /// - Parameter bindsLAN: false pins the socket to loopback; true leaves the
    ///   listener free to bind every interface.
    static func makeParameters(bindsLAN: Bool, port: NWEndpoint.Port) -> NWParameters {
        let parameters = NWParameters.tcp
        // Rebinding immediately after a stop, instead of waiting out TIME_WAIT
        // and telling the user the port is in use when it is their own socket.
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if !bindsLAN {
            // Pin the bind address to 127.0.0.1 itself rather than filtering
            // by interface type. This is the failure mode that matters: a
            // wrong `requiredLocalEndpoint` cannot listen too widely, it can
            // only fail to listen, whereas an interface filter that is not
            // honoured would silently expose the socket to the LAN when the
            // user asked for loopback. IPv6 `::1` is deliberately not served —
            // clients resolving `localhost` fall back to 127.0.0.1, and
            // 127.0.0.1 is what the Settings pane tells them to use.
            //
            // The bearer token is still required here. The app is not
            // sandboxed, so every process running as this user can reach
            // 127.0.0.1 too; "local" is not an access control.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                                   port: port)
        }
        return parameters
    }

    /// Constructs the listener. Does not start it — binding happens on
    /// `start(queue:)`, which is the caller's job.
    ///
    /// Naming the port BOTH positionally and inside `requiredLocalEndpoint` is
    /// refused with NWError 22 (EINVAL) — observed on a running app, not
    /// theorised. When the endpoint pins the address it carries the port too,
    /// so `on:` must be omitted; only the LAN path, which sets no endpoint,
    /// names the port positionally. Keeping the two halves of that rule in one
    /// function is the point of this type: they cannot drift apart here.
    static func makeListener(bindsLAN: Bool, port: NWEndpoint.Port) throws -> NWListener {
        let parameters = makeParameters(bindsLAN: bindsLAN, port: port)
        return bindsLAN
            ? try NWListener(using: parameters, on: port)
            : try NWListener(using: parameters)
    }
}
