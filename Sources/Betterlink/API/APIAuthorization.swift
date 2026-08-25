import CryptoKit
import Foundation

// The trust boundary, as pure functions over a parsed request. Nothing here
// touches the Keychain, the socket or the camera — the caller supplies the
// expected token — which is what lets Checks/APIProtocolCheck.swift prove that
// a missing token and a wrong token are both refused, with no app running.
//
// Three gates, in this order, all of them ahead of routing:
//
//   1. Transport policy (Origin / Host)  — is this a browser or a rebinding
//      attempt? Answered before anything else because it is a blanket rule
//      that does not depend on the credential.
//   2. Authorization                     — is the bearer token right?
//   3. Routing                           — only now may a path exist or not.
//
// Ordering matters for more than tidiness. Routing last is what stops an
// unauthenticated caller from separating "401 for a preset id that exists"
// from "404 for one that does not" and enumerating the user's presets.

// MARK: - Transport policy

/// Blanket rules about who is allowed to talk to this socket at all,
/// independent of any credential.
enum APIRequestPolicy {
    enum Rejection: Equatable {
        /// The request carries an `Origin` header, so it came from a web page.
        case browserOrigin
        /// HTTP/1.1 requires `Host`; its absence means we cannot apply the
        /// rebinding check below, so the request is refused rather than waved
        /// through.
        case missingHost
        /// `Host` is a DNS name we cannot vouch for. See below.
        case untrustedHost(String)
        /// More than one `Host`. Same reasoning as the duplicate
        /// `Content-Length` and `Authorization` checks: nobody writes that
        /// client on purpose, and picking one of them is how a parser gets
        /// played off against whatever reads the header next.
        case duplicateHost

        var status: HTTPStatus { .forbidden }

        var code: String {
            switch self {
            case .browserOrigin: "origin_not_allowed"
            case .missingHost: "host_required"
            case .untrustedHost: "untrusted_host"
            case .duplicateHost: "duplicate_host"
            }
        }

        var message: String {
            switch self {
            case .browserOrigin:
                "This is a machine-to-machine control API. Requests carrying an "
                    + "Origin header are refused, and no CORS headers are ever sent."
            case .missingHost:
                "HTTP/1.1 requires a Host header."
            case .untrustedHost(let host):
                "Host '\(host)' is not an IP address, localhost, or a .local name."
            case .duplicateHost:
                "The request carries more than one Host header."
            }
        }
    }

    /// - Returns: the reason to refuse, or nil to continue to authorization.
    static func evaluate(_ request: HTTPRequest) -> Rejection? {
        // No CORS headers are ever emitted, so a browser could not read a
        // response anyway — but a plain form POST does not need to read the
        // response to have already moved the camera. Refuse anything that
        // announces itself as page-driven. (`OPTIONS` preflights get a 405
        // with no `Access-Control-*` headers at the routing layer, so the
        // browser blocks the real request before it is even sent.)
        if request.headers.contains("origin") { return .browserOrigin }

        // DNS rebinding: a page on attacker.example whose name resolves to
        // 127.0.0.1 sends same-origin requests to this socket with no Origin
        // header at all. The tell is the Host header — it carries the
        // attacker's registrable domain. Requiring Host to be an IP literal,
        // `localhost`, or an mDNS `.local` name removes the whole class:
        // none of those can be pointed at a victim's loopback by an attacker
        // who controls a public DNS zone. The bearer token already stops the
        // request from doing anything; this stops it from being sent.
        let hosts = request.headers.all("host")
        if hosts.count > 1 { return .duplicateHost }
        guard let rawHost = hosts.first, !rawHost.isEmpty else {
            return .missingHost
        }
        guard isTrustedHost(rawHost) else { return .untrustedHost(rawHost) }
        return nil
    }

    /// `Host` with its optional port removed and the result vetted.
    static func isTrustedHost(_ rawHost: String) -> Bool {
        var host = rawHost
        if host.hasPrefix("[") {
            // IPv6 literal, optionally `[::1]:8787`.
            guard let close = host.firstIndex(of: "]") else { return false }
            let inner = String(host[host.index(after: host.startIndex)..<close])
            let remainder = String(host[host.index(after: close)...])
            guard remainder.isEmpty || (remainder.hasPrefix(":") && isPort(String(remainder.dropFirst())))
            else { return false }
            return isIPv6Literal(inner)
        }
        if let colon = host.lastIndex(of: ":") {
            let port = String(host[host.index(after: colon)...])
            guard isPort(port) else { return false }
            host = String(host[host.startIndex..<colon])
        }
        let lowered = host.lowercased()
        if lowered == "localhost" { return true }
        if isIPv4Literal(lowered) { return true }
        // mDNS names are resolved by the local responder, not by public DNS,
        // so they cannot be delegated to an attacker.
        if lowered.hasSuffix(".local") && lowered.count > ".local".count { return true }
        return false
    }

