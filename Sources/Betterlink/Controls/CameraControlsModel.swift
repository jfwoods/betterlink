import CoreGraphics
import Foundation
import Observation

/// One adjustable camera value: what the UI edits plus the device-reported
/// range behind it. Starts from the ranges verified in
/// investigation-findings.md §4 and is replaced by the camera's own
/// MIN/MAX/RES on connect.
struct AdjustableControl: Sendable {
    var value: Double
    var range: ClosedRange<Double>
    var step: Double

    /// Adopts a fresh reading, trusting the device-reported range only when
    /// it is non-degenerate (a broken range would crash a Slider).
    mutating func update<V: FixedWidthInteger>(value: V, deviceRange: UVCControlRange<V>) {
        self.value = Double(value)
        let minimum = Double(deviceRange.minimum)
        let maximum = Double(deviceRange.maximum)
        if minimum < maximum { range = minimum...maximum }
        let resolution = Double(deviceRange.resolution)
        if resolution > 0 { step = resolution }
    }
}

/// State behind every camera control on the Dashboard. Shares the app's one
/// `UVCTransport` with the preset panes and mirrors the viewfinder's Link
/// discovery (via `track(_:)`) instead of duplicating USB discovery: when
/// the viewfinder sees the Link, this model reads every control's current
/// value and range; when it goes away, every control disables and the USB
/// handle is dropped.
@MainActor
@Observable
final class CameraControlsModel {
    // MARK: Connection

    /// The viewfinder's discovery says an Insta360 Link is attached.
    private(set) var isCameraPresent = false
    /// The initial read of values + ranges succeeded; controls are enabled.
    private(set) var isReady = false
    private(set) var statusMessage: String?

    // MARK: Gimbal

    /// The persisted per-axis ceilings, scaled into the verified caps (pan
    /// 0–30, tilt 0–20, §4). Read straight from UserDefaults rather than
    /// stored here, because the control bar and the Settings pane both write
    /// the same keys and neither owns the value.
    var gimbalSpeedCaps: GimbalSpeedCaps { .persisted() }

    /// The speed bytes those ceilings come to — what the control bar shows,
    /// because these are the bytes that reach the camera.
    var panSpeed: Int { Int(gimbalSpeedCaps.panCeiling) }
    var tiltSpeed: Int { Int(gimbalSpeedCaps.tiltCeiling) }

    // MARK: Zoom (displayed as a factor; CT_ZOOM_ABSOLUTE carries 100...400)

    private(set) var zoomFactor = 1.0
    private(set) var zoomRange: ClosedRange<Double> = 1.0...4.0

    // MARK: Image (defaults from §4; replaced by device readings on connect)

    private(set) var brightness = AdjustableControl(value: 50, range: 0...100, step: 1)
    private(set) var contrast = AdjustableControl(value: 50, range: 0...100, step: 1)
    private(set) var saturation = AdjustableControl(value: 50, range: 0...100, step: 1)
    private(set) var sharpness = AdjustableControl(value: 50, range: 0...100, step: 1)
    private(set) var hue = AdjustableControl(value: 0, range: -15...15, step: 1)
    private(set) var whiteBalanceTemperature = AdjustableControl(value: 6400, range: 2000...10000, step: 50)
    private(set) var focus = AdjustableControl(value: 0, range: 0...100, step: 1)
    private(set) var roll = AdjustableControl(value: 0, range: -100...100, step: 1)
    private(set) var autoWhiteBalance = true
    private(set) var autoFocus = true
    private(set) var antiFlicker = PowerLineFrequency.auto

    // MARK: Video mode

    private(set) var currentVideoMode: VideoMode?

    /// Whether the stream uses the camera's portrait formats. Tilt stops
    /// working while it does (§9), which is why the pad's tilt buttons and the
    /// inspector's warning key off this.
    var streamsPortrait: Bool { viewfinder?.streamsPortrait ?? false }

