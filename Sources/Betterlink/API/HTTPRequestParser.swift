import Foundation

// Incremental HTTP/1.1 request parser for the local control API.
//
// The governing rule in this file is: bound it before you allocate against it.
// A socket is an unbounded source of bytes that a stranger controls, so every
// growth point here has a ceiling that is checked *before* the append that
// would cross it, and every ceiling has a distinct error so the caller can say
// which one was hit. Nothing in here reaches for the camera, the Keychain or
// the network — it is pure bytes in, `HTTPRequest` out, which is what makes it
// testable without hardware (Checks/APIProtocolCheck.swift).

/// Every ceiling the parser enforces, in one place so the defaults are
/// reviewable as a set rather than scattered through the parsing code.
struct HTTPLimits: Sendable, Equatable {
    /// Longest `METHOD SP target SP HTTP/1.1` line. Our longest real target is
    /// `/presets/<uuid>/apply` at 55 bytes.
    var maxRequestLineBytes = 8 * 1024
    /// Most header fields in one request. Browsers send ~15; a Stream Deck
    /// sends ~6.
    var maxHeaderCount = 64
    /// Total bytes of the header block (everything after the request line up
    /// to and including the blank line that ends it).
    var maxHeaderBlockBytes = 16 * 1024
    /// Largest declared `Content-Length` we will accept. Our largest real body
    /// is a controls patch of a few hundred bytes; 16 KiB is already generous.
    /// A larger declared length is refused the moment the head is parsed,
    /// before a single body byte is read off the socket.
    var maxBodyBytes = 16 * 1024
    /// Largest single chunk `append(_:)` will take. The connection layer reads
    /// in chunks no bigger than this, so the parser's buffer can never
    /// overshoot a ceiling by more than one chunk.
    var maxChunkBytes = 16 * 1024

    /// The parser refuses to buffer more head than this before it has found
    /// the blank line that ends it. +4 for the terminating CRLFCRLF itself.
    var maxHeadBytes: Int { maxRequestLineBytes + maxHeaderBlockBytes + 4 }
}

/// Why a request was refused at the protocol level, with the status each one
/// maps to. Kept as data rather than as ad-hoc `throw`s at the call sites so
/// the check can assert the mapping — a limit that reports the wrong status is
/// a limit nobody will notice is firing.
enum HTTPRequestError: Error, Equatable, CustomStringConvertible {
    case chunkTooLarge
    case requestLineTooLong
    case headersTooLarge
    case tooManyHeaders
    case malformedRequestLine
    case unsupportedMethod(String)
    case unsupportedVersion(String)
    case malformedTarget
    case malformedHeader
    case duplicateContentLength
    case malformedContentLength
    case bodyTooLarge
    case transferEncodingNotSupported
    case malformedLineEnding

    var status: HTTPStatus {
        switch self {
        case .chunkTooLarge: .payloadTooLarge
        case .requestLineTooLong: .uriTooLong
        case .headersTooLarge, .tooManyHeaders: .requestHeaderFieldsTooLarge
        case .malformedRequestLine, .malformedTarget, .malformedHeader,
             .duplicateContentLength, .malformedContentLength, .malformedLineEnding: .badRequest
        case .unsupportedMethod: .notImplemented
        case .unsupportedVersion: .httpVersionNotSupported
        case .bodyTooLarge: .payloadTooLarge
        case .transferEncodingNotSupported: .notImplemented
        }
    }

    /// Stable machine-readable code for the JSON error body.
    var code: String {
        switch self {
        case .chunkTooLarge, .bodyTooLarge: "body_too_large"
        case .requestLineTooLong: "request_line_too_long"
        case .headersTooLarge: "headers_too_large"
        case .tooManyHeaders: "too_many_headers"
        case .malformedRequestLine: "malformed_request_line"
        case .unsupportedMethod: "unsupported_method"
        case .unsupportedVersion: "unsupported_version"
        case .malformedTarget: "malformed_target"
        case .malformedHeader: "malformed_header"
        case .duplicateContentLength: "duplicate_content_length"
        case .malformedContentLength: "malformed_content_length"
        case .transferEncodingNotSupported: "transfer_encoding_not_supported"
        case .malformedLineEnding: "malformed_line_ending"
        }
    }