    private static func isPort(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text) else { return false }
        return (1...65_535).contains(value)
    }

    private static func isIPv4Literal(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return false }
            return value <= 255
        }
    }

    private static func isIPv6Literal(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 60 else { return false }
        // A zone id (`fe80::1%en0`) is an interface name, not hex, so it is
        // split off and vetted separately — otherwise every link-local
        // address would look malformed.
        var address = text
        if let percent = text.firstIndex(of: "%") {
            let zone = text[text.index(after: percent)...]
            guard !zone.isEmpty,
                  zone.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                return false
            }
            address = String(text[text.startIndex..<percent])
        }
        // Deliberately shape-only: anything that is not hex digits, colons or
        // dots (IPv4-mapped) is not a literal, and a literal that is malformed
        // in some subtler way simply fails to connect.
        let allowed = Set("0123456789abcdefABCDEF:.")
        return address.contains(":") && address.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - Bearer authorization

/// Bearer-token authorization (RFC 6750), always required — on loopback as
/// well as on the LAN. The app is not sandboxed, so a listening socket is not
/// contained by anything; "it is only 127.0.0.1" is not an access control,
/// because every process running as this user can reach 127.0.0.1 too.
enum APIAuthorization {
    enum Outcome: Equatable {
        case authorized
        /// No usable `Authorization: Bearer …` was presented.
        case missingCredentials
        /// One was presented and it is wrong.
        case invalidToken

        /// RFC 6750 §3: the `error` parameter is omitted when the request
        /// carried no credentials at all, and present when it carried bad ones.
        var challenge: String {
            switch self {
            case .authorized, .missingCredentials: #"Bearer realm="Betterlink""#
            case .invalidToken: #"Bearer realm="Betterlink", error="invalid_token""#
            }
        }

        var message: String {
            switch self {
            case .authorized: ""
            case .missingCredentials:
                "This API requires an Authorization: Bearer <token> header. "
                    + "The token is in Betterlink's Settings pane."
            case .invalidToken:
                "The bearer token is not valid."
            }
        }
    }

    /// - Parameter expectedToken: the token from the Keychain. Never logged,
    ///   never echoed in a response, never compared with `==`.
    static func evaluate(headers: HTTPHeaders, expectedToken: String) -> Outcome {
        let presentedValues = headers.all("authorization")
        // Exactly one credential. Two `Authorization` headers is not a client
        // anybody writes on purpose; it is an attempt to find out which one a
        // parser prefers.
        guard presentedValues.count == 1 else {
            return presentedValues.isEmpty ? .missingCredentials : .invalidToken
        }
        guard let presented = bearerToken(in: presentedValues[0]) else {
            return .missingCredentials
        }
        return tokensMatch(presented: presented, expected: expectedToken)
            ? .authorized : .invalidToken
    }

    /// Extracts the token from one `Authorization` field value, or nil if the
    /// field is not a bearer credential. The scheme is case-insensitive; the
    /// token itself is not.
    static func bearerToken(in fieldValue: String) -> String? {
        let trimmed = fieldValue.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let scheme = trimmed[trimmed.startIndex..<space]
        guard scheme.lowercased() == "bearer" else { return nil }
        let token = trimmed[trimmed.index(after: space)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        // A token with embedded whitespace is not a b64token (RFC 6750 §2.1).
        guard !token.isEmpty, !token.contains(" "), !token.contains("\t") else { return nil }
        return token
    }

    /// Compares two tokens without leaking either one through timing.
    ///
    /// Both sides are hashed first and the fixed-width digests are what get
    /// compared. That is deliberate, and stronger than looping over the tokens
    /// themselves: a byte-wise loop over raw strings still has to decide what
    /// to do about unequal lengths, and every way of doing that leaks the
    /// expected token's length. SHA-256 makes both inputs exactly 32 bytes, so
    /// the comparison below is genuinely fixed-time, and the hash of the
    /// expected token is computed from a value the attacker is not varying.
    static func tokensMatch(presented: String, expected: String) -> Bool {
        let presentedDigest = Array(SHA256.hash(data: Data(presented.utf8)))
        let expectedDigest = Array(SHA256.hash(data: Data(expected.utf8)))
        return constantTimeEquals(presentedDigest, expectedDigest)
    }

    /// Fixed-time byte comparison: no early return, no data-dependent branch.
    /// Unequal lengths are impossible for the digests above; the guard is here
    /// so the function is still correct if it is ever reused on raw bytes.
    static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}