    /// Flips the stream between the landscape and portrait format families and
    /// re-syncs the picker to the orientation's default size.
    func setStreamsPortrait(_ portrait: Bool) {
        viewfinder?.setStreamsPortrait(portrait)
        selectedVideoFormatID = portrait ? "1080x1920" : "1920x1080"
        selectedFrameRate = availableFrameRates.first
        refreshCurrentVideoMode()
    }

    /// What the picker offers: the attached camera's own formats in the current
    /// orientation, read from the capture device rather than a hand-maintained
    /// table.
    var videoFormats: [VideoFormatOption] { viewfinder?.videoFormats ?? [] }

    /// Defaults to the format the viewfinder itself picks on attach; replaced
    /// by whatever XU 0x1C reports once the stream is up.
    var selectedVideoFormatID: String? = "1920x1080" {
        didSet {
            // Keep the frame-rate selection valid for the chosen resolution.
            guard oldValue != selectedVideoFormatID else { return }
            let rates = availableFrameRates
            if let rate = selectedFrameRate, rates.contains(rate) { return }
            selectedFrameRate = rates.first
        }
    }

    var selectedFrameRate: Int?

    var availableFrameRates: [Int] { selectedVideoFormat?.frameRates ?? [] }

    var selectedVideoFormat: VideoFormatOption? {
        videoFormats.first { $0.id == selectedVideoFormatID }
    }

    /// Format changes are blocked mid-recording: swapping the capture format
    /// would pull it out from under the movie file output.
    var canChangeVideoFormat: Bool {
        guard isReady else { return false }
        if case .recording = viewfinder?.recorder.state { return false }
        return true
    }

    var canApplyVideoMode: Bool {
        guard canChangeVideoFormat, let format = selectedVideoFormat,
              let rate = selectedFrameRate, format.frameRates.contains(rate) else { return false }
        return true
    }

    var currentVideoModeDescription: String {
        // All zeros is what selector 0x1C reads back when nothing is streaming.
        guard let mode = currentVideoMode, mode.width > 0, mode.height > 0 else { return "—" }
        return "\(mode.width) × \(mode.height) @ \(mode.framesPerSecond) fps"
    }

    // MARK: Internals

    @ObservationIgnored private let transport: UVCTransport
    @ObservationIgnored private let writeQueue = ControlWriteQueue()
    /// Speed ceilings captured when a drive starts, so a slider moved
    /// mid-drag cannot change the speed under the user's hand.
    @ObservationIgnored private var driveCaps = GimbalSpeedCaps.persisted()
    @ObservationIgnored private var driveLimiter = GimbalDriveLimiter()
    /// Who holds the head. Not observable: it changes on every drive
    /// submission, and a SwiftUI invalidation per mouse-move during a drag
    /// would be a poor trade for state no view reads.
    @ObservationIgnored private var driveOwnership = GimbalDriveOwnership()
    @ObservationIgnored private var pendingDrive: GimbalDrive?
    @ObservationIgnored private var pendingDriveTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var isTracking = false
    /// The viewfinder owns the capture session, which is what actually sets
    /// resolution and frame rate; held from `track(_:)` for the video-mode
    /// picker.
    @ObservationIgnored private weak var viewfinder: ViewfinderModel?

    /// The app passes in the one shared transport (see `ContentView.init`);
    /// the default exists for previews.
    init(transport: UVCTransport = UVCTransport()) {
        self.transport = transport
        writeQueue.onError = { [weak self] error in
            self?.statusMessage = "Camera command failed: \(error)"
        }
    }

    // MARK: Discovery mirroring

    /// Follows the viewfinder's Link discovery for the life of this model.
    /// Idempotent; call once from the app shell.
    func track(_ viewfinder: ViewfinderModel) {
        guard !isTracking else { return }
        isTracking = true
        self.viewfinder = viewfinder
        observePresence(of: viewfinder)
    }

    private func observePresence(of viewfinder: ViewfinderModel) {
        let present = withObservationTracking {
            // .live(cameraName:isLink:) with isLink == true.
            if case .live(_, true) = viewfinder.status { true } else { false }
        } onChange: { [weak self, weak viewfinder] in
            Task { @MainActor in
                guard let self, let viewfinder else { return }
                self.observePresence(of: viewfinder)
            }
        }
        syncCameraPresence(present)
    }