    var description: String {
        switch self {
        case .chunkTooLarge:
            "The request sent more data in one read than the server accepts."
        case .requestLineTooLong:
            "The request line exceeds the server's limit."
        case .headersTooLarge:
            "The request headers exceed the server's size limit."
        case .tooManyHeaders:
            "The request has more header fields than the server accepts."
        case .malformedRequestLine:
            "The request line is not METHOD SP target SP HTTP-version."
        case .unsupportedMethod(let method):
            "The \(method) method is not implemented."
        case .unsupportedVersion(let version):
            "\(version) is not supported; use HTTP/1.1."
        case .malformedTarget:
            "The request target must be an absolute path with no '..' or empty segments."
        case .malformedHeader:
            "A header field is malformed."
        case .duplicateContentLength:
            "The request carries conflicting Content-Length header fields."
        case .malformedContentLength:
            "Content-Length is not a non-negative decimal integer."
        case .bodyTooLarge:
            "The request body exceeds the server's size limit."
        case .transferEncodingNotSupported:
            "Transfer-Encoding is not supported; send a Content-Length instead."
        case .malformedLineEnding:
            "Request lines must end with CRLF."
        }
    }
}

/// Feed it bytes as they arrive; it reports `.needMoreData` until exactly one
/// complete request has been read, then `.complete`. It never reads ahead past
/// the declared `Content-Length`, so a pipelined second request is simply left
/// unread — which is correct, because every response closes the connection.
struct HTTPRequestParser {
    enum Step: Equatable {
        case needMoreData
        case complete(HTTPRequest)
    }

    /// The head, once parsed, plus how much body is still owed.
    private struct PendingBody {
        var method: HTTPMethod
        var path: String
        var query: String?
        var headers: HTTPHeaders
        var expectedLength: Int
    }

    private let limits: HTTPLimits
    /// Head bytes while the head is still being read; body bytes afterwards.
    private var buffer: [UInt8] = []
    private var pending: PendingBody?
    private var isFinished = false

    init(limits: HTTPLimits = HTTPLimits()) {
        self.limits = limits
    }

    /// How many bytes the parser is currently holding. Exists so
    /// Checks/APIProtocolCheck.swift can prove the ceilings above are real
    /// bounds on memory and not just error messages — a limit that fires only
    /// after the allocation it was meant to prevent is not a limit.
    var bufferedByteCount: Int { buffer.count }

    /// Adds a chunk read off the socket and reports whether a request is ready.
    /// Throws the first ceiling it crosses; the caller must then write the
    /// mapped error response and close — a parser that has thrown is spent.
    mutating func append<Bytes: Collection>(_ bytes: Bytes) throws(HTTPRequestError) -> Step
    where Bytes.Element == UInt8 {
        // A single oversized read is refused before it is copied anywhere.
        // With this in place the buffer can only ever overshoot a ceiling by
        // at most one chunk, which is what makes every other bound below a
        // real bound rather than an aspiration.
        guard bytes.count <= limits.maxChunkBytes else { throw .chunkTooLarge }
        guard !isFinished else { return .needMoreData }

        if pending == nil {
            // Resume the scan near where the last one stopped instead of
            // restarting at zero. Rescanning the whole buffer on every append
            // is O(n^2) in the number of reads, which an unauthenticated peer
            // can drive by dribbling the head one byte at a time — bounded
            // memory, unbounded CPU. Backing up three bytes catches a
            // terminator straddling the chunk boundary.
            let scanStart = max(0, buffer.count - 3)
            buffer.append(contentsOf: bytes)
            guard let terminator = Self.indexOfHeadTerminator(in: buffer, from: scanStart) else {
                // No blank line yet. Refuse to keep buffering a head that has
                // already outgrown its ceiling — this is the case that would
                // otherwise let a client that never sends CRLFCRLF eat memory.
                if buffer.count > limits.maxHeadBytes { throw .headersTooLarge }
                return .needMoreData
            }
            guard terminator + 4 <= limits.maxHeadBytes else { throw .headersTooLarge }
            let head = Array(buffer[0..<terminator])
            let rest = Array(buffer[(terminator + 4)...])
            let parsed = try Self.parseHead(head, limits: limits)
            buffer = rest
            pending = parsed
        } else {
            buffer.append(contentsOf: bytes)
        }

        guard let pending else { return .needMoreData }
        guard buffer.count >= pending.expectedLength else { return .needMoreData }
        isFinished = true
        return .complete(HTTPRequest(method: pending.method,
                                     path: pending.path,
                                     query: pending.query,
                                     headers: pending.headers,
                                     body: Array(buffer[0..<pending.expectedLength])))
    }

