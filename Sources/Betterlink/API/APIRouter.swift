import Foundation

// Turns a parsed request into camera work, on the main actor, against the
// app's *existing* models — never against a second `UVCTransport` and never
// straight onto the USB actor for a write.
//
// Every write goes through `CameraControlsModel`'s public setters, which put
// it on the same per-key write queue the Dashboard uses. That is what stops an
// HTTP client from interleaving a zoom write into the middle of a preset
// restore: `UVCTransport.apply(_:)` is one synchronous call on the transport
// actor, so nothing can land inside it, and everything else is FIFO behind the
// same queue the UI is already sharing.
//
// Reads are different: `GET /status` reads pan/tilt straight off the transport
// actor. That is deliberate — it is a GET_CUR, it cannot disturb a write, and
// the actor serializes it like any other transfer.
@MainActor
final class APIRouter {
    private let transport: UVCTransport
    private let viewfinder: ViewfinderModel
    private let controls: CameraControlsModel
    private let presets: PresetsModel

    /// The expected bearer token. Replaced in place when the user regenerates
    /// it, so a regenerate takes effect on the very next request without
    /// bouncing the listener.
    var token: String

    /// Single-flight guard for preset application. `PresetsModel` already
    /// refuses to start a second operation, but it refuses *silently* — two
    /// simultaneous HTTP applies would both get 200 and only one would have
    /// happened. This turns the second one into an honest 409.
    private var isApplyingPreset = false

    /// Ends an API-initiated gimbal drive if nothing else does.
    ///
    /// Owned here, not by the connection, and that is the whole point: it has
    /// to outlive the request that armed it. A client that sends `drive` and
    /// then vanishes, a connection that drops, a router work-deadline that
    /// fires — none of them can leave the head moving, because the timer is
    /// armed on this object and this object lives as long as the server.
    /// The answer is deliberately discarded here, and only here: when this
    /// fires after the Dashboard has taken the head, `endGimbalDrive` refuses
    /// and touches nothing, which is exactly the intended no-op. There is no
    /// client waiting on a response, so there is nothing to report. This is
    /// why an abandoned timer needs no chasing down.
    private lazy var gimbalDeadMan = GimbalDeadMan { [controls] in
        controls.endGimbalDrive(owner: .api)
    }

    init(transport: UVCTransport, viewfinder: ViewfinderModel,
         controls: CameraControlsModel, presets: PresetsModel, token: String) {
        self.transport = transport
        self.viewfinder = viewfinder
        self.controls = controls
        self.presets = presets
        self.token = token
    }

    // MARK: - Entry point

    /// The three gates run in a fixed order: transport policy, then
    /// authorization, then routing. Routing last is not a style choice — it is
    /// what stops an unauthenticated caller from telling a 401 for a preset id
    /// that exists apart from a 404 for one that does not, and enumerating the
    /// user's presets that way. An unauthorized request gets the identical
    /// 401 for every path in the API, real or invented.
    func respond(to request: HTTPRequest) async -> HTTPResponse {
        if let rejection = APIRequestPolicy.evaluate(request) {
            return APIFault(status: rejection.status, code: rejection.code,
                            message: rejection.message).response
        }
        let outcome = APIAuthorization.evaluate(headers: request.headers, expectedToken: token)
        guard outcome == .authorized else {
            return APIFault(status: .unauthorized,
                            code: "unauthorized",
                            message: outcome.message,
                            extraHeaders: [HTTPHeaderField(name: "WWW-Authenticate",
                                                           value: outcome.challenge)]).response
        }
        do {
            return try await dispatch(request)
        } catch {
            return error.response
        }
    }

    // MARK: - Routing

