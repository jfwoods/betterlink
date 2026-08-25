import AVFoundation
import Observation

/// AVFoundation capture types predate Sendable. The session is only ever mutated
/// on `ViewfinderModel.sessionQueue` (Apple's recommended serial-queue discipline)
/// and the device reference is read-only; these wrappers state that contract.
private struct SessionBox: @unchecked Sendable { let session: AVCaptureSession }
private struct DeviceBox: @unchecked Sendable { let device: AVCaptureDevice }

/// One selectable stream format, as plain values the UI can bind to: the
/// camera's own formats of this size, with every whole frame rate they offer
/// merged together.
///
/// Only LANDSCAPE formats are ever offered. The camera silently refuses every
/// gimbal tilt command — relative and absolute alike — while it streams a
/// portrait format (verified on hardware 2026-08-21, §9), so a selectable
/// portrait mode would break tilt. Do not add them back.
struct VideoFormatOption: Identifiable, Hashable, Sendable {
    let width: Int32
    let height: Int32
    /// Whole frames per second, highest first.
    let frameRates: [Int]

    var id: String { "\(width)x\(height)" }
    var label: String { "\(width) × \(height)" }
}

/// Owns the capture session behind the Dashboard viewfinder: camera permission,
/// device discovery, and disconnect/reconnect handling.
@MainActor
@Observable
final class ViewfinderModel {
    enum Status: Equatable {
        case checkingAccess
        case accessDenied
        case noCamera
        case live(cameraName: String, isLink: Bool)
        case failed(message: String)
    }

    private(set) var status: Status = .checkingAccess

    /// The stream formats the attached camera advertises, for the Dashboard's
    /// Video Mode picker. Empty while no camera is attached.
    private(set) var videoFormats: [VideoFormatOption] = []

    /// Attached to the preview layer on the main actor; mutated only on `sessionQueue`.
    let session = AVCaptureSession()

    /// The single preview layer for the app, owned here so it lives exactly as
    /// long as the session. Deallocating a preview layer that is still attached
    /// to a running session makes the session post runtime error -11800
    /// (OSStatus -67520) on macOS 26, which is what a per-view layer did every
    /// time the Dashboard was navigated away from. Views borrow this layer;
    /// they must never create their own.
    let previewLayer: AVCaptureVideoPreviewLayer

    /// When true the stream uses the camera's portrait (9:16) format — what
    /// AVFoundation picked by default before the landscape pin. The camera
    /// refuses every gimbal tilt command while streaming portrait (§9), so
    /// this is off by default and the UI warns about the trade.
    private(set) var streamsPortrait = false