    // MARK: - Head parsing

    /// Index of the CRLFCRLF that ends the head, or nil. `start` is where to
    /// begin looking; earlier bytes have already been scanned by a previous
    /// call and cannot contain an unseen terminator.
    private static func indexOfHeadTerminator(in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= 4 else { return nil }
        let first = max(0, start)
        guard first <= bytes.count - 4 else { return nil }
        for index in first...(bytes.count - 4) where bytes[index] == 0x0D && bytes[index + 1] == 0x0A
            && bytes[index + 2] == 0x0D && bytes[index + 3] == 0x0A {
            return index
        }
        return nil
    }

    private static func parseHead(_ head: [UInt8],
                                  limits: HTTPLimits) throws(HTTPRequestError) -> PendingBody {
        // The head is ASCII by definition; a non-ASCII byte in a header name,
        // a header value or the target is a smuggling smell, not a charset
        // problem, so it is refused rather than decoded leniently.
        for byte in head where byte >= 0x80 || (byte < 0x20 && byte != 0x0D && byte != 0x0A && byte != 0x09) {
            throw .malformedHeader
        }
        let lines = try splitCRLF(head)
        guard let requestLine = lines.first else { throw .malformedRequestLine }
        guard requestLine.count <= limits.maxRequestLineBytes else { throw .requestLineTooLong }

        let headerLines = Array(lines.dropFirst())
        guard headerLines.count <= limits.maxHeaderCount else { throw .tooManyHeaders }
        // The head we were handed is the request line plus the header block;
        // charge everything after the request line's CRLF against the block.
        let headerBlockBytes = head.count - requestLine.count - 2 + 4
        guard headerBlockBytes <= limits.maxHeaderBlockBytes else { throw .headersTooLarge }

        let (method, target, version) = try parseRequestLine(requestLine)
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            throw .unsupportedVersion(version)
        }
        let (path, query) = try parseTarget(target)

        var headers = HTTPHeaders()
        for line in headerLines {
            let (name, value) = try parseHeaderLine(line)
            headers.append(name: name, value: value)
        }

        // Chunked (or any other) transfer coding is not implemented, and a
        // request that carries both Transfer-Encoding and Content-Length is
        // the classic smuggling shape — refuse the whole family outright.
        guard !headers.contains("transfer-encoding") else { throw .transferEncodingNotSupported }

        let lengths = headers.all("content-length")
        var expectedLength = 0
        if !lengths.isEmpty {
            guard Set(lengths).count == 1 else { throw .duplicateContentLength }
            guard let declared = parseDecimal(lengths[0]) else { throw .malformedContentLength }
            // Refused here, on the head alone — before one byte of the body
            // has been read off the socket, let alone buffered.
            guard declared <= limits.maxBodyBytes else { throw .bodyTooLarge }
            expectedLength = declared
        }