    private func syncCameraPresence(_ present: Bool) {
        guard present != isCameraPresent else { return }
        isCameraPresent = present
        if present {
            scheduleRefresh()
        } else {
            detach()
        }
    }

    /// Re-reads every control from the camera (e.g. after another app
    /// changed them behind our back).
    func reloadFromCamera() {
        guard isCameraPresent else { return }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        statusMessage = nil
        Task {
            do {
                let snapshot = try await readSnapshot()
                guard generation == refreshGeneration else { return }
                apply(snapshot)
                isReady = true
            } catch {
                guard generation == refreshGeneration else { return }
                isReady = false
                // The bar disables on isReady, which can interrupt a gesture
                // without delivering its release; let go of the hold here too
                // rather than trusting that it arrives.
                driveOwnership.abandon()
                abandonPendingDrive()
                statusMessage = "Could not read camera controls: \(error)"
            }
        }
    }

    private func detach() {
        refreshGeneration += 1
        isReady = false
        statusMessage = nil
        // Nobody is driving a camera that is not there. A stale owner left
        // behind would refuse the next stop from everybody else, and a stale
        // hold would lock the API out of the gimbal entirely.
        driveOwnership.abandon()
        abandonPendingDrive()
        writeQueue.cancelAll()
        let transport = transport
        Task { await transport.disconnect() }
    }

    // MARK: Gimbal drive

    /// Starts a pad drive at the ceiling — the pad has no analog range. The
    /// camera keeps moving until the matching `endGimbalDrive(owner:)`. The
    /// write queue is FIFO per key, so the stop is guaranteed to land after
    /// the drive it ends (and a drive still pending when the stop is queued is
    /// simply replaced by it, so the camera never sees a drive it will not be
    /// told to stop).
    /// Marked `@discardableResult` for the Dashboard's sake: a Dashboard claim
    /// cannot be refused, so its two call sites would only be writing `_ =`.
    /// Every other caller must read it — a client told "fine" when nothing
    /// moved is worse off than one told why.
    @discardableResult
    func beginGimbalDrive(_ direction: GimbalPadDirection,
                          owner: GimbalDriveOwner) -> GimbalDriveResult {
        driveCaps = .persisted()
        return submitGimbalDrive(GimbalDrive(pad: direction, caps: driveCaps), owner: owner)
    }

    /// Grabs the joystick puck. Captures the ceilings for the whole drag, the
    /// way a pad press captures them for the whole hold.
    ///
    /// Takes no owner because it commands nothing: the head is claimed by the
    /// first `updateJoystickDrive`, which the gesture delivers in the same
    /// mouse-down. Claiming here instead would take the head without moving
    /// it, which would refuse the previous owner's dead-man while its drive
    /// was still running — the exact hole ownership exists to close.
    ///
    /// It does mark the hold, though, and that is the point of it existing at
    /// all: from the instant the puck is grabbed the API is refused, so there
    /// is no window in which a script can take a head the user is holding.
    func beginJoystickDrive() {
        driveCaps = .persisted()
        driveOwnership.beginDashboardHold()
    }

    /// The puck moved: `offset` is its displacement from the center of the
    /// well and `radius` the travel the well allows, which together give both
    /// direction and speed. Rate-limited — see `submitGimbalDrive`.
    func updateJoystickDrive(offset: CGSize, radius: CGFloat, owner: GimbalDriveOwner) {
        // The result is dropped rather than returned: this is the Dashboard's
        // path — its geometry is in view points — and a Dashboard claim is
        // never refused.
        _ = submitGimbalDrive(GimbalJoystick.drive(offset: offset, radius: radius,
                                                   caps: driveCaps,
                                                   allowsTilt: !streamsPortrait),
                              owner: owner)
    }

