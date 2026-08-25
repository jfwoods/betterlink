import Foundation
import Network

// Runnable check for the local REST API's wire protocol and trust boundary:
// the HTTP/1.1 parser, its ceilings, the bearer-token authorization, the
// browser/rebinding policy, and the request-body validators. Not part of the
// app target and it never touches the camera, the network or the Keychain —
// compile and run it with the bare toolchain:
//
//   swiftc -swift-version 6 -parse-as-library \
//     Sources/Betterlink/API/HTTPMessage.swift \
//     Sources/Betterlink/API/HTTPRequestParser.swift \
//     Sources/Betterlink/API/APIAuthorization.swift \
//     Sources/Betterlink/API/APIJSON.swift \
//     Sources/Betterlink/API/GimbalDrivePolicy.swift \
//     Sources/Betterlink/Transport/UVCTypes.swift \
//     Sources/Betterlink/Controls/GimbalJoystick.swift \
//     Sources/Betterlink/API/APIListenerFactory.swift \
//     Checks/APIProtocolCheck.swift \
//     -o /tmp/api-check && /tmp/api-check
//
// Every token in this file is a made-up fixture. No real credential is ever
// committed to this repository, in code, in a comment, or in a test.

@main
struct APIProtocolCheck {
    // Obviously-fake fixtures. The real token is 43 base64url characters from
    // SecRandomCopyBytes and lives only in the Keychain.
    static let goodToken = "FIXTURE-token-not-a-real-credential-00000000"
    static let wrongToken = "FIXTURE-token-not-a-real-credential-00000001"

    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("ok   \(label)")
        } else {
            failures += 1
            print("FAIL \(label)")
        }
    }

    @MainActor
    static func main() async {
        checkHappyPath()
        checkBounds()
        checkMalformed()
        checkAuthorization()
        checkTransportPolicy()
        checkResponses()
        checkBodyValidation()
        checkGimbalDurationArithmetic()
        checkGimbalOwnershipAnswers()
        checkListenerConstruction()
        await checkGimbalDeadMan()

        if failures > 0 {
            print("\(failures) check(s) FAILED")
            exit(1)
        }
        print("All API protocol checks passed.")
    }

    // MARK: - Helpers

    /// Feeds a whole request in one chunk.
    static func parse(_ text: String,
                      limits: HTTPLimits = HTTPLimits()) -> Result<HTTPRequest, HTTPRequestError> {
        var parser = HTTPRequestParser(limits: limits)
        do {
            switch try parser.append(Array(text.utf8)) {
            case .complete(let request): return .success(request)
            case .needMoreData: return .failure(.malformedRequestLine)
            }
        } catch {
            return .failure(error)
        }
    }

    static func error(_ result: Result<HTTPRequest, HTTPRequestError>) -> HTTPRequestError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    static func request(_ result: Result<HTTPRequest, HTTPRequestError>) -> HTTPRequest? {
        if case .success(let request) = result { return request }
        return nil
    }

    /// A minimal well-formed request with a trusted Host and a valid token.
    static func wellFormed(method: String = "GET", target: String = "/status",
                           extraHeaders: [String] = [], body: String = "") -> String {
        var lines = ["\(method) \(target) HTTP/1.1",
                     "Host: 127.0.0.1:8787",
                     "Authorization: Bearer \(goodToken)"]
        if !body.isEmpty {
            lines.append("Content-Type: application/json")
            lines.append("Content-Length: \(body.utf8.count)")
        }
        lines += extraHeaders
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    // MARK: - 1. Well-formed requests parse

    static func checkHappyPath() {
        print("-- well-formed requests")

        let simple = parse(wellFormed())
        if let parsed = request(simple) {
            expect(parsed.method == .get, "GET method parses")
            expect(parsed.path == "/status", "path parses")
            expect(parsed.query == nil, "no query string")
            expect(parsed.body.isEmpty, "no body")
            expect(parsed.headers.first("HOST") == "127.0.0.1:8787",
                   "header lookup is case-insensitive")
            expect(parsed.headers.first("authorization")?.hasPrefix("Bearer ") == true,
                   "Authorization survives parsing")
        } else {
            expect(false, "well-formed GET parses (got \(String(describing: error(simple))))")
        }

        let body = #"{"factor":2.5}"#
        let put = parse(wellFormed(method: "PUT", target: "/zoom", body: body))
        if let parsed = request(put) {
            expect(parsed.method == .put, "PUT method parses")
            expect(parsed.body == Array(body.utf8), "body bytes are exact")
            expect(parsed.bodyText == body, "body decodes as UTF-8")
            expect(parsed.headers.first("content-length") == "14", "Content-Length parses")
        } else {
            expect(false, "well-formed PUT with a body parses (got \(String(describing: error(put))))")
        }

        // The same request delivered one byte at a time must produce the same
        // result: a socket does not respect message boundaries.
        var dribbled = HTTPRequestParser()
        var reassembled: HTTPRequest?
        for byte in Array(wellFormed(method: "PUT", target: "/zoom", body: body).utf8) {
            if case .complete(let parsed) = (try? dribbled.append([byte])) ?? .needMoreData {
                reassembled = parsed
            }
        }
        expect(reassembled?.body == Array(body.utf8), "byte-at-a-time delivery parses identically")

        expect(request(parse(wellFormed(target: "/presets/")))?.path == "/presets",
               "one trailing slash is normalized away")
        let queried = request(parse(wellFormed(target: "/status?verbose=1")))
        expect(queried?.path == "/status" && queried?.query == "verbose=1",
               "query string splits off the path")
        expect(request(parse(wellFormed(method: "HEAD")))?.method.routesAs == .get,
               "HEAD routes as GET")
        expect(request(parse(wellFormed(target: "/")))?.path == "/",
               "root path survives normalization")

        // The head scan resumes near where it left off rather than restarting,
        // so the one thing that could break it is a CRLFCRLF split across two
        // reads. Try every split point of a request whose head ends mid-chunk.
        let splittable = Array(wellFormed(method: "PUT", target: "/zoom",
                                          body: #"{"factor":1.0}"#).utf8)
        var straddled = 0
        for split in 1..<splittable.count {
            var parser = HTTPRequestParser()
            var parsed: HTTPRequest?
            for chunk in [Array(splittable[0..<split]), Array(splittable[split...])] {
                if case .complete(let done) = (try? parser.append(chunk)) ?? .needMoreData {
                    parsed = done
                }
            }
            if parsed?.path == "/zoom" && parsed?.body.count == 14 { straddled += 1 }
        }
        expect(straddled == splittable.count - 1,
               "the resumed head scan finds a terminator at every chunk boundary "
                   + "(\(straddled)/\(splittable.count - 1))")
    }

    // MARK: - 2. Bounds — rejected rather than allocated

    static func checkBounds() {
        print("-- bounds")

        // One ceiling per limits object: with a small `maxChunkBytes` here, a
        // whole-request feed would trip the chunk ceiling first and every case
        // below would pass for the wrong reason.
        var tight = HTTPLimits()
        tight.maxRequestLineBytes = 64
        tight.maxHeaderBlockBytes = 256
        tight.maxHeaderCount = 4
        tight.maxBodyBytes = 64
        tight.maxChunkBytes = 8 * 1024

        // Oversized request line.
        let longTarget = "/" + String(repeating: "a", count: 200)
        let longLine = "GET \(longTarget) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        expect(error(parse(longLine, limits: tight)) == .requestLineTooLong,
               "an oversized request line is refused")
        expect(HTTPRequestError.requestLineTooLong.status == .uriTooLong,
               "an oversized request line maps to 414")

        // Too many header fields.
        let manyHeaders = (0..<10).map { "X-Filler-\($0): v" }.joined(separator: "\r\n")
        let tooMany = "GET /status HTTP/1.1\r\nHost: 127.0.0.1\r\n\(manyHeaders)\r\n\r\n"
        expect(error(parse(tooMany, limits: tight)) == .tooManyHeaders,
               "too many header fields is refused")
        expect(HTTPRequestError.tooManyHeaders.status == .requestHeaderFieldsTooLarge,
               "too many header fields maps to 431")

        // An oversized header block, within the field-count limit.
        var wide = tight
        wide.maxHeaderCount = 64
        let fat = "GET /s HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Fat: \(String(repeating: "b", count: 400))\r\n\r\n"
        expect(error(parse(fat, limits: wide)) == .headersTooLarge,
               "an oversized header block is refused")

        // A head that never terminates must be refused *while* it is arriving,
        // with the buffer still bounded — this is the memory-exhaustion case.
        // Small chunks here so the bound asserted below is a tight one.
        var starve = tight
        starve.maxChunkBytes = 64
        var starving = HTTPRequestParser(limits: starve)
        var starvingError: HTTPRequestError?
        var peak = 0
        for _ in 0..<200 {
            do {
                _ = try starving.append([UInt8](repeating: UInt8(ascii: "x"), count: 64))
                peak = max(peak, starving.bufferedByteCount)
            } catch {
                starvingError = error
                peak = max(peak, starving.bufferedByteCount)
                break
            }
        }
        expect(starvingError == .headersTooLarge,
               "a head that never terminates is refused")
        expect(peak <= starve.maxHeadBytes + starve.maxChunkBytes,
               "the never-terminating head stayed bounded (peak \(peak) bytes)")

        // A declared body over the cap is refused on the head alone, before a
        // single body byte is offered.
        var bodyParser = HTTPRequestParser(limits: tight)
        let hugeHead = "POST /controls HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Content-Type: application/json\r\nContent-Length: 1048576\r\n\r\n"
        var bodyError: HTTPRequestError?
        do { _ = try bodyParser.append(Array(hugeHead.utf8)) } catch { bodyError = error }
        expect(bodyError == .bodyTooLarge, "an oversized declared body is refused")
        expect(HTTPRequestError.bodyTooLarge.status == .payloadTooLarge,
               "an oversized body maps to 413")
        expect(bodyParser.bufferedByteCount <= hugeHead.utf8.count,
               "the oversized body was refused before any body byte was buffered")

        // A single read larger than the chunk ceiling is refused before it is
        // copied anywhere.
        var chunkLimits = tight
        chunkLimits.maxChunkBytes = 128
        var chunked = HTTPRequestParser(limits: chunkLimits)
        var chunkError: HTTPRequestError?
        do {
            _ = try chunked.append([UInt8](repeating: 0x41, count: chunkLimits.maxChunkBytes + 1))
        } catch { chunkError = error }
        expect(chunkError == .chunkTooLarge, "an oversized single read is refused")
        expect(chunked.bufferedByteCount == 0, "the oversized read was never buffered")

        // A body exactly at the cap still works — the limit is a ceiling, not
        // an off-by-one that rejects legitimate requests.
        let exact = String(repeating: "x", count: tight.maxBodyBytes - 2)
        let atCap = "POST /c HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(tight.maxBodyBytes)\r\n\r\n\"\(exact)\""
        expect(request(parse(atCap, limits: tight))?.body.count == tight.maxBodyBytes,
               "a body exactly at the cap is accepted")
    }

    // MARK: - 3. Malformed requests

    static func checkMalformed() {
        print("-- malformed requests")

        let cases: [(String, HTTPRequestError, String)] = [
            ("GET /status\r\nHost: 127.0.0.1\r\n\r\n",
             .malformedRequestLine, "a two-part request line"),
            ("GET  /status HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
             .malformedRequestLine, "a doubled space in the request line"),
            ("GET /status HTTP/2.0\r\nHost: 127.0.0.1\r\n\r\n",
             .unsupportedVersion("HTTP/2.0"), "an unsupported HTTP version"),
            ("BREW /status HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
             .unsupportedMethod("BREW"), "an unknown method"),
            ("GET http://evil.example/status HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
             .malformedTarget, "an absolute-form target"),
            ("GET /../etc/passwd HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
             .malformedTarget, "a '..' path segment"),
            ("GET /presets//apply HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
             .malformedTarget, "an empty path segment"),
            ("GET //presets HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
             .malformedTarget, "a doubled leading slash"),
            ("GET /presets// HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
             .malformedTarget, "a doubled trailing slash"),
            ("GET /presets/./apply HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
             .malformedTarget, "a '.' path segment"),
            ("GET /%2e%2e/secrets HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
             .malformedTarget, "a percent-encoded '..' segment"),
            ("GET /%zz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
             .malformedTarget, "a malformed percent escape"),
            ("GET /status HTTP/1.1\r\nHost 127.0.0.1\r\n\r\n",
             .malformedHeader, "a header with no colon"),
            ("GET /status HTTP/1.1\r\nHost : 127.0.0.1\r\n\r\n",
             .malformedHeader, "whitespace before a header colon"),
            ("GET /status HTTP/1.1\r\nHost: 127.0.0.1\r\n  continued\r\n\r\n",
             .malformedHeader, "an obs-fold continuation line"),
            ("GET /status HTTP/1.1\nHost: 127.0.0.1\r\n\r\n",
             .malformedLineEnding, "a bare LF line ending"),
            ("POST /c HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabc",
             .duplicateContentLength, "conflicting Content-Length fields"),
            ("POST /c HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\n",
             .malformedContentLength, "a negative Content-Length"),
            ("POST /c HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 1 2\r\n\r\n",
             .malformedContentLength, "a non-numeric Content-Length"),
            ("POST /c HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n",
             .transferEncodingNotSupported, "a chunked Transfer-Encoding"),
        ]
        for (raw, expected, label) in cases {
            expect(error(parse(raw)) == expected, "refuses \(label)")
        }

        // Identical Content-Length fields are not a conflict.
        let duplicated = "POST /c HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}"
        expect(request(parse(duplicated))?.body.count == 2,
               "identical repeated Content-Length fields are accepted")

        expect(HTTPRequestError.unsupportedMethod("BREW").status == .notImplemented,
               "an unknown method maps to 501")
        expect(HTTPRequestError.unsupportedVersion("HTTP/2.0").status == .httpVersionNotSupported,
               "an unsupported version maps to 505")
        expect(HTTPRequestError.transferEncodingNotSupported.status == .notImplemented,
               "a transfer coding maps to 501")
    }

    // MARK: - 4. Authorization

    static func checkAuthorization() {
        print("-- authorization")

        func evaluate(_ headerLines: [String]) -> APIAuthorization.Outcome {
            var headers = HTTPHeaders()
            for line in headerLines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers.append(name: String(line[line.startIndex..<colon]),
                               value: String(line[line.index(after: colon)...])
                                   .trimmingCharacters(in: .whitespaces))
            }
            return APIAuthorization.evaluate(headers: headers, expectedToken: goodToken)
        }

        expect(evaluate([]) == .missingCredentials,
               "a request with no Authorization header is refused")
        expect(evaluate(["Authorization: Bearer \(wrongToken)"]) == .invalidToken,
               "a wrong token is refused")
        expect(evaluate(["Authorization: Bearer \(goodToken)"]) == .authorized,
               "the correct token is accepted")
        expect(evaluate(["authorization: bearer \(goodToken)"]) == .authorized,
               "the scheme and the header name are case-insensitive")
        expect(evaluate(["Authorization: Basic \(goodToken)"]) == .missingCredentials,
               "a non-bearer scheme is not credentials")
        expect(evaluate(["Authorization: \(goodToken)"]) == .missingCredentials,
               "a bare token with no scheme is not credentials")
        expect(evaluate(["Authorization: Bearer"]) == .missingCredentials,
               "a bearer scheme with no token is not credentials")
        expect(evaluate(["Authorization: Bearer \(goodToken)",
                         "Authorization: Bearer \(wrongToken)"]) == .invalidToken,
               "two Authorization headers are refused even when one is correct")

        // Prefix and length must not be distinguishable outcomes.
        expect(evaluate(["Authorization: Bearer \(String(goodToken.dropLast()))"]) == .invalidToken,
               "a token that is a prefix of the real one is refused")
        expect(evaluate(["Authorization: Bearer \(goodToken)x"]) == .invalidToken,
               "a token with the real one as a prefix is refused")
        expect(evaluate(["Authorization: Bearer x"]) == .invalidToken,
               "a one-character token is refused")

        expect(APIAuthorization.tokensMatch(presented: goodToken, expected: goodToken),
               "tokensMatch accepts an exact match")
        expect(!APIAuthorization.tokensMatch(presented: goodToken.uppercased(), expected: goodToken),
               "tokensMatch is case-sensitive on the token itself")

        expect(APIAuthorization.constantTimeEquals([1, 2, 3], [1, 2, 3]),
               "constantTimeEquals accepts equal bytes")
        expect(!APIAuthorization.constantTimeEquals([1, 2, 3], [1, 2, 4]),
               "constantTimeEquals rejects a one-byte difference")
        expect(!APIAuthorization.constantTimeEquals([1, 2, 3], [1, 2]),
               "constantTimeEquals rejects unequal lengths")
        expect(APIAuthorization.constantTimeEquals([], []),
               "constantTimeEquals accepts two empty buffers")

        // The challenge distinguishes "you sent nothing" from "you sent a bad
        // one", which is what RFC 6750 asks for, and nothing else.
        expect(APIAuthorization.Outcome.missingCredentials.challenge == #"Bearer realm="Betterlink""#,
               "a missing credential gets a bare Bearer challenge")
        expect(APIAuthorization.Outcome.invalidToken.challenge.contains("invalid_token"),
               "a bad credential gets an invalid_token challenge")
    }

    // MARK: - 5. Browser and rebinding policy

    static func checkTransportPolicy() {
        print("-- transport policy")

        func evaluate(_ headerLines: [String]) -> APIRequestPolicy.Rejection? {
            var headers = HTTPHeaders()
            for line in headerLines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers.append(name: String(line[line.startIndex..<colon]),
                               value: String(line[line.index(after: colon)...])
                                   .trimmingCharacters(in: .whitespaces))
            }
            return APIRequestPolicy.evaluate(
                HTTPRequest(method: .post, path: "/gimbal/stop", query: nil,
                            headers: headers, body: []))
        }

        expect(evaluate(["Host: 127.0.0.1:8787"]) == nil,
               "a loopback request with no Origin is allowed through")
        expect(evaluate(["Host: 127.0.0.1:8787", "Origin: https://example.com"]) == .browserOrigin,
               "a request carrying an Origin header is refused")
        expect(evaluate(["Host: 127.0.0.1:8787", "origin: null"]) == .browserOrigin,
               "an Origin of 'null' is still an Origin")
        expect(evaluate([]) == .missingHost, "a request with no Host header is refused")
        expect(evaluate(["Host: rebind.example.com:8787"])
                   == .untrustedHost("rebind.example.com:8787"),
               "a DNS name in Host is refused (rebinding defence)")
        expect(evaluate(["Host: 127.0.0.1", "Host: rebind.example.com"]) == .duplicateHost,
               "two Host headers are refused even when the first is trusted")
        expect(evaluate(["Host: rebind.example.com", "Host: 127.0.0.1"]) == .duplicateHost,
               "two Host headers are refused in either order")
        expect(APIRequestPolicy.Rejection.browserOrigin.status == .forbidden,
               "a policy rejection is a 403")

        let trusted = ["127.0.0.1", "127.0.0.1:8787", "localhost", "localhost:8787",
                       "LOCALHOST:8787", "192.168.1.42:8787", "10.0.0.5", "[::1]:8787",
                       "[fe80::1%en0]", "studio-mac.local:8787"]
        for host in trusted {
            expect(APIRequestPolicy.isTrustedHost(host), "Host '\(host)' is trusted")
        }
        let untrusted = ["evil.example.com", "example.com:8787", ".local", "127.0.0.1:0",
                         "127.0.0.1:99999", "999.1.1.1", "", "attacker.local.evil.com"]
        for host in untrusted {
            expect(!APIRequestPolicy.isTrustedHost(host), "Host '\(host)' is not trusted")
        }
    }

    // MARK: - 6. Responses

    static func checkResponses() {
        print("-- responses")

        let body = Array(#"{"ok":true}"#.utf8)
        let response = HTTPResponse(status: .ok, json: body)
        let text = String(decoding: response.serialized(), as: UTF8.self)
        expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"), "the status line is well-formed")
        expect(text.contains("Content-Length: \(body.count)\r\n"),
               "Content-Length matches the body")
        expect(text.contains("Connection: close\r\n"), "every response closes its connection")
        expect(text.contains("X-Content-Type-Options: nosniff\r\n"), "responses forbid sniffing")
        expect(text.contains("Cache-Control: no-store\r\n"), "responses are never cached")
        expect(text.hasSuffix(#"{"ok":true}"#), "the body follows the blank line")

        // No CORS, ever — on a success or on any refusal.
        let samples: [HTTPResponse] = [
            response,
            APIFault(status: .unauthorized, code: "unauthorized", message: "no").response,
            APIFault.cameraUnavailable("no camera").response,
            APIFault(status: .forbidden, code: "origin_not_allowed", message: "no").response,
        ]
        for sample in samples {
            let rendered = String(decoding: sample.serialized(), as: UTF8.self).lowercased()
            expect(!rendered.contains("access-control-"),
                   "a \(sample.status.rawValue) response carries no CORS header")
        }

        let head = String(decoding: response.serialized(suppressBody: true), as: UTF8.self)
        expect(head.contains("Content-Length: \(body.count)\r\n"),
               "a HEAD response keeps the Content-Length of the body it would have sent")
        expect(head.hasSuffix("\r\n\r\n"), "a HEAD response sends no body")

        let challenge = APIFault(
            status: .unauthorized, code: "unauthorized", message: "no",
            extraHeaders: [HTTPHeaderField(
                name: "WWW-Authenticate",
                value: APIAuthorization.Outcome.invalidToken.challenge)]).response
        let rendered = String(decoding: challenge.serialized(), as: UTF8.self)
        expect(rendered.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"), "a refused token is a 401")
        expect(rendered.contains("WWW-Authenticate: Bearer realm=\"Betterlink\""),
               "a 401 carries a Bearer challenge")
        expect(rendered.contains(#""code":"unauthorized""#), "errors carry a machine-readable code")
        // A 401 must be indistinguishable whatever the path was, or an
        // unauthenticated caller could enumerate preset ids by status code.
        expect(!rendered.contains("preset"), "a 401 body says nothing about what was requested")
    }

    // MARK: - 7. Request-body validation

    static func checkBodyValidation() {
        print("-- body validation")

        func post(_ body: String, contentType: String? = "application/json") -> HTTPRequest {
            var headers = HTTPHeaders()
            headers.append(name: "Host", value: "127.0.0.1")
            if let contentType { headers.append(name: "Content-Type", value: contentType) }
            return HTTPRequest(method: .patch, path: "/controls", query: nil,
                               headers: headers, body: Array(body.utf8))
        }

        func fault(_ work: () throws -> Void) -> APIFault? {
            do { try work(); return nil } catch let fault as APIFault { return fault }
            catch { return nil }
        }

        expect(fault { _ = try APIJSON.requestObject(post(#"{"brightness":60}"#), required: true) } == nil,
               "a well-formed JSON body is accepted")
        expect(fault { _ = try APIJSON.requestObject(post("not json"), required: true) }?.code
                   == "malformed_json",
               "a body that is not JSON is refused")
        expect(fault { _ = try APIJSON.requestObject(post("[1,2,3]"), required: true) }?.code
                   == "malformed_json",
               "a JSON array body is refused")
        expect(fault { _ = try APIJSON.requestObject(post(#"{"a":1}"#, contentType: "text/plain"),
                                                     required: true) }?.status
                   == .unsupportedMediaType,
               "a body with the wrong Content-Type is refused with 415")
        expect(fault { _ = try APIJSON.requestObject(post(#"{"a":1}"#, contentType: nil),
                                                     required: true) }?.code
                   == "content_type_required",
               "a body with no Content-Type at all is refused")
        expect(fault { _ = try APIJSON.requestObject(
            post(#"{"a":1}"#, contentType: "application/json; charset=utf-8"),
            required: true) } == nil,
               "a Content-Type with a charset parameter is accepted")
        expect(fault { _ = try APIJSON.requestObject(
            post(#"{"a":1}"#, contentType: "APPLICATION/JSON"), required: true) } == nil,
               "Content-Type matching is case-insensitive")
        expect(fault { _ = try APIJSON.requestObject(
            post(#"{"a":1}"#, contentType: "application/json-patch+json"),
            required: true) }?.status == .unsupportedMediaType,
               "a media type that merely starts with application/json is refused")
        expect(fault { _ = try APIJSON.requestObject(post(""), required: true) }?.code
                   == "body_required",
               "a required body cannot be empty")
        expect(fault { _ = try APIJSON.requestObject(post(""), required: false) } == nil,
               "an optional body may be empty")

        // Depth guard: it runs before JSONSerialization descends the shape.
        let deep = String(repeating: "{\"a\":", count: 12) + "1" + String(repeating: "}", count: 12)
        expect(fault { _ = try APIJSON.requestObject(post(deep), required: true) }?.code
                   == "body_too_deeply_nested",
               "a deeply nested body is refused before it is parsed")
        expect(APIJSON.depth(of: Array(#"{"note":"{{{{{{{"}"#.utf8)) == 1,
               "braces inside a string literal do not count toward depth")

        // Reject rather than coerce.
        let object: [String: Any] = ["brightness": 200, "autoFocus": true,
                                     "antiFlicker": "50hz", "hue": true]
        expect(fault { try APIJSON.rejectUnknownKeys(["brightnes": 1], allowed: ["brightness"]) }?.code
                   == "unknown_field",
               "a misspelled control name is refused rather than ignored")
        expect(fault { _ = try APIJSON.requireDouble(object, "brightness", in: 0...100) }?.code
                   == "out_of_range",
               "an out-of-range value is refused rather than clamped")
        expect(fault { _ = try APIJSON.requireDouble(object, "hue", in: -15...15) }?.code
                   == "invalid_type",
               "a boolean is not accepted where a number is required")
        expect(fault { _ = try APIJSON.requireDouble(object, "missing", in: 0...100) }?.code
                   == "missing_field",
               "a missing required field is refused")
        expect(fault { _ = try APIJSON.requireBool(object, "brightness") }?.code == "invalid_type",
               "a number is not accepted where a boolean is required")
        expect(fault { _ = try APIJSON.requireString(object, "antiFlicker",
                                                     oneOf: ["off", "auto"]) }?.code
                   == "invalid_value",
               "a string outside the allowed set is refused")
        expect((try? APIJSON.requireDouble(["brightness": 100], "brightness", in: 0...100)) == 100,
               "a value exactly at the top of the range is accepted")
        expect((try? APIJSON.requireDouble(["hue": -15], "hue", in: -15...15)) == -15,
               "a value exactly at the bottom of the range is accepted")
    }

    // MARK: - 8. Gimbal drive duration arithmetic

    static func checkGimbalDurationArithmetic() {
        print("-- gimbal drive duration")

        let ceiling = GimbalDrivePolicy.ceilingMilliseconds

        // No durationMs: the ceiling is what ends the drive.
        let omitted = GimbalDrivePolicy.resolve(requestedMilliseconds: nil)
        expect(omitted.milliseconds == ceiling && omitted.limit == .ceiling
                   && omitted.requestedMilliseconds == nil,
               "an omitted durationMs falls back to the ceiling")

        // A shorter durationMs is honoured exactly.
        let short = GimbalDrivePolicy.resolve(requestedMilliseconds: 750)
        expect(short.milliseconds == 750 && short.limit == .duration
                   && short.requestedMilliseconds == 750,
               "a durationMs below the ceiling is honoured as sent")

        // Exactly at the ceiling is honoured, not reported as a clamp.
        let exact = GimbalDrivePolicy.resolve(requestedMilliseconds: ceiling)
        expect(exact.milliseconds == ceiling && exact.limit == .duration,
               "a durationMs exactly at the ceiling counts as honoured")

        // Longer is clamped, and the response can still show what was asked.
        let long = GimbalDrivePolicy.resolve(requestedMilliseconds: ceiling * 10)
        expect(long.milliseconds == ceiling && long.limit == .ceiling
                   && long.requestedMilliseconds == ceiling * 10,
               "a durationMs above the ceiling is clamped and the request preserved")

        expect(GimbalDrivePolicy.resolve(requestedMilliseconds: 1).milliseconds == 1,
               "the smallest accepted durationMs survives")
        expect(long.duration == .milliseconds(ceiling),
               "the resolved Duration matches the resolved milliseconds")

        // durationMs is validated, not coerced.
        func fault(_ work: () throws -> Void) -> APIFault? {
            do { try work(); return nil } catch let fault as APIFault { return fault }
            catch { return nil }
        }
        let bounds = 1...GimbalDrivePolicy.maximumRequestedMilliseconds
        expect(fault { _ = try APIJSON.requireInt(["durationMs": 1500.7], "durationMs",
                                                  in: bounds) }?.code == "invalid_type",
               "a fractional durationMs is refused rather than rounded")
        expect(fault { _ = try APIJSON.requireInt(["durationMs": 0], "durationMs",
                                                  in: bounds) }?.code == "out_of_range",
               "a zero durationMs is refused")
        expect(fault { _ = try APIJSON.requireInt(["durationMs": -500], "durationMs",
                                                  in: bounds) }?.code == "out_of_range",
               "a negative durationMs is refused")
        expect(fault { _ = try APIJSON.requireInt(["durationMs": true], "durationMs",
                                                  in: bounds) }?.code == "invalid_type",
               "a boolean durationMs is refused")
        expect(fault { _ = try APIJSON.requireInt(
            ["durationMs": GimbalDrivePolicy.maximumRequestedMilliseconds + 1],
            "durationMs", in: bounds) }?.code == "out_of_range",
               "a nonsensically large durationMs is refused rather than clamped")
    }

    // MARK: - 9. The dead man's handle actually fires

    /// Drives the real timer with the camera call replaced by a counter. The
    /// waits are deliberately many times the armed interval so this cannot
    /// flake on a loaded CI runner.
    @MainActor
    static func checkGimbalDeadMan() async {
        print("-- gimbal dead-man timer")

        func settle() async {
            try? await Task.sleep(for: .milliseconds(400))
        }

        // 1. An abandoned drive stops with no client action at all. This is the
        //    case the whole mechanism exists for: nothing calls stop, nothing
        //    calls disarm, the client is simply gone.
        var stops = 0
        let abandoned = GimbalDeadMan { stops += 1 }
        abandoned.arm(for: .milliseconds(50))
        expect(abandoned.isArmed, "arming reports the timer as armed")
        await settle()
        expect(stops == 1, "an abandoned drive stops itself with no client action")
        expect(!abandoned.isArmed, "the timer reports itself disarmed after firing")

        // 2. It fires once, not repeatedly.
        await settle()
        expect(stops == 1, "the timer fires exactly once")

        // 3. An explicit stop disarms it, so no stop is sent behind the caller.
        var disarmedStops = 0
        let disarmed = GimbalDeadMan { disarmedStops += 1 }
        disarmed.arm(for: .milliseconds(50))
        disarmed.disarm()
        expect(!disarmed.isArmed, "disarming reports the timer as unarmed")
        await settle()
        expect(disarmedStops == 0, "a disarmed timer never fires")

        // 4. Re-arming replaces the pending timer rather than stacking one.
        var rearmedStops = 0
        let rearmed = GimbalDeadMan { rearmedStops += 1 }
        rearmed.arm(for: .milliseconds(50))
        rearmed.arm(for: .milliseconds(120))
        await settle()
        expect(rearmedStops == 1, "re-arming replaces the pending timer instead of stacking")

        // 5. A timer disarmed after its sleep elapsed must still not fire.
        //    This is the generation check: cancellation alone cannot stop a
        //    task already suspended on the hop back onto the main actor.
        var lateStops = 0
        let late = GimbalDeadMan { lateStops += 1 }
        late.arm(for: .zero)
        late.disarm()
        await settle()
        expect(lateStops == 0, "a timer disarmed after its sleep elapsed does not fire")

        // 6. Re-arming after a fire works — a second drive is a fresh drive.
        var reuseStops = 0
        let reused = GimbalDeadMan { reuseStops += 1 }
        reused.arm(for: .milliseconds(50))
        await settle()
        reused.arm(for: .milliseconds(50))
        await settle()
        expect(reuseStops == 2, "the timer can be re-armed after firing")

        // 7. It stops *on time*: not early, and not never. Wide margins on
        //    both sides so a busy runner cannot turn this into a flake.
        var timedStops = 0
        let timed = GimbalDeadMan { timedStops += 1 }
        timed.arm(for: .milliseconds(300))
        try? await Task.sleep(for: .milliseconds(60))
        expect(timedStops == 0, "a durationMs drive has not stopped well before its interval")
        try? await Task.sleep(for: .milliseconds(700))
        expect(timedStops == 1, "a durationMs drive stops once its interval elapses")
    }

    // MARK: - 10. How ownership answers reach the client

    static func checkGimbalOwnershipAnswers() {
        print("-- gimbal ownership answers")

        // An accepted drive is not a refusal, so the router goes on to arm the
        // dead-man and report the duration.
        expect(GimbalDrivePolicy.refusal(for: .accepted) == nil,
               "an accepted drive produces no refusal")

        // A held Dashboard control and a missing camera are different things to
        // a Stream Deck: one clears by itself, the other needs somebody to go
        // and plug something in. They must not share a status or a code.
        guard let held = GimbalDrivePolicy.refusal(for: .refusedControlHeld),
              let notReady = GimbalDrivePolicy.refusal(for: .refusedCameraNotReady) else {
            expect(false, "both refusals produce a fault")
            return
        }
        expect(held.status == .conflict, "a held Dashboard control is a 409")
        expect(held.code == "gimbal_control_held",
               "a held Dashboard control has its own machine-readable code")
        expect(notReady.status == .serviceUnavailable, "an unready camera is a 503")
        expect(notReady.code == "camera_unavailable", "an unready camera keeps its existing code")
        expect(held.status != notReady.status && held.code != notReady.code,
               "the two refusals are distinguishable by both status and code")
        // 409 is the same status `camera_busy` already uses for "somebody else
        // has the camera, retry shortly" — the taxonomy stays predictable.
        expect(APIFault.conflict("camera_busy", "x").status == held.status,
               "a held control shares a status with the preset-busy conflict it resembles")
        expect(APIFault.cameraUnavailable("x").status == notReady.status,
               "an unready camera shares a status with the rest of the camera-absent family")
        // A refusal must not be mistakable for something the client broke.
        expect(held.status.rawValue >= 400 && held.status.rawValue < 500,
               "a held control is a 4xx, not a server error")
        expect(!held.message.isEmpty && !notReady.message.isEmpty,
               "both refusals carry a human-readable message")

        // Drive and center answer identically for the same result, and they do
        // so structurally: both routes call the one `refusal(for:)` below, so
        // giving center its own answer would mean changing that function's
        // shape and breaking this file's compile. What is pinned here is the
        // other half — the exact values that mapping must produce — so a
        // route-specific branch cannot be slipped in underneath it either.
        //
        // This matters because centering was the last door through the
        // priority rule: a script swinging the head home under a held pad is
        // the same defect as a script driving it, arriving another way.
        let mapping: [(GimbalDriveResult, HTTPStatus, String)] = [
            (.refusedControlHeld, .conflict, "gimbal_control_held"),
            (.refusedCameraNotReady, .serviceUnavailable, "camera_unavailable"),
        ]
        for (result, status, code) in mapping {
            let fault = GimbalDrivePolicy.refusal(for: result)
            expect(fault?.status == status && fault?.code == code,
                   "\(result) answers \(status.rawValue) \(code) for a drive and a center alike")
        }

        // A center refused for a held control is the same 409 a drive gets —
        // same status, same code, same words — so a Stream Deck needs no
        // special case for which gimbal route it called.
        let centerHeld = GimbalDrivePolicy.refusal(for: .refusedControlHeld)
        expect(centerHeld?.status == held.status && centerHeld?.code == held.code
                   && centerHeld?.message == held.message,
               "a refused center is indistinguishable from a refused drive")

        // Not-ready is checked ahead of held in the model, for center exactly
        // as for drive, so a request made with no camera and a held control
        // answers 503 rather than 409 through either route.
        expect(GimbalDrivePolicy.refusal(for: .refusedCameraNotReady)?.status
                   == .serviceUnavailable,
               "no camera outranks a held control, whichever route asked")

        // The refusal renders as a normal error body, with no CORS and no leak.
        let rendered = String(decoding: held.response.serialized(), as: UTF8.self)
        expect(rendered.hasPrefix("HTTP/1.1 409 Conflict\r\n"), "the refusal serializes as 409")
        expect(rendered.contains(#""code":"gimbal_control_held""#),
               "the refusal body carries its code")
        expect(!rendered.lowercased().contains("access-control-"),
               "the refusal carries no CORS header")

        // An honest stop. True means the stop was queued on the write queue,
        // which is what 202 means everywhere else in this API.
        let stopped = GimbalDrivePolicy.stopOutcome(stopped: true)
        expect(stopped.stopped && stopped.status == .accepted && stopped.reason == nil,
               "a stop that reached the camera is 202 with stopped: true")

        // False means somebody else holds the head. Nothing failed, so it stays
        // 2xx — but the caller must not be able to conclude the camera is
        // stationary, and nothing was queued, so it is not a 202.
        let refused = GimbalDrivePolicy.stopOutcome(stopped: false)
        expect(!refused.stopped, "a refused stop reports stopped: false")
        expect(refused.status == .ok,
               "a refused stop is 200 — nothing was queued, so 202 would overstate it")
        expect(refused.status.rawValue < 300,
               "a refused stop is still a success: nothing went wrong and there is nothing to retry")
        expect(refused.reason == "control_held",
               "a refused stop says why in a machine-readable field")
        expect(refused.detail.lowercased().contains("may still be moving"),
               "a refused stop warns that the camera may still be moving")
        expect(stopped.status != refused.status,
               "the two stop outcomes are distinguishable by status as well as body")
    }

    // MARK: - 11. The listener can actually be constructed
    //
    // Narrow on purpose, and worth being explicit about what it is not.
    //
    // It catches ONE thing: a parameter combination `NWListener.init` refuses.
    // That is not a hypothetical — the port was once named both positionally
    // and inside `requiredLocalEndpoint`, Network.framework rejected it with
    // NWError 22 (EINVAL), and the loopback listener never bound at all. Four
    // check suites and a 60,000-input fuzz passed over that bug, because not
    // one of them could construct a listener.
    //
    // It does NOT catch anything that surfaces after construction. Binding
    // happens in `start(queue:)`, and its failures — a port already in use,
    // a refused entitlement, an interface that vanished — arrive
    // asynchronously through `stateUpdateHandler` and are invisible here. It
    // does not open a socket, accept a connection, or prove a single byte of
    // HTTP ever crosses one.
    //
    // No unit test dissolves the class of bug that needs a running process.
    // This converts one specific, recurring, cheap-to-check failure into
    // something CI catches. Read its presence as that and nothing more: the
    // app still has to be run.

    static func checkListenerConstruction() {
        print("-- listener construction")

        guard let port = NWEndpoint.Port(rawValue: 8787) else {
            expect(false, "8787 is a valid TCP port")
            return
        }

        // Both modes, because they take different paths through the port rule
        // and only one of them was ever wrong.
        for bindsLAN in [false, true] {
            let mode = bindsLAN ? "LAN" : "loopback"
            do {
                let listener = try APIListenerFactory.makeListener(bindsLAN: bindsLAN, port: port)
                // Never started, so nothing binds; cancelled anyway so the
                // object does not outlive the check.
                listener.cancel()
                expect(true, "a \(mode) listener can be constructed")
            } catch {
                expect(false, "a \(mode) listener can be constructed (threw \(error))")
            }
        }

        // The rule that was broken, pinned directly: loopback pins the address
        // (and the endpoint carries the port), the LAN path pins nothing.
        // Naming the port both ways is what NWListener refuses.
        let loopback = APIListenerFactory.makeParameters(bindsLAN: false, port: port)
        let lan = APIListenerFactory.makeParameters(bindsLAN: true, port: port)
        expect(loopback.requiredLocalEndpoint == .hostPort(host: .ipv4(.loopback), port: port),
               "loopback pins the bind address to 127.0.0.1 and carries the port")
        expect(lan.requiredLocalEndpoint == nil,
               "the LAN path pins no endpoint, so it is free to name the port positionally")
        expect(loopback.allowLocalEndpointReuse && lan.allowLocalEndpointReuse,
               "both modes allow endpoint reuse so a restart is not refused its own port")

        // Every port the Settings pane will accept, so a valid choice cannot
        // be one the listener refuses to be built for.
        for raw in [1024, 8787, 49_152, 65_535] {
            guard let candidate = NWEndpoint.Port(rawValue: UInt16(raw)) else {
                expect(false, "port \(raw) is representable")
                continue
            }
            do {
                try APIListenerFactory.makeListener(bindsLAN: false, port: candidate).cancel()
                expect(true, "a loopback listener can be constructed on port \(raw)")
            } catch {
                expect(false, "a loopback listener can be constructed on port \(raw) (threw \(error))")
            }
        }
    }
}