        return PendingBody(method: method, path: path, query: query,
                           headers: headers, expectedLength: expectedLength)
    }

    /// Splits on CRLF, refusing a bare LF. Obs-folded continuation lines
    /// (RFC 9112 §5.2, a line beginning with SP or HTAB) are refused too:
    /// they are deprecated and they are how header parsers disagree.
    private static func splitCRLF(_ bytes: [UInt8]) throws(HTTPRequestError) -> [String] {
        var lines: [String] = []
        var current: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D {
                guard index + 1 < bytes.count, bytes[index + 1] == 0x0A else {
                    throw .malformedLineEnding
                }
                lines.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
                index += 2
                continue
            }
            // A bare LF never terminates a line here.
            guard byte != 0x0A else { throw .malformedLineEnding }
            current.append(byte)
            index += 1
        }
        if !current.isEmpty { lines.append(String(decoding: current, as: UTF8.self)) }
        for line in lines.dropFirst() where line.hasPrefix(" ") || line.hasPrefix("\t") {
            throw .malformedHeader
        }
        return lines
    }

    private static func parseRequestLine(
        _ line: String
    ) throws(HTTPRequestError) -> (HTTPMethod, String, String) {
        // Exactly two single spaces: no tabs, no runs, no trailing space.
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else {
            throw .malformedRequestLine
        }
        guard let method = HTTPMethod(rawValue: String(parts[0])) else {
            throw .unsupportedMethod(String(parts[0]).prefix(16).description)
        }
        return (method, String(parts[1]), String(parts[2]))
    }

    /// Origin-form targets only (`/path` or `/path?query`). Absolute-form
    /// (`http://host/path`), authority-form and `*` are all refused: accepting
    /// them means deciding whose `Host` wins, and this server never needs to.
    private static func parseTarget(_ target: String) throws(HTTPRequestError) -> (String, String?) {
        guard target.hasPrefix("/") else { throw .malformedTarget }
        let rawPath: String
        let query: String?
        if let mark = target.firstIndex(of: "?") {
            rawPath = String(target[target.startIndex..<mark])
            query = String(target[target.index(after: mark)...])
        } else {
            rawPath = target
            query = nil
        }
        let decoded = try percentDecode(rawPath)
        guard !decoded.contains("\0") else { throw .malformedTarget }
        // Path traversal and empty segments are refused rather than
        // normalized away: this router only ever matches fixed paths, so a
        // target that needs normalizing is a probe, not a typo. The single
        // exception is one trailing slash, which is normalized off so that
        // `/presets` and `/presets/` are the same route — `//presets` and
        // `/presets//` are still refused.
        var segments = decoded.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        if segments.last == "" { segments = segments.dropLast() }
        for segment in segments where segment.isEmpty || segment == "." || segment == ".." {
            throw .malformedTarget
        }
        var path = decoded
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return (path, query)
    }

    private static func percentDecode(_ text: String) throws(HTTPRequestError) -> String {
        guard text.contains("%") else { return text }
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8).makeIterator()
        var pendingByte = iterator.next()
        while let byte = pendingByte {
            if byte == UInt8(ascii: "%") {
                guard let high = iterator.next(), let low = iterator.next(),
                      let highValue = hexValue(high), let lowValue = hexValue(low) else {
                    throw .malformedTarget
                }
                bytes.append(highValue << 4 | lowValue)
            } else {
                bytes.append(byte)
            }
            pendingByte = iterator.next()
        }
        // A percent escape that decodes to something that is not UTF-8 is
        // refused; substituting U+FFFD would let two different byte strings
        // match the same route.
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { throw .malformedTarget }
        return decoded
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    private static func parseHeaderLine(
        _ line: String
    ) throws(HTTPRequestError) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { throw .malformedHeader }
        let name = String(line[line.startIndex..<colon])
        // "No whitespace is allowed between the field name and colon"
        // (RFC 9112 §5.1) — a server that tolerates it is a smuggling gadget.
        guard !name.isEmpty, isToken(name) else { throw .malformedHeader }
        let value = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return (name, value)
    }

    /// RFC 9110 §5.6.2 token characters.
    private static func isToken(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let allowed = Set("!#$%&'*+-.^_`|~")
        for character in text {
            guard character.isASCII else { return false }
            if character.isLetter || character.isNumber || allowed.contains(character) { continue }
            return false
        }
        return true
    }

    /// A non-negative decimal with no sign, no whitespace and no `+`.
    /// `Int(_:)` alone would accept "-1" and " 12".
    private static func parseDecimal(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 19,
              text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }
}