    /// Stops the drive `owner` started — and only that one.
    ///
    /// Refused outright when somebody else holds the head, which is the whole
    /// point: an API client's dead-man timer expiring must not end a move the
    /// user is making with their hand on the control, and a Dashboard release
    /// must not end a move the API has since taken over. A refused stop is a
    /// *complete* no-op: it must not touch the pending drive or the limiter,
    /// because both of those now belong to whoever does hold the head.
    ///
    /// The owner is not defaulted. A default on a safety-relevant parameter is
    /// a silent claim, and the next call site to be written would inherit it
    /// without anyone deciding — which is precisely how this class of bug got
    /// here in the first place.
    ///
    /// An allowed stop bypasses the ready gate: it must go out even if the
    /// connection state flipped mid-hold. It bypasses the limiter for the same
    /// reason — never held back by the throttle interval, never dropped as a
    /// duplicate — and discards any drive still waiting for its turn rather
    /// than letting it land afterwards.
    /// Returns whether the stop reached the camera, which callers should bind
    /// to a name that says what the answer means — `let stoppedTheHead = …`.
    /// `false` is **"somebody else holds the head"**, not "the stop failed":
    /// nothing went wrong, there is nothing to retry, and this owner's drive
    /// is over either way. What it does mean is that the head may still be
    /// moving under the other owner's command, which is the one thing a
    /// client must not be told incorrectly — answering an unconditional
    /// success beside a camera that is still panning is the same bug as a
    /// drive that reports success and moves nothing.
    ///
    /// `@discardableResult` for the Dashboard's sake, as with
    /// `beginGimbalDrive`: its release has nothing to do about the answer
    /// either way. Even in the one case where a Dashboard release is refused
    /// — the puck was grabbed but never moved before the well vanished, so it
    /// never took the head — the move belongs to the other owner and is
    /// theirs to stop. Every other caller must read it.
    @discardableResult
    func endGimbalDrive(owner: GimbalDriveOwner) -> Bool {
        // `release` lets go of the hold before it decides about the stop, and
        // that order is the safety property — see GimbalDriveOwnership.
        guard driveOwnership.release(from: owner) else { return false }
        abandonPendingDrive()
        send("gimbal", requiresReady: false) { try await $0.stopGimbal() }
        return true
    }

    /// Sends the head home.
    ///
    /// A center moves the head, so it goes through the same door a drive does:
    /// refused while somebody has a Dashboard control physically down, because
    /// a script swinging the head home under a held pad is exactly what the
    /// priority rule exists to prevent, arriving by a different route. The
    /// Dashboard's own center is never refused, structurally — see
    /// `GimbalDriveOwnership.allowsOverride(by:)`.
    ///
    /// An accepted center takes the head and gives it straight back: it
    /// overrides whatever was running and ends in its own stop (§7), so it
    /// leaves the head held by nobody and the loser's later stop is harmlessly
    /// let through. A refused one changes nothing whatsoever — it must not
    /// touch the ownership or the hold belonging to the person it was just
    /// refused against.
    @discardableResult
    func centerGimbal(owner: GimbalDriveOwner) -> GimbalDriveResult {
        guard isReady else { return .refusedCameraNotReady }
        guard driveOwnership.recenter(by: owner) else { return .refusedControlHeld }
        abandonPendingDrive()
        send("gimbal") { try await $0.centerGimbal() }
        return .accepted
    }

