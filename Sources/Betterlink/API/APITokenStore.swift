import Foundation
import Security

// Where the API's bearer token lives.
//
// The Keychain, not UserDefaults. A token in a plist under
// ~/Library/Preferences is readable by every process running as this user,
// which would make the loopback half of the design pointless: the reason the
// token is required on 127.0.0.1 at all is that "local" is not a trust
// boundary on an unsandboxed Mac. Storing the credential somewhere any local
// process can read it would hand back exactly what the token was there to
// take away.
//
// The item is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: it is a
// machine-local control credential with no meaning on another Mac, so it must
// not sync to iCloud Keychain and must not be readable while the device is
// locked.

enum APITokenError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case randomGenerationFailed(Int32)
    case corruptItem

    var description: String {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error \(status)\(message.map { ": \($0)" } ?? "")"
        case .randomGenerationFailed(let code):
            return "Could not generate a random token (SecRandomCopyBytes returned \(code))"
        case .corruptItem:
            return "The stored API token is not valid UTF-8 and has been discarded"
        }
    }
}

enum APITokenStore {
    /// Bundle-identifier-shaped so the item is recognizable in Keychain
    /// Access. Changing either string orphans the existing item, which shows
    /// up as a silently regenerated token — do not rename these.
    static let service = "me.jfwoods.Betterlink.api"
    static let account = "rest-api-bearer-token"

    /// 32 bytes of entropy. Rendered base64url without padding, so it is 43
    /// characters that need no escaping in an HTTP header, a shell command,
    /// or a Stream Deck configuration field.
    static let tokenByteCount = 16 * 2

    // MARK: Reads

    /// The stored token, or nil if none has been generated yet. Does not
    /// create one — the settings UI uses this to tell "not set up yet" from
    /// "set up", without minting a credential just because a pane was opened.
    static func existingToken() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw APITokenError.corruptItem }
            guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                // Something wrote a non-UTF-8 blob into our slot. Refuse to
                // authorize against it rather than comparing against garbage.
                try? delete()
                throw APITokenError.corruptItem
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw APITokenError.keychain(status)
        }
    }

    /// The stored token, generating and storing one on first use. This is what
    /// the server calls when it starts: enabling the API is what mints the
    /// credential.
    static func loadOrCreateToken() throws -> String {
        if let existing = try existingToken() { return existing }
        return try regenerateToken()
    }

    // MARK: Writes

    /// Replaces the stored token with a freshly generated one and returns it.
    /// Every client configured with the old token stops working immediately —
    /// that is the point of the button in Settings.
    @discardableResult
    static func regenerateToken() throws -> String {
        let token = try generateToken()
        try store(token)
        return token
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APITokenError.keychain(status)
        }
    }

    // MARK: Generation

    /// `SecRandomCopyBytes` is the CSPRNG; `Int.random` and friends are not
    /// documented to be cryptographically secure and must never mint a
    /// credential.
    static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw APITokenError.randomGenerationFailed(result) }
        return base64URLEncoded(bytes)
    }

    /// base64url without padding (RFC 4648 §5): no `+`, `/` or `=`, so the
    /// token survives being pasted into a URL, a header, or a shell without
    /// quoting.
    static func base64URLEncoded(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Keychain plumbing

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Explicitly not synchronizable: a control credential for one Mac's
            // USB webcam has no business on the user's other devices.
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static func store(_ token: String) throws {
        let data = Data(token.utf8)
        // Update-then-add rather than delete-then-add: a delete that succeeds
        // followed by an add that fails would leave the app with no token at
        // all, and the user locked out of an API they just regenerated.
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw APITokenError.keychain(updateStatus) }

        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Betterlink local API token"
        attributes[kSecAttrDescription as String] = "Bearer token for Betterlink's local REST API"
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw APITokenError.keychain(addStatus) }
    }
}