    /// Host-side recording (ROADMAP Phase 2). Owned here so an in-flight
    /// recording survives Dashboard navigation, and so it shares the session's
    /// single serial-queue discipline.
    let recorder: RecordingController

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        recorder = RecordingController(session: session, sessionQueue: sessionQueue)
    }

    private let sessionQueue = DispatchQueue(label: "me.jfwoods.Betterlink.viewfinder-session")
    private let discovery = LinkCamera.discoverySession()
    private var currentDeviceID: String?
    /// The attached device, so a format switch can reach it off the main actor.
    @ObservationIgnored private var currentDevice: DeviceBox?
    private var started = false
    @ObservationIgnored private nonisolated(unsafe) var observers: [any NSObjectProtocol] = []

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Idempotent entry point, called from the view's `.task`. Requests camera
    /// access, then follows device connects/disconnects for the life of the model.
    func start() async {
        guard !started else { return }
        started = true
        guard await ensureAccess() else {
            status = .accessDenied
            return
        }
        observeDeviceChanges()
        attachBestCamera()
    }

    private func ensureAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    private func observeDeviceChanges() {
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.attachBestCamera() }
            })
        }
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                ?? "The capture session reported an error."
            Task { @MainActor in self?.sessionFailed(message) }
        })
    }

    /// Points the session at the best available camera, or tears it down when
    /// none is attached. Cheap and idempotent, so it simply re-runs on every
    /// device connect/disconnect notification.
    private func attachBestCamera() {
        if let device = LinkCamera.bestCamera(in: discovery.devices.filter(\.isConnected)) {
            guard device.uniqueID != currentDeviceID else { return }
            currentDeviceID = device.uniqueID
            currentDevice = DeviceBox(device: device)
            videoFormats = Self.formatOptions(of: device, portrait: streamsPortrait)
            status = .live(cameraName: device.localizedName, isLink: LinkCamera.isLink(device))
            configureSession(for: device)
        } else {
            currentDeviceID = nil
            currentDevice = nil
            videoFormats = []
            status = .noCamera
            teardownSession()
        }
    }

    /// Switches the live stream to `option` at `frameRate` fps. This is what
    /// the Dashboard's Video Mode picker drives: resolution and frame rate are
    /// an `activeFormat` choice on the capture device, not a camera setting
    /// (XU 0x1C's write side is a hardware-verified no-op, §9).
    /// Best-effort: an unknown size or a camera that cannot be locked leaves
    /// the stream as it was.
    /// Switches the stream between the landscape formats (tilt works) and the
    /// camera's portrait ones (tilt does not, §9). Re-picks that orientation's
    /// default size, and re-stocks `videoFormats` for the picker.
    func setStreamsPortrait(_ portrait: Bool) {
        guard portrait != streamsPortrait else { return }
        streamsPortrait = portrait
        guard let deviceBox = currentDevice else { return }
        videoFormats = Self.formatOptions(of: deviceBox.device, portrait: portrait)
        let sessionBox = SessionBox(session: session)
        sessionQueue.async {
            sessionBox.session.beginConfiguration()
            Self.selectPreferredFormat(on: deviceBox.device, portrait: portrait)
            sessionBox.session.commitConfiguration()
            // Same re-assert the picker needs: the assignment only sticks once
            // the running session has renegotiated.
            Self.selectPreferredFormat(on: deviceBox.device, portrait: portrait)
        }
    }

    func selectVideoFormat(_ option: VideoFormatOption, frameRate: Int) {
        guard let deviceBox = currentDevice else { return }
        let sessionBox = SessionBox(session: session)
        let portrait = streamsPortrait
        sessionQueue.async {
            // Format and frame duration take effect together at
            // commitConfiguration — but on this camera the assignment only
            // sticks if it is repeated once the session is running again,
            // exactly as `configureSession` has to do after `startRunning`.
            sessionBox.session.beginConfiguration()
            Self.selectFormat(on: deviceBox.device, width: option.width,
                              height: option.height, frameRate: frameRate)
            sessionBox.session.commitConfiguration()
            Self.selectFormat(on: deviceBox.device, width: option.width,
                              height: option.height, frameRate: frameRate)
            // Never end up portrait by accident: that silently disables the
            // gimbal's tilt axis (§9). A refused landscape format falls back to
            // the default landscape pick rather than stranding the user. When
            // portrait is what was asked for, this is not a rescue case.
            let active = Self.size(deviceBox.device.activeFormat)
            if !portrait, active.height > active.width {
                Self.selectPreferredFormat(on: deviceBox.device, portrait: false)
            }
        }
    }

    private nonisolated static func size(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
        CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    }

    /// The camera's formats in one orientation, one entry per distinct size,
    /// largest first. The two orientations never mix in the picker: the whole
    /// point of the portrait toggle is that it also decides whether tilt works.
    private nonisolated static func formatOptions(of device: AVCaptureDevice,
                                                  portrait: Bool) -> [VideoFormatOption] {
        var rates: [String: (CMVideoDimensions, Set<Int>)] = [:]
        for format in device.formats
        where portrait ? size(format).height > size(format).width
                       : size(format).width > size(format).height {
            let dimensions = size(format)
            var entry = rates["\(dimensions.width)x\(dimensions.height)"] ?? (dimensions, [])
            for range in format.videoSupportedFrameRateRanges {
                entry.1.insert(Int(range.maxFrameRate.rounded()))
            }
            rates["\(dimensions.width)x\(dimensions.height)"] = entry
        }
        return rates.values
            .map { VideoFormatOption(width: $0.0.width, height: $0.0.height, frameRates: $0.1.sorted(by: >)) }
            .sorted { Int($0.width) * Int($0.height) > Int($1.width) * Int($1.height) }
    }

    /// Assigns the device format of the given size (and frame rate, when one is
    /// asked for). Frame durations come from the format's own range object: an
    /// unsupported value raises an Objective-C exception Swift cannot catch.
    private nonisolated static func selectFormat(on device: AVCaptureDevice, width: Int32,
                                                 height: Int32, frameRate: Int?) {
        func rateRange(_ format: AVCaptureDevice.Format) -> AVFrameRateRange? {
            guard let frameRate else { return nil }
            return format.videoSupportedFrameRateRanges
                .first { Int($0.maxFrameRate.rounded()) == frameRate }
        }
        let match = device.formats.first { format in
            size(format).width == width && size(format).height == height
                && (frameRate == nil || rateRange(format) != nil)
        }
        guard let match, (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = match
        if let range = rateRange(match) {
            // Both ends, so the camera is pinned to the chosen rate rather
            // than merely capped at it.
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.activeVideoMaxFrameDuration = range.minFrameDuration
        }
        device.unlockForConfiguration()
    }

    /// Default pick on attach: 1080p landscape, so the stream is never the
    /// 1080x1920 portrait format that locks the gimbal's tilt axis. 1080p
    /// rather than the camera's largest format: 4K exists in the format list
    /// but the Link is a USB 2.0 device, and session presets are no use here
    /// (every preset still negotiates the portrait format on this unit).
    private nonisolated static func selectPreferredFormat(on device: AVCaptureDevice,
                                                          portrait: Bool) {
        let options = formatOptions(of: device, portrait: portrait)
        let preferred = portrait ? (width: Int32(1080), height: Int32(1920))
                                 : (width: Int32(1920), height: Int32(1080))
        guard let choice = options.first(where: { $0.width == preferred.width && $0.height == preferred.height })
            ?? options.first else { return }
        selectFormat(on: device, width: choice.width, height: choice.height, frameRate: nil)
    }

    private func configureSession(for device: AVCaptureDevice) {
        let sessionBox = SessionBox(session: session)
        let deviceBox = DeviceBox(device: device)
        let deviceID = device.uniqueID
        let portrait = streamsPortrait
        sessionQueue.async { [weak self] in
            let session = sessionBox.session
            var failure: String?
            session.beginConfiguration()
            // The Link offers a 1080x1920 portrait format, AVFoundation picks it
            // by default on this unit, and the camera refuses every tilt command
            // — relative and absolute alike — while it is streaming portrait.
            // A session preset is not enough (every preset maps onto the
            // portrait format on this unit), so the landscape format is chosen
            // on the device itself, after the input is added — adding an input
            // re-negotiates the format (verified on hardware 2026-08-21, §9).
            for input in session.inputs {
                session.removeInput(input)
            }
            do {
                let input = try AVCaptureDeviceInput(device: deviceBox.device)
                if session.canAddInput(input) {
                    session.addInput(input)
                    Self.selectPreferredFormat(on: deviceBox.device, portrait: portrait)
                } else {
                    failure = "The camera's video stream could not be added to the capture session."
                }
            } catch {
                failure = error.localizedDescription
            }
            session.commitConfiguration()
            if failure == nil, !session.isRunning {
                session.startRunning()
                // Re-assert it: starting the session can renegotiate the format.
                Self.selectPreferredFormat(on: deviceBox.device, portrait: portrait)
            }
            if let failure {
                Task { @MainActor in self?.attachFailed(deviceID: deviceID, message: failure) }
            }
        }
    }

    private func teardownSession() {
        let sessionBox = SessionBox(session: session)
        sessionQueue.async {
            let session = sessionBox.session
            session.stopRunning()
            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            session.commitConfiguration()
        }
    }

    private func attachFailed(deviceID: String, message: String) {
        // Ignore stale failures from a device we have already moved away from.
        guard deviceID == currentDeviceID else { return }
        status = .failed(message: message)
    }

    private func sessionFailed(_ message: String) {
        guard case .live = status else { return }
        status = .failed(message: message)
    }
}