    /// Puts a drive on the wire at no more than ~10 Hz, and not at all when
    /// the camera already holds that exact payload. An update that arrives too
    /// soon is held and flushed when the interval is up rather than dropped:
    /// the user can stop moving the mouse at any moment, and the head keeps
    /// doing whatever was last sent.
    /// `.accepted` means the model has taken responsibility for the movement,
    /// not that a transfer went out: an accepted drive the camera is already
    /// performing is skipped by the limiter, which is the whole point of it.
    private func submitGimbalDrive(_ drive: GimbalDrive,
                                   owner: GimbalDriveOwner) -> GimbalDriveResult {
        // The hold tracks the pointer, not the camera: a control that is down
        // is down whether or not the camera is answering, and the release path
        // is what lets go of it.
        if owner == .dashboard { driveOwnership.beginDashboardHold() }
        // Ahead of the claim so that a request refused for want of a camera
        // changes nothing at all. `send` would drop it anyway; returning here
        // makes that visible instead of silent, and keeps the limiter from
        // recording a payload the camera never received.
        guard isReady else { return .refusedCameraNotReady }
        // The claim lands before the limiter, not after. Taking the head is
        // not conditional on the payload being worth a transfer — two owners
        // asking for the same movement is exactly when the limiter skips the
        // send, and ownership still has to move, or the loser's dead-man would
        // stop a drive the winner is now responsible for.
        guard driveOwnership.claim(owner) else { return .refusedControlHeld }
        pendingDrive = drive
        flushPendingDrive()
        return .accepted
    }

    /// Drops a drive that has not gone out yet and forgets what the camera was
    /// last told. Everything that ends a move funnels through here.
    private func abandonPendingDrive() {
        pendingDrive = nil
        pendingDriveTask?.cancel()
        pendingDriveTask = nil
        driveLimiter.reset()
    }

    private func flushPendingDrive() {
        guard let drive = pendingDrive else { return }
        let now = ContinuousClock.now
        switch driveLimiter.decision(for: drive, at: now) {
        case .skip:
            pendingDrive = nil
        case .send:
            pendingDrive = nil
            pendingDriveTask?.cancel()
            pendingDriveTask = nil
            driveLimiter.markSent(drive, at: now)
            send("gimbal") {
                try await $0.driveGimbal(pan: drive.pan, panSpeed: drive.panSpeed,
                                         tilt: drive.tilt, tiltSpeed: drive.tiltSpeed)
            }
        case .wait(let remaining):
            // One timer is enough: it flushes whatever is pending when it
            // fires, which is by then the newest update.
            guard pendingDriveTask == nil else { return }
            pendingDriveTask = Task { [weak self] in
                try? await Task.sleep(for: remaining)
                guard !Task.isCancelled, let self else { return }
                pendingDriveTask = nil
                flushPendingDrive()
            }
        }
    }

    // MARK: Zoom

    func setZoom(_ factor: Double) {
        let clamped = factor.clamped(to: zoomRange)
        zoomFactor = clamped
        send("zoom") { try await $0.setZoom(UInt16((clamped * 100).rounded())) }
    }

    /// Scroll-to-zoom entry point; delta is in zoom-factor units.
    func nudgeZoom(by delta: Double) {
        setZoom(zoomFactor + delta)
    }

    // MARK: Image controls

    func setBrightness(_ value: Double) {
        brightness.value = value
        send("brightness") { try await $0.setBrightness(UInt16(value.rounded())) }
    }

    func setContrast(_ value: Double) {
        contrast.value = value
        send("contrast") { try await $0.setContrast(UInt16(value.rounded())) }
    }

    func setSaturation(_ value: Double) {
        saturation.value = value
        send("saturation") { try await $0.setSaturation(UInt16(value.rounded())) }
    }

    func setSharpness(_ value: Double) {
        sharpness.value = value
        send("sharpness") { try await $0.setSharpness(UInt16(value.rounded())) }
    }

    func setHue(_ value: Double) {
        hue.value = value
        send("hue") { try await $0.setHue(Int16(value.rounded())) }
    }

    func setWhiteBalanceTemperature(_ kelvin: Double) {
        whiteBalanceTemperature.value = kelvin
        send("whiteBalance") { try await $0.setWhiteBalanceTemperature(UInt16(kelvin.rounded())) }
    }

    func setAutoWhiteBalance(_ enabled: Bool) {
        autoWhiteBalance = enabled
        send("whiteBalanceAuto") { try await $0.setAutoWhiteBalance(enabled) }
    }

    func setFocus(_ value: Double) {
        focus.value = value
        send("focus") { try await $0.setFocus(UInt16(value.rounded())) }
    }

    func setAutoFocus(_ enabled: Bool) {
        autoFocus = enabled
        send("focusAuto") { try await $0.setAutoFocus(enabled) }
    }