    private func dispatch(_ request: HTTPRequest) async throws(APIFault) -> HTTPResponse {
        // No endpoint here defines a query parameter. Rejecting one rather
        // than ignoring it means `PUT /zoom?factor=2` fails loudly instead of
        // looking like it worked.
        if request.query != nil {
            throw .badRequest("query_not_supported",
                              "This API takes no query parameters; send a JSON body instead.")
        }
        let segments = request.path.split(separator: "/").map(String.init)
        guard let match = Self.resolve(segments) else {
            throw APIFault(status: .notFound, code: "not_found",
                           message: "No route for \(request.path).")
        }
        // HEAD is answered by the matching GET handler with the body dropped
        // at serialization time, so it can never reach a handler that writes.
        let method = request.method.routesAs
        guard match.allowed.contains(method) else {
            throw APIFault(status: .methodNotAllowed, code: "method_not_allowed",
                           message: "\(request.method.rawValue) is not allowed on \(request.path).",
                           extraHeaders: [HTTPHeaderField(
                               name: "Allow",
                               value: match.allowed.map(\.rawValue).joined(separator: ", "))])
        }

        switch (match.route, method) {
        case (.status, _):
            return await statusResponse()
        case (.presetList, _):
            return presetListResponse()
        case (.presetApply(let id), _):
            return try await applyPreset(id: id)
        case (.gimbalDrive, _):
            return try driveGimbal(request)
        case (.gimbalStop, _):
            return try stopGimbal(request)
        case (.gimbalCenter, _):
            return try centerGimbal(request)
        case (.zoom, _):
            return try setZoom(request)
        case (.recordingState, _):
            return HTTPResponse(status: .ok, json: APIJSON.encode(recordingPayload()))
        case (.recordingStart, _):
            return try startRecording(request)
        case (.recordingStop, _):
            return try stopRecording(request)
        case (.controls, .patch):
            return try patchControls(request)
        case (.controls, _):
            return HTTPResponse(status: .ok,
                                json: APIJSON.encode(["controls": controlsPayload()]))
        }
    }

    /// Every path this API serves. Kept as one enum so the route table and the
    /// dispatcher above cannot drift apart — the switch is exhaustive, so
    /// adding a route here fails to compile until it is handled.
    private enum Route {
        case status
        case presetList
        case presetApply(String)
        case gimbalDrive
        case gimbalStop
        case gimbalCenter
        case zoom
        case recordingState
        case recordingStart
        case recordingStop
        case controls
    }

    /// The route table. `nil` means 404; the returned method list is what a
    /// 405 reports in its `Allow` header.
    private static func resolve(_ segments: [String]) -> (route: Route, allowed: [HTTPMethod])? {
        switch segments.count {
        case 1:
            switch segments[0] {
            case "status": return (.status, [.get])
            case "presets": return (.presetList, [.get])
            case "zoom": return (.zoom, [.put])
            case "recording": return (.recordingState, [.get])
            case "controls": return (.controls, [.get, .patch])
            default: return nil
            }
        case 2:
            switch (segments[0], segments[1]) {
            case ("gimbal", "drive"): return (.gimbalDrive, [.post])
            case ("gimbal", "stop"): return (.gimbalStop, [.post])
            case ("gimbal", "center"): return (.gimbalCenter, [.post])
            case ("recording", "start"): return (.recordingStart, [.post])
            case ("recording", "stop"): return (.recordingStop, [.post])
            default: return nil
            }
        case 3:
            guard segments[0] == "presets", segments[2] == "apply" else { return nil }
            return (.presetApply(segments[1]), [.post])
        default:
            return nil
        }
    }

    // MARK: - Status

    private func statusResponse() async -> HTTPResponse {
        var payload: [String: Any] = [
            "apiVersion": 1,
            "app": [
                "name": "Betterlink",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            ],
            "camera": cameraPayload(),
            "zoom": zoomPayload(),
            "controls": controlsPayload(),
            "recording": recordingPayload(),
            "videoMode": videoModePayload(),
        ]
        payload["position"] = await positionPayload()
        return HTTPResponse(status: .ok, json: APIJSON.encode(payload))
    }

    private func cameraPayload() -> [String: Any] {
        var name: Any = NSNull()
        if case .live(let cameraName, _) = viewfinder.status { name = cameraName }
        return [
            "connected": controls.isCameraPresent,
            "ready": controls.isReady,
            "name": name,
            // Whether the capture session is live. Recording needs this, and
            // it is only true once the Dashboard has been shown at least once
            // in this launch (the viewfinder starts from that view's task).
            "streaming": viewfinder.session.isRunning,
            // Tilt is refused by the camera while the stream is portrait
            // (investigation-findings.md §9), so a client driving the gimbal
            // needs to see this.
            "streamsPortrait": controls.streamsPortrait,
            "message": controls.statusMessage ?? NSNull(),
        ]
    }

    /// Pan/tilt comes from the camera itself: no model caches it, and a stale
    /// position is worse than none for key feedback. A read failure reports
    /// null rather than failing the whole status call.
    private func positionPayload() async -> Any {
        guard controls.isCameraPresent, let position = try? await transport.panTilt() else {
            return NSNull()
        }
        return [
            "pan": Int(position.pan),
            "tilt": Int(position.tilt),
            "panDegrees": APIJSON.trim(position.panDegrees),
            "tiltDegrees": APIJSON.trim(position.tiltDegrees),
        ]
    }

