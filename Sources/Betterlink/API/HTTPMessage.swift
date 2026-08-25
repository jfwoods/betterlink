import Foundation

// The HTTP/1.1 message types the local control API speaks. Deliberately
// hand-rolled and deliberately tiny: the app ships signed, notarized and
// hardened-runtime with Sparkle as its only dependency, and a web framework
// is a supply-chain and review cost far out of proportion to a dozen routes
// on loopback.
//
// Everything in this file is pure value types over Foundation — no Network,
// no SwiftUI, no camera. That is what lets Checks/APIProtocolCheck.swift
// compile and exercise the wire format with the bare toolchain, with no
// camera attached and no app running.

// MARK: - Method

/// The methods the parser will admit. Anything outside this set is a 501 at
/// parse time; a method that is in the set but not routed for a given path is
/// a 405 with an `Allow` header, which is the distinction RFC 9110 draws.
enum HTTPMethod: String, Sendable, Equatable, CaseIterable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case options = "OPTIONS"

    /// HEAD is routed exactly like GET and then has its body suppressed at
    /// serialization time, so a HEAD can never reach a handler with side
    /// effects — every GET route here is a pure read.
    var routesAs: HTTPMethod { self == .head ? .get : self }
}

// MARK: - Headers

/// One header field, with the name already lowercased. Field names are
/// case-insensitive (RFC 9110 §5.1) and comparing them case-insensitively at
/// every lookup site is how a header check gets quietly bypassed.
struct HTTPHeaderField: Sendable, Equatable {
    /// Lowercased.
    let name: String
    let value: String
}

/// An ordered, case-insensitive header collection that keeps duplicates.
/// Duplicates matter: a second `Content-Length` or a second `Authorization`
/// is a request-smuggling / auth-confusion vector, so the parser and the
/// authorizer both need to see that there was more than one rather than
/// silently taking the first.
struct HTTPHeaders: Sendable, Equatable {
    private(set) var fields: [HTTPHeaderField]

    init(_ fields: [HTTPHeaderField] = []) {
        self.fields = fields
    }

    var count: Int { fields.count }

    /// The first value for `name`, or nil. Use `all(_:)` wherever a second
    /// occurrence would change the meaning of the request.
    func first(_ name: String) -> String? {
        let wanted = name.lowercased()
        return fields.first { $0.name == wanted }?.value
    }

    func all(_ name: String) -> [String] {
        let wanted = name.lowercased()
        return fields.compactMap { $0.name == wanted ? $0.value : nil }
    }

    func contains(_ name: String) -> Bool {
        let wanted = name.lowercased()
        return fields.contains { $0.name == wanted }
    }

    mutating func append(name: String, value: String) {
        fields.append(HTTPHeaderField(name: name.lowercased(), value: value))
    }
}

// MARK: - Request

/// A fully received request. `path` is percent-decoded and normalized; `query`
/// is the raw query string (no endpoint takes one, and the router rejects any
/// request that carries one rather than ignoring it silently).
struct HTTPRequest: Sendable, Equatable {
    var method: HTTPMethod
    var path: String
    var query: String?
    var headers: HTTPHeaders
    var body: [UInt8]

    /// The body decoded as UTF-8, or nil if it is not valid UTF-8. Callers
    /// treat nil as a 400 rather than substituting replacement characters.
    var bodyText: String? {
        guard !body.isEmpty else { return "" }
        return String(bytes: body, encoding: .utf8)
    }
}

// MARK: - Status

/// Only the statuses this API actually emits. A closed set keeps the error
/// vocabulary documentable — the README has to list every one of these.
enum HTTPStatus: Int, Sendable, Equatable {
    case ok = 200
    case accepted = 202
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case methodNotAllowed = 405
    case requestTimeout = 408
    case conflict = 409
    case payloadTooLarge = 413
    case uriTooLong = 414
    case unsupportedMediaType = 415
    case requestHeaderFieldsTooLarge = 431
    case internalServerError = 500
    case notImplemented = 501
    case serviceUnavailable = 503
    case httpVersionNotSupported = 505

    var reasonPhrase: String {
        switch self {
        case .ok: "OK"
        case .accepted: "Accepted"
        case .badRequest: "Bad Request"
        case .unauthorized: "Unauthorized"
        case .forbidden: "Forbidden"
        case .notFound: "Not Found"
        case .methodNotAllowed: "Method Not Allowed"
        case .requestTimeout: "Request Timeout"
        case .conflict: "Conflict"
        case .payloadTooLarge: "Payload Too Large"
        case .uriTooLong: "URI Too Long"
        case .unsupportedMediaType: "Unsupported Media Type"
        case .requestHeaderFieldsTooLarge: "Request Header Fields Too Large"
        case .internalServerError: "Internal Server Error"
        case .notImplemented: "Not Implemented"
        case .serviceUnavailable: "Service Unavailable"
        case .httpVersionNotSupported: "HTTP Version Not Supported"
        }
    }
}

// MARK: - Response

/// A response, serialized on demand. Every response closes its connection
/// (`Connection: close`): one request per connection means there is no
/// pipelining state to desynchronize and no keep-alive timer to leak a socket,
/// which is worth far more here than the round-trip a Stream Deck saves.
struct HTTPResponse: Sendable, Equatable {
    var status: HTTPStatus
    /// Extra headers beyond the always-present set below. Order is preserved.
    var extraHeaders: [HTTPHeaderField]
    var body: [UInt8]
    var contentType: String

    init(status: HTTPStatus,
         json body: [UInt8] = [],
         extraHeaders: [HTTPHeaderField] = []) {
        self.status = status
        self.body = body
        self.extraHeaders = extraHeaders
        self.contentType = "application/json; charset=utf-8"
    }

    /// - Parameter suppressBody: true for a HEAD response. `Content-Length`
    ///   still describes the body the equivalent GET would have returned,
    ///   which is the whole point of HEAD.
    func serialized(suppressBody: Bool = false) -> Data {
        var head = "HTTP/1.1 \(status.rawValue) \(status.reasonPhrase)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // This is a machine-to-machine control API for a webcam. It must never
        // become a surface a web page can drive, so: no CORS headers ever, and
        // nothing about a response may be cached or content-type-sniffed.
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n"
        for field in extraHeaders {
            head += "\(field.name): \(field.value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if !suppressBody {
            data.append(contentsOf: body)
        }
        return data
    }
}