    func setRoll(_ value: Double) {
        roll.value = value
        send("roll") { try await $0.setRoll(Int16(value.rounded())) }
    }

    func setAntiFlicker(_ frequency: PowerLineFrequency) {
        antiFlicker = frequency
        send("antiFlicker") { try await $0.setPowerLineFrequency(frequency) }
    }

    // MARK: Video mode

    /// Switches the stream to the selected format. Resolution and frame rate
    /// are an `AVCaptureDevice.activeFormat` choice, not a camera setting: the
    /// XU 0x1C write side is a hardware-verified no-op (§9) and its read side
    /// only ever reports the format the host negotiated. So this drives the
    /// viewfinder's session, then re-reads 0x1C to show what actually took.
    func applyVideoMode() {
        guard canApplyVideoMode, let format = selectedVideoFormat,
              let rate = selectedFrameRate else { return }
        viewfinder?.selectVideoFormat(format, frameRate: rate)
        refreshCurrentVideoMode()
    }

    /// Re-reads XU 0x1C to show what the camera actually ended up streaming.
    /// Deliberately not on the write queue: this waits, and a queued gimbal
    /// stop must never sit behind it.
    private func refreshCurrentVideoMode() {
        let transport = transport
        Task { [weak self] in
            // The session renegotiates on its own queue; give it a moment
            // before asking the camera what it ended up streaming.
            try? await Task.sleep(for: .milliseconds(750))
            guard let confirmed = try? await transport.videoMode() else { return }
            self?.currentVideoMode = confirmed
        }
    }

    // MARK: Reads

    private func readSnapshot() async throws -> ControlSnapshot {
        try await ControlSnapshot(
            zoom: transport.zoom(),
            zoomRange: transport.zoomRange(),
            brightness: transport.brightness(),
            brightnessRange: transport.brightnessRange(),
            contrast: transport.contrast(),
            contrastRange: transport.contrastRange(),
            saturation: transport.saturation(),
            saturationRange: transport.saturationRange(),
            sharpness: transport.sharpness(),
            sharpnessRange: transport.sharpnessRange(),
            hue: transport.hue(),
            hueRange: transport.hueRange(),
            whiteBalance: transport.whiteBalanceTemperature(),
            whiteBalanceRange: transport.whiteBalanceTemperatureRange(),
            autoWhiteBalance: transport.isAutoWhiteBalanceEnabled(),
            focus: transport.focus(),
            focusRange: transport.focusRange(),
            autoFocus: transport.isAutoFocusEnabled(),
            roll: transport.roll(),
            rollRange: transport.rollRange(),
            antiFlicker: transport.powerLineFrequency(),
            videoMode: transport.videoMode())
    }

    private func apply(_ snapshot: ControlSnapshot) {
        let zoomMinimum = Double(snapshot.zoomRange.minimum) / 100
        let zoomMaximum = Double(snapshot.zoomRange.maximum) / 100
        if zoomMinimum < zoomMaximum { zoomRange = zoomMinimum...zoomMaximum }
        zoomFactor = (Double(snapshot.zoom) / 100).clamped(to: zoomRange)

        brightness.update(value: snapshot.brightness, deviceRange: snapshot.brightnessRange)
        contrast.update(value: snapshot.contrast, deviceRange: snapshot.contrastRange)
        saturation.update(value: snapshot.saturation, deviceRange: snapshot.saturationRange)
        sharpness.update(value: snapshot.sharpness, deviceRange: snapshot.sharpnessRange)
        hue.update(value: snapshot.hue, deviceRange: snapshot.hueRange)
        whiteBalanceTemperature.update(value: snapshot.whiteBalance,
                                       deviceRange: snapshot.whiteBalanceRange)
        focus.update(value: snapshot.focus, deviceRange: snapshot.focusRange)
        roll.update(value: snapshot.roll, deviceRange: snapshot.rollRange)
        autoWhiteBalance = snapshot.autoWhiteBalance
        autoFocus = snapshot.autoFocus
        antiFlicker = snapshot.antiFlicker

        currentVideoMode = snapshot.videoMode
        // Point the picker at the mode actually being streamed, when the
        // camera reports one the capture device also offers.
        if let mode = snapshot.videoMode,
           let format = videoFormats.first(where: { $0.id == "\(mode.width)x\(mode.height)" }) {
            selectedVideoFormatID = format.id
            let rate = Int(mode.framesPerSecond)
            selectedFrameRate = format.frameRates.contains(rate) ? rate : format.frameRates.first
        }
        if selectedFrameRate == nil { selectedFrameRate = availableFrameRates.first }

        statusMessage = nil
    }