    private func zoomPayload() -> [String: Any] {
        [
            "factor": APIJSON.trim(controls.zoomFactor),
            "min": APIJSON.trim(controls.zoomRange.lowerBound),
            "max": APIJSON.trim(controls.zoomRange.upperBound),
        ]
    }

    private func videoModePayload() -> Any {
        // All zeros is what XU 0x1C reads back when nothing is streaming.
        guard let mode = controls.currentVideoMode, mode.width > 0, mode.height > 0 else {
            return NSNull()
        }
        return ["width": Int(mode.width), "height": Int(mode.height),
                "frameRate": Int(mode.framesPerSecond)]
    }

    private func controlsPayload() -> [String: Any] {
        func adjustable(_ control: AdjustableControl) -> [String: Any] {
            [
                "value": APIJSON.trim(control.value),
                "min": APIJSON.trim(control.range.lowerBound),
                "max": APIJSON.trim(control.range.upperBound),
                "step": APIJSON.trim(control.step),
            ]
        }
        return [
            "brightness": adjustable(controls.brightness),
            "contrast": adjustable(controls.contrast),
            "saturation": adjustable(controls.saturation),
            "sharpness": adjustable(controls.sharpness),
            "hue": adjustable(controls.hue),
            "whiteBalanceTemperature": adjustable(controls.whiteBalanceTemperature),
            "focus": adjustable(controls.focus),
            "roll": adjustable(controls.roll),
            "autoWhiteBalance": controls.autoWhiteBalance,
            "autoFocus": controls.autoFocus,
            "antiFlicker": Self.antiFlickerName(controls.antiFlicker),
        ]
    }

    // MARK: - Presets

    private func presetListResponse() -> HTTPResponse {
        let list = presets.store.presets.map { preset -> [String: Any] in
            [
                "id": preset.id.uuidString,
                "name": preset.name,
                "createdAt": preset.createdAt.formatted(.iso8601),
                "isDefault": preset.isDefault,
            ]
        }
        return HTTPResponse(status: .ok, json: APIJSON.encode(["presets": list]))
    }

