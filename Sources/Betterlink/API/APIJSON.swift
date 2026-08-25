import Foundation

// JSON in and out for the control API, plus the one error shape every failure
// takes. Foundation's JSONSerialization rather than Codable on purpose:
// request bodies here have to *reject* unknown keys, and Codable's default is
// to ignore them silently — which is the opposite of what a control surface
// wants. Silently dropping `{"brightnes": 80}` is how a user concludes the
// API is broken.

/// A refusal, with everything the wire needs. Every non-2xx response in this
/// API is built from one of these, so the error vocabulary is a closed set the
/// README can list in full.
struct APIFault: Error, Sendable {
    var status: HTTPStatus
    /// Stable, machine-readable. Clients branch on this, not on the prose.
    var code: String
    var message: String
    var extraHeaders: [HTTPHeaderField] = []

    var response: HTTPResponse {
        HTTPResponse(status: status,
                     json: APIJSON.encode(["error": ["code": code, "message": message]]),
                     extraHeaders: extraHeaders)
    }

    static func badRequest(_ code: String, _ message: String) -> APIFault {
        APIFault(status: .badRequest, code: code, message: message)
    }

    static func conflict(_ code: String, _ message: String) -> APIFault {
        APIFault(status: .conflict, code: code, message: message)
    }

    /// The camera is not attached, or its controls have not been read yet.
    /// 503 rather than 400: nothing is wrong with the request, and retrying it
    /// later is exactly the right thing for a client to do.
    static func cameraUnavailable(_ message: String) -> APIFault {
        APIFault(status: .serviceUnavailable, code: "camera_unavailable", message: message)
    }
}

enum APIJSON {
    /// Serializes a response body. Sorted keys so responses are byte-stable
    /// and diffable; unescaped slashes so file paths stay readable.
    ///
    /// Non-throwing by design: a response body this code built itself failing
    /// to serialize is a programming error, and the fallback keeps the
    /// connection answering something well-formed instead of hanging.
    static func encode(_ object: [String: Any]) -> [UInt8] {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return Array(#"{"error":{"code":"encoding_failed","message":"Response could not be encoded."}}"#.utf8)
        }
        return Array(data)
    }

    /// Nesting ceiling for request bodies. Every body this API accepts is a
    /// flat object of scalars, so 4 is already slack. The point is that
    /// `JSONSerialization` is handed a shape whose depth is known-bounded
    /// before it starts descending it.
    static let maxRequestDepth = 4

    /// Parses a request body that must be a JSON object.
    /// - Parameter required: false for endpoints where an empty body is fine.
    static func requestObject(_ request: HTTPRequest,
                              required: Bool) throws(APIFault) -> [String: Any] {
        if request.body.isEmpty {
            guard required else { return [:] }
            throw .badRequest("body_required", "This endpoint requires a JSON object body.")
        }
        // A body means a declared content type, and it must be the one we
        // documented. Accepting anything at all here is what makes a browser's
        // `text/plain` form POST a usable request.
        guard let contentType = request.headers.first("content-type") else {
            throw APIFault(status: .unsupportedMediaType, code: "content_type_required",
                           message: "A request with a body must declare Content-Type: application/json.")
        }
        let base = contentType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard base == "application/json" else {
            throw APIFault(status: .unsupportedMediaType, code: "unsupported_media_type",
                           message: "Content-Type must be application/json, not '\(contentType)'.")
        }
        guard depth(of: request.body) <= maxRequestDepth else {
            throw .badRequest("body_too_deeply_nested",
                              "Request bodies must be a flat JSON object of scalar values.")
        }
        guard request.bodyText != nil else {
            throw .badRequest("malformed_body", "The request body is not valid UTF-8.")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(request.body)) else {
            throw .badRequest("malformed_json", "The request body is not valid JSON.")
        }
        guard let object = parsed as? [String: Any] else {
            throw .badRequest("malformed_json", "The request body must be a JSON object.")
        }
        return object
    }

