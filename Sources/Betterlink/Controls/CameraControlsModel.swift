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

/// The four gimbal pad directions, mapped onto the XU relative pan/tilt axes.
///
/// The direction sign is NOT hardware-verified (§9): the prior CLI shipped
/// with a sign inverted relative to its own documentation. If up/down or
/// left/right move the wrong way on a real Link, flip the mapping here —
/// nowhere else.
enum GimbalPadDirection: Sendable {
    case up, down, left, right

    var pan: GimbalDirection {
        switch self {
        case .left: .negative
        case .right: .positive
        case .up, .down: .stop
        }
    }

    /// Tilt's direction byte runs opposite the pan one: 0x01 drives the head
    /// down (and the absolute reading negative), 0xFF drives it up — verified
    /// on hardware 2026-08-21 (§9), once a landscape stream made tilt respond
    /// at all.
    var tilt: GimbalDirection {
        switch self {
        case .up: .negative
        case .down: .positive
        case .left, .right: .stop
        }
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

    /// App-local speed scale (never written to the camera by itself); the
    /// per-axis speeds below scale it into the verified caps (pan 0–30,
    /// tilt 0–20, §4) at the moment a drive starts.
    var gimbalSpeed = 0.5

    var panSpeed: Int {
        max(1, Int((gimbalSpeed * Double(UVCTransport.maxPanSpeed)).rounded()))
    }

    var tiltSpeed: Int {
        max(1, Int((gimbalSpeed * Double(UVCTransport.maxTiltSpeed)).rounded()))
    }

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
                statusMessage = "Could not read camera controls: \(error)"
            }
        }
    }

    private func detach() {
        refreshGeneration += 1
        isReady = false
        statusMessage = nil
        writeQueue.cancelAll()
        let transport = transport
        Task { await transport.disconnect() }
    }

    // MARK: Gimbal drive

    /// Starts a relative pan/tilt drive; the camera keeps moving until the
    /// matching `endGimbalDrive()`. The write queue is FIFO per key, so the
    /// stop is guaranteed to land after the drive it ends (and a stop that is
    /// still pending when the pad is pressed again is simply replaced).
    func beginGimbalDrive(_ direction: GimbalPadDirection) {
        let panSpeed = UInt8(self.panSpeed)
        let tiltSpeed = UInt8(self.tiltSpeed)
        send("gimbal") { transport in
            try await transport.driveGimbal(pan: direction.pan, panSpeed: panSpeed,
                                            tilt: direction.tilt, tiltSpeed: tiltSpeed)
        }
    }

    /// Bypasses the ready gate: a stop must go out even if the connection
    /// state flipped mid-hold.
    func endGimbalDrive() {
        send("gimbal", requiresReady: false) { try await $0.stopGimbal() }
    }

    func centerGimbal() {
        send("gimbal") { try await $0.centerGimbal() }
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