    // MARK: Write plumbing

    private func send(_ key: String, requiresReady: Bool = true,
                      _ operation: @escaping @Sendable (UVCTransport) async throws -> Void) {
        if requiresReady && !isReady { return }
        let transport = transport
        writeQueue.submit(key) { try await operation(transport) }
    }
}

extension GimbalSpeedCaps {
    /// The ceilings as the user left them. `Preferences.registerDefaults()`
    /// puts a value behind both keys at launch; the fallback covers the two
    /// callers that never run it — SwiftUI previews and the Checks binaries —
    /// where a missing key would otherwise read as 0 and crawl at speed 1.
    static func persisted(_ defaults: UserDefaults = .standard) -> GimbalSpeedCaps {
        GimbalSpeedCaps(pan: fraction(defaults, Preferences.gimbalPanSpeed),
                        tilt: fraction(defaults, Preferences.gimbalTiltSpeed),
                        maxPanSpeed: UVCTransport.maxPanSpeed,
                        maxTiltSpeed: UVCTransport.maxTiltSpeed)
    }

    private static func fraction(_ defaults: UserDefaults, _ key: String) -> Double {
        let stored = defaults.double(forKey: key)
        return stored > 0 ? min(stored, 1) : 0.5
    }
}

/// Everything `scheduleRefresh` reads from the camera in one pass, so the
/// model's observable state updates atomically once the reads finish.
private struct ControlSnapshot: Sendable {
    var zoom: UInt16
    var zoomRange: UVCControlRange<UInt16>
    var brightness: UInt16
    var brightnessRange: UVCControlRange<UInt16>
    var contrast: UInt16
    var contrastRange: UVCControlRange<UInt16>
    var saturation: UInt16
    var saturationRange: UVCControlRange<UInt16>
    var sharpness: UInt16
    var sharpnessRange: UVCControlRange<UInt16>
    var hue: Int16
    var hueRange: UVCControlRange<Int16>
    var whiteBalance: UInt16
    var whiteBalanceRange: UVCControlRange<UInt16>
    var autoWhiteBalance: Bool
    var focus: UInt16
    var focusRange: UVCControlRange<UInt16>
    var autoFocus: Bool
    var roll: Int16
    var rollRange: UVCControlRange<Int16>
    var antiFlicker: PowerLineFrequency
    var videoMode: VideoMode?
}

/// Coalesces rapid UI writes (slider drags) so the camera sees at most one
/// in-flight transfer per control, always carrying the most recent value.
/// Different keys are drained FIFO; a newer write for the same key replaces
/// the pending one. That per-key ordering is what guarantees a gimbal stop
/// always lands after the drive it ends.
@MainActor
final class ControlWriteQueue {
    var onError: ((Error) -> Void)?

    private var pending: [String: @Sendable () async throws -> Void] = [:]
    private var order: [String] = []
    private var isDraining = false

    func submit(_ key: String, _ operation: @escaping @Sendable () async throws -> Void) {
        if pending.updateValue(operation, forKey: key) == nil {
            order.append(key)
        }
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    func cancelAll() {
        pending.removeAll()
        order.removeAll()
    }

    private func drain() async {
        while !order.isEmpty {
            let key = order.removeFirst()
            guard let operation = pending.removeValue(forKey: key) else { continue }
            do {
                try await operation()
            } catch {
                onError?(error)
            }
        }
        isDraining = false
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