    /// Maximum `{`/`[` nesting, counted over the raw bytes with string
    /// literals skipped, so a brace inside a string does not inflate it.
    /// Cheap and allocation-free — it runs before the parser does.
    static func depth(of body: [UInt8]) -> Int {
        var depth = 0
        var maximum = 0
        var inString = false
        var escaped = false
        for byte in body {
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                maximum = max(maximum, depth)
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default: break
            }
        }
        return maximum
    }

    // MARK: Typed field readers
    //
    // Each of these rejects rather than coerces: a wrong type, a missing key
    // and an out-of-range value are all distinct 400s, and none of them ever
    // clamps a value on its way to the camera.

    static func requireDouble(_ object: [String: Any], _ key: String,
                              in range: ClosedRange<Double>) throws(APIFault) -> Double {
        guard let raw = object[key] else {
            throw .badRequest("missing_field", "'\(key)' is required.")
        }
        // NSNumber covers both JSON integers and JSON reals; Bool is an
        // NSNumber too, and `true` is not a number anybody meant.
        guard let number = raw as? NSNumber, !(raw is Bool) else {
            throw .badRequest("invalid_type", "'\(key)' must be a number.")
        }
        let value = number.doubleValue
        guard value.isFinite else {
            throw .badRequest("invalid_value", "'\(key)' must be a finite number.")
        }
        guard range.contains(value) else {
            throw .badRequest("out_of_range",
                              "'\(key)' is \(trim(value)) but the camera accepts "
                                  + "\(trim(range.lowerBound))…\(trim(range.upperBound)).")
        }
        return value
    }

    /// A whole number in range. Deliberately separate from `requireDouble`:
    /// `durationMs` is a count of milliseconds, and silently rounding 1500.7
    /// into 1501 would be exactly the kind of quiet coercion this API refuses
    /// everywhere else.
    static func requireInt(_ object: [String: Any], _ key: String,
                           in range: ClosedRange<Int>) throws(APIFault) -> Int {
        guard let raw = object[key] else {
            throw .badRequest("missing_field", "'\(key)' is required.")
        }
        guard let number = raw as? NSNumber, !(raw is Bool) else {
            throw .badRequest("invalid_type", "'\(key)' must be a number.")
        }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value,
              value >= Double(Int.min), value <= Double(Int.max) else {
            throw .badRequest("invalid_type", "'\(key)' must be a whole number.")
        }
        let integer = Int(value)
        guard range.contains(integer) else {
            throw .badRequest("out_of_range",
                              "'\(key)' is \(integer) but must be "
                                  + "\(range.lowerBound)…\(range.upperBound).")
        }
        return integer
    }

    static func requireBool(_ object: [String: Any], _ key: String) throws(APIFault) -> Bool {
        guard let raw = object[key] else {
            throw .badRequest("missing_field", "'\(key)' is required.")
        }
        guard let value = raw as? Bool else {
            throw .badRequest("invalid_type", "'\(key)' must be true or false.")
        }
        return value
    }

    static func requireString(_ object: [String: Any], _ key: String,
                              oneOf allowed: [String]) throws(APIFault) -> String {
        guard let raw = object[key] else {
            throw .badRequest("missing_field", "'\(key)' is required.")
        }
        guard let value = raw as? String else {
            throw .badRequest("invalid_type", "'\(key)' must be a string.")
        }
        guard allowed.contains(value) else {
            throw .badRequest("invalid_value",
                              "'\(key)' must be one of \(allowed.map { "'\($0)'" }.joined(separator: ", ")).")
        }
        return value
    }

    /// Refuses any key the endpoint does not define, so a typo is a 400 rather
    /// than a write that silently did not happen.
    static func rejectUnknownKeys(_ object: [String: Any],
                                  allowed: Set<String>) throws(APIFault) {
        let unknown = Set(object.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw .badRequest("unknown_field",
                              "Unrecognized field(s): \(unknown.map { "'\($0)'" }.joined(separator: ", ")). "
                                  + "Allowed: \(allowed.sorted().map { "'\($0)'" }.joined(separator: ", ")).")
        }
    }

    /// Doubles are rounded before they go on the wire so a control value
    /// reads as `50` rather than `50.000000000000007`.
    static func trim(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}