    private func applyPreset(id: String) async throws(APIFault) -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            throw .badRequest("invalid_preset_id", "'\(id)' is not a UUID.")
        }
        guard let preset = presets.store.presets.first(where: { $0.id == uuid }) else {
            throw APIFault(status: .notFound, code: "preset_not_found",
                           message: "No preset with id \(uuid.uuidString).")
        }
        guard controls.isCameraPresent else {
            throw .cameraUnavailable("No Insta360 Link is attached.")
        }
        guard !isApplyingPreset, !presets.isBusy else {
            throw .conflict("camera_busy", "Another preset operation is already running.")
        }
        isApplyingPreset = true
        defer { isApplyingPreset = false }
        // `PresetsModel.apply` returns without touching `outcome` if it decides
        // it is busy, which would leave the previous run's result sitting there
        // for us to read as though it were ours — and report `applied: true`
        // for work that never happened. Clearing first turns that into a nil
        // we can detect instead of an invariant that only holds because there
        // is no suspension point between the guard above and the call below.
        presets.clearOutcome()
        await presets.apply(preset)

        var payload: [String: Any] = ["preset": ["id": preset.id.uuidString, "name": preset.name]]
        switch presets.outcome {
        case .success:
            payload["applied"] = true
            payload["warnings"] = [String]()
        case .partial(_, let details):
            // Some controls refused the write. The preset did land, so this is
            // a 200 — but the caller is told exactly what did not.
            payload["applied"] = true
            payload["warnings"] = details
        case .failure(let message):
            throw APIFault(status: .serviceUnavailable, code: "camera_error",
                           message: "Applying “\(preset.name)” failed: \(message)")
        case nil:
            // No outcome means the model declined to run at all.
            throw .conflict("camera_busy",
                            "The camera was busy with another operation; nothing was applied.")
        }
        return HTTPResponse(status: .ok, json: APIJSON.encode(payload))
    }

    // MARK: - Gimbal

    private func driveGimbal(_ request: HTTPRequest) throws(APIFault) -> HTTPResponse {
        let object = try APIJSON.requestObject(request, required: true)
        try APIJSON.rejectUnknownKeys(object, allowed: ["direction", "durationMs"])
        let name = try APIJSON.requireString(object, "direction",
                                             oneOf: ["up", "down", "left", "right"])
        var requestedDuration: Int?
        if object["durationMs"] != nil {
            requestedDuration = try APIJSON.requireInt(
                object, "durationMs",
                in: 1...GimbalDrivePolicy.maximumRequestedMilliseconds)
        }
        try requireReadyCamera()
        let direction: GimbalPadDirection = switch name {
        case "up": .up
        case "down": .down
        case "left": .left
        default: .right
        }
        // The camera silently refuses every tilt command while it streams a
        // portrait format (§9). Silently is the problem: a client would see
        // 202 and nothing would move, so this is a 409 instead.
        if (direction == .up || direction == .down), controls.streamsPortrait {
            throw .conflict("tilt_unavailable",
                            "The camera refuses tilt commands while the stream is portrait. "
                                + "Switch the Dashboard's stream to landscape first.")
        }
        let resolution = GimbalDrivePolicy.resolve(requestedMilliseconds: requestedDuration)
        // The result must be read. `.accepted` means the model has taken
        // responsibility for the movement — not that a transfer went out; an
        // accepted drive the camera is already performing is skipped by the
        // rate limiter, which is the limiter working. 202 is still right.
        let result = controls.beginGimbalDrive(direction, owner: .api)
        if let refusal = GimbalDrivePolicy.refusal(for: result) { throw refusal }
        // Armed only once the drive was accepted, and in the same synchronous
        // stretch — there is no suspension point between the two — so a drive
        // never exists without a timer behind it, and a refused drive never
        // arms a timer that would later try to end somebody else's move.
        gimbalDeadMan.arm(for: resolution.duration)

        var payload: [String: Any] = [
            "driving": name,
            "stopsInMs": resolution.milliseconds,
            "limit": resolution.limit.rawValue,
            "ceilingMs": GimbalDrivePolicy.ceilingMilliseconds,
        ]
        if let requested = resolution.requestedMilliseconds {
            payload["requestedMs"] = requested
        }
        return HTTPResponse(status: .accepted, json: APIJSON.encode(payload))
    }

    private func stopGimbal(_ request: HTTPRequest) throws(APIFault) -> HTTPResponse {
        try requireEmptyBody(request)
        // Disarmed unconditionally: this owner's drive is over whatever the
        // model says next.
        gimbalDeadMan.disarm()
        // Deliberately not gated on `isReady`, mirroring the model's own stop:
        // a stop has to go out even if the connection state flipped mid-drive.
        //
        // False does not mean the stop failed — it means somebody else holds
        // the head, so there was nothing of ours to end. Nothing went wrong
        // and there is nothing to retry, but the camera may well still be
        // moving, and "stopped: true" beside a panning camera is the failure
        // this return value exists to prevent.
        let outcome = GimbalDrivePolicy.stopOutcome(
            stopped: controls.endGimbalDrive(owner: .api))
        var payload: [String: Any] = ["stopped": outcome.stopped, "detail": outcome.detail]
        if let reason = outcome.reason { payload["reason"] = reason }
        return HTTPResponse(status: outcome.status, json: APIJSON.encode(payload))
    }

    private func centerGimbal(_ request: HTTPRequest) throws(APIFault) -> HTTPResponse {
        try requireEmptyBody(request)
        try requireReadyCamera()
        // A center moves the head, so it goes through the same door a drive
        // does and answers with the same two refusals — including the same
        // guard order, not-ready ahead of held, so a center asked for with no
        // camera *and* a held control reads identically to a drive in that
        // state. A script swinging the head home under somebody's held pad is
        // the priority rule's own case arriving by a different route.
        let result = controls.centerGimbal(owner: .api)
        if let refusal = GimbalDrivePolicy.refusal(for: result) { throw refusal }
        // Disarmed only once the center was accepted, and that condition
        // matters. A refused center changes nothing at all, and "nothing" has
        // to include our timer: the API may still hold the head from an
        // earlier drive, and throwing away its dead-man on a request that did
        // nothing would leave that drive with nothing left to end it. An
        // accepted center ends the move with its own trailing stop (§7) and
        // hands the head back to nobody, so the timer has no work left.
        gimbalDeadMan.disarm()
        return HTTPResponse(status: .accepted, json: APIJSON.encode(["centering": true]))
    }

    // MARK: - Zoom

    private func setZoom(_ request: HTTPRequest) throws(APIFault) -> HTTPResponse {
        let object = try APIJSON.requestObject(request, required: true)
        try APIJSON.rejectUnknownKeys(object, allowed: ["factor"])
        try requireReadyCamera()
        // Range comes from the camera's own GET_MIN/GET_MAX, and an out-of-range
        // factor is a 400 rather than a silent clamp — `setZoom` would have
        // clamped it and reported success for a value the caller never asked for.
        let factor = try APIJSON.requireDouble(object, "factor", in: controls.zoomRange)
        controls.setZoom(factor)
        return HTTPResponse(status: .accepted,
                            json: APIJSON.encode(["factor": APIJSON.trim(factor)]))
    }

    // MARK: - Recording

    private func recordingPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "startedAt": NSNull(),
            "elapsedSeconds": NSNull(),
            "message": NSNull(),
            "lastRecordingPath": viewfinder.recorder.lastRecordingURL?.path ?? NSNull(),
        ]
        switch viewfinder.recorder.state {
        case .idle:
            payload["state"] = "idle"
        case .starting:
            payload["state"] = "starting"
        case .recording(let startedAt):
            payload["state"] = "recording"
            payload["startedAt"] = startedAt.formatted(.iso8601)
            payload["elapsedSeconds"] = APIJSON.trim(Date().timeIntervalSince(startedAt))
        case .stopping:
            payload["state"] = "stopping"
        case .failed(let message):
            payload["state"] = "failed"
            payload["message"] = message
        }
        return payload
    }

    private func startRecording(_ request: HTTPRequest) throws(APIFault) -> HTTPResponse {
        try requireEmptyBody(request)
        switch viewfinder.recorder.state {
        case .idle, .failed:
            break
        case .starting, .recording, .stopping:
            throw .conflict("recording_in_progress",
                            "A recording is already starting, running, or stopping.")
        }
        // Recording borrows the viewfinder's live capture session. Reject
        // rather than start the session from a network request: opening a
        // capture session can raise a system permission prompt, and an
        // unattended HTTP call is the wrong moment for that.
        guard viewfinder.session.isRunning else {
            throw .conflict("viewfinder_not_streaming",
                            "Recording needs the live viewfinder. Open Betterlink's Dashboard "
                                + "with the camera attached, then try again.")
        }
        viewfinder.recorder.startRecording()
        return HTTPResponse(status: .accepted, json: APIJSON.encode(recordingPayload()))
    }

    private func stopRecording(_ request: HTTPRequest) throws(APIFault) -> HTTPResponse {
        try requireEmptyBody(request)
        // `.starting` counts: the recorder latches a stop asked for before
        // the recording has begun, so refusing here would be the API telling
        // the caller nothing was running while a recording was on its way up.
        switch viewfinder.recorder.state {
        case .recording, .starting:
            break
        case .idle, .stopping, .failed:
            throw .conflict("not_recording", "No recording is running.")
        }
        viewfinder.recorder.stopRecording()
        return HTTPResponse(status: .accepted, json: APIJSON.encode(recordingPayload()))
    }

    // MARK: - Image controls

    private static let numericControlKeys = [
        "brightness", "contrast", "saturation", "sharpness",
        "hue", "whiteBalanceTemperature", "focus", "roll",
    ]

    private static let allControlKeys: Set<String> =
        Set(numericControlKeys + ["autoWhiteBalance", "autoFocus", "antiFlicker"])

    private static let antiFlickerByName: [String: PowerLineFrequency] = [
        "off": .disabled, "50hz": .hz50, "60hz": .hz60, "auto": .auto,
    ]

    private static func antiFlickerName(_ frequency: PowerLineFrequency) -> String {
        switch frequency {
        case .disabled: "off"
        case .hz50: "50hz"
        case .hz60: "60hz"
        case .auto: "auto"
        }
    }

    private func patchControls(_ request: HTTPRequest) throws(APIFault) -> HTTPResponse {
        let object = try APIJSON.requestObject(request, required: true)
        try APIJSON.rejectUnknownKeys(object, allowed: Self.allControlKeys)
        guard !object.isEmpty else {
            throw .badRequest("body_required", "Give at least one control to change.")
        }
        try requireReadyCamera()

        // Validate the whole patch before writing any of it. A patch that
        // applies three controls and then 400s on the fourth leaves the camera
        // in a state the caller never asked for and cannot infer.
        let ranges: [String: ClosedRange<Double>] = [
            "brightness": controls.brightness.range,
            "contrast": controls.contrast.range,
            "saturation": controls.saturation.range,
            "sharpness": controls.sharpness.range,
            "hue": controls.hue.range,
            "whiteBalanceTemperature": controls.whiteBalanceTemperature.range,
            "focus": controls.focus.range,
            "roll": controls.roll.range,
        ]
        var numbers: [String: Double] = [:]
        for key in Self.numericControlKeys where object[key] != nil {
            guard let range = ranges[key] else { continue }
            numbers[key] = try APIJSON.requireDouble(object, key, in: range)
        }
        let autoWhiteBalance = object["autoWhiteBalance"] != nil
            ? try APIJSON.requireBool(object, "autoWhiteBalance") : nil
        let autoFocus = object["autoFocus"] != nil
            ? try APIJSON.requireBool(object, "autoFocus") : nil
        var antiFlicker: PowerLineFrequency?
        if object["antiFlicker"] != nil {
            let name = try APIJSON.requireString(object, "antiFlicker",
                                                 oneOf: Self.antiFlickerByName.keys.sorted())
            antiFlicker = Self.antiFlickerByName[name]
        }

        // A manual value written while its auto mode is on is discarded by the
        // camera. Refuse it rather than report success for a write that will
        // not stick — turn the auto mode off in the same patch instead.
        if numbers["whiteBalanceTemperature"] != nil,
           autoWhiteBalance ?? controls.autoWhiteBalance {
            throw .conflict("auto_mode_active",
                            "whiteBalanceTemperature has no effect while auto white balance is on. "
                                + "Send \"autoWhiteBalance\": false in the same request.")
        }
        if numbers["focus"] != nil, autoFocus ?? controls.autoFocus {
            throw .conflict("auto_mode_active",
                            "focus has no effect while auto focus is on. "
                                + "Send \"autoFocus\": false in the same request.")
        }

        // Auto modes first, so a patch that turns one off and sets its manual
        // value in the same request lands in an order the camera accepts.
        if let autoWhiteBalance { controls.setAutoWhiteBalance(autoWhiteBalance) }
        if let autoFocus { controls.setAutoFocus(autoFocus) }
        if let antiFlicker { controls.setAntiFlicker(antiFlicker) }
        for (key, value) in numbers.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "brightness": controls.setBrightness(value)
            case "contrast": controls.setContrast(value)
            case "saturation": controls.setSaturation(value)
            case "sharpness": controls.setSharpness(value)
            case "hue": controls.setHue(value)
            case "whiteBalanceTemperature": controls.setWhiteBalanceTemperature(value)
            case "focus": controls.setFocus(value)
            case "roll": controls.setRoll(value)
            default: break
            }
        }
        return HTTPResponse(status: .accepted,
                            json: APIJSON.encode(["controls": controlsPayload()]))
    }

    /// Called when the server is shutting down. If the API left the gimbal
    /// moving, stop it now: once this router is released nothing is left that
    /// could. Guarded on the timer actually being armed so that closing the
    /// window never fires a stop into a drive the Dashboard started.
    func stopGimbalIfDriving() {
        guard gimbalDeadMan.isArmed else { return }
        gimbalDeadMan.disarm()
        // Discarded for the same reason as the dead-man's own fire: no client
        // is waiting, and a refusal means the Dashboard holds the head and is
        // responsible for it.
        controls.endGimbalDrive(owner: .api)
    }

    // MARK: - Shared guards

    /// Writes are dropped on the floor by `CameraControlsModel.send(_:)` while
    /// the model is not ready. Refusing here is the difference between a
    /// client being told nothing happened and a client believing it did.
    private func requireReadyCamera() throws(APIFault) {
        guard controls.isCameraPresent else {
            throw .cameraUnavailable("No Insta360 Link is attached.")
        }
        guard controls.isReady else {
            throw .cameraUnavailable(controls.statusMessage
                ?? "The camera's controls have not been read yet.")
        }
    }

    /// For the endpoints that take no body at all: an empty body is fine, and
    /// anything else is a 400 rather than something quietly ignored.
    private func requireEmptyBody(_ request: HTTPRequest) throws(APIFault) {
        guard request.body.isEmpty else {
            throw .badRequest("body_not_supported", "This endpoint takes no request body.")
        }
    }
}
