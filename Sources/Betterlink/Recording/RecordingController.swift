import AppKit
import AVFoundation
import Observation

/// AVFoundation capture types predate Sendable. The session is only ever mutated
/// on the viewfinder's session queue and the device reference is read-only;
/// these wrappers state that contract (same discipline as ViewfinderModel).
private struct SessionBox: @unchecked Sendable { let session: AVCaptureSession }
private struct AudioDeviceBox: @unchecked Sendable { let device: AVCaptureDevice? }

/// Host-side recording of the viewfinder's capture session (ROADMAP Phase 2).
/// The Link has no in-camera record command (investigation-findings.md §3.3);
/// recording is an `AVCaptureMovieFileOutput` plus a microphone input attached
/// to the shared session for the duration of a recording and removed afterwards,
/// so the plain viewfinder never holds the mic open.
///
/// All session mutations happen on the viewfinder's serial `sessionQueue`,
/// honouring the one-queue discipline ViewfinderModel established.
@MainActor
@Observable
final class RecordingController: NSObject {
    enum State: Equatable {
        case idle
        case starting
        case recording(startedAt: Date)
        case stopping
        case failed(message: String)
    }

    private(set) var state: State = .idle

    /// The last successfully finished recording, for UI affordances.
    private(set) var lastRecordingURL: URL?

    /// Matches the official app's free-space floor (§3.3).
    private nonisolated static let minimumFreeSpace: Int64 = 200 * 1_000_000

    private let sessionBox: SessionBox
    private let sessionQueue: DispatchQueue

    /// A stop asked for while the recording was still starting. AVFoundation
    /// has nothing to finish until `didStartRecordingTo` fires — four to six
    /// seconds after the start on this camera — so the request is held here
    /// and applied the moment the recording does begin. Dropping it instead
    /// left the camera recording after the user had asked it to stop.
    ///
    /// Cleared on every `startRecording()`, which is enough: it is read in
    /// exactly one place, the delegate callback for the recording that is
    /// starting right now.
    private var stopRequestedWhileStarting = false

    /// The pieces added to the shared session for the current recording.
    /// Created and removed only on `sessionQueue`.
    @ObservationIgnored private nonisolated(unsafe) var movieOutput: AVCaptureMovieFileOutput?
    @ObservationIgnored private nonisolated(unsafe) var audioInput: AVCaptureDeviceInput?

    /// - Parameters:
    ///   - session: the viewfinder's capture session; recording borrows it.
    ///   - sessionQueue: the single serial queue on which that session is mutated.
    init(session: AVCaptureSession, sessionQueue: DispatchQueue) {
        self.sessionBox = SessionBox(session: session)
        self.sessionQueue = sessionQueue
        super.init()
    }

    /// Starts a recording into a timestamped file in ~/Movies. Safe to call in
    /// any state; only idle/failed begin a new recording.
    func startRecording() {
        switch state {
        case .idle, .failed:
            break
        case .starting, .recording, .stopping:
            return
        }
        state = .starting
        stopRequestedWhileStarting = false
        Task {
            let audioBox = await Self.selectAudioDevice()
            beginCapture(audio: audioBox)
        }
    }

    /// Asks the movie output to finish; completion lands in the file-output
    /// delegate, which removes the recording graph and settles the state.
    ///
    /// A stop during `.starting` is latched rather than dropped — see
    /// `stopRequestedWhileStarting`.
    func stopRecording() {
        switch state {
        case .recording:
            break
        case .starting:
            stopRequestedWhileStarting = true
            return
        case .idle, .stopping, .failed:
            return
        }
        state = .stopping
        sessionQueue.async { [weak self] in
            self?.movieOutput?.stopRecording()
        }
    }

    // MARK: - Capture graph

    private func beginCapture(audio: AudioDeviceBox) {
        let sessionBox = sessionBox
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let url: URL
            do {
                url = try Self.makeOutputURL()
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in self.startFailed(message) }
                return
            }

            let session = sessionBox.session
            let output = AVCaptureMovieFileOutput()
            var addedAudio: AVCaptureDeviceInput?
            var failure: String?

            session.beginConfiguration()
            if session.isRunning {
                if let device = audio.device {
                    do {
                        let input = try AVCaptureDeviceInput(device: device)
                        if session.canAddInput(input) {
                            session.addInput(input)
                            addedAudio = input
                        }
                    } catch {
                        // Record video-only rather than fail the whole recording.
                    }
                }
                if session.canAddOutput(output) {
                    session.addOutput(output)
                } else {
                    failure = "The capture session cannot accept a movie output."
                    if let input = addedAudio {
                        session.removeInput(input)
                        addedAudio = nil
                    }
                }
            } else {
                failure = "The camera is not streaming; recording needs a live viewfinder."
            }
            session.commitConfiguration()

            if let failure {
                Task { @MainActor in self.startFailed(failure) }
                return
            }
            self.movieOutput = output
            self.audioInput = addedAudio
            output.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// Removes the recording graph from the shared session. The viewfinder's
    /// own video input and preview are untouched. Runs on `sessionQueue`;
    /// tolerates the pieces having already been removed by a session
    /// reconfiguration (camera swap/disconnect mid-recording).
    private nonisolated func removeCaptureGraph() {
        let session = sessionBox.session
        session.beginConfiguration()
        if let output = movieOutput, session.outputs.contains(output) {
            session.removeOutput(output)
        }
        if let input = audioInput, session.inputs.contains(input) {
            session.removeInput(input)
        }
        movieOutput = nil
        audioInput = nil
        session.commitConfiguration()
    }

    // MARK: - State settlement (main actor)

    private func startFailed(_ message: String) {
        state = .failed(message: message)
    }

    private func finishRecording(url: URL, failureMessage: String?) {
        if let failureMessage {
            state = .failed(message: failureMessage)
            return
        }
        state = .idle
        lastRecordingURL = url
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Audio source

    /// The Link's own microphone when attached, otherwise the system default
    /// input, otherwise any connected mic. Returns no device when microphone
    /// access is denied — the recording proceeds video-only.
    private nonisolated static func selectAudioDevice() async -> AudioDeviceBox {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            allowed = true
        case .notDetermined:
            allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            allowed = false
        }
        guard allowed else { return AudioDeviceBox(device: nil) }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        let mics = discovery.devices.filter(\.isConnected)
        let device = mics.first(where: LinkCamera.isLink)
            ?? AVCaptureDevice.default(for: .audio)
            ?? mics.first
        return AudioDeviceBox(device: device)
    }

    // MARK: - Output file

    /// Timestamped .mov in ~/Movies, refusing to start under the free-space floor.
    private nonisolated static func makeOutputURL() throws -> URL {
        let fileManager = FileManager.default
        guard let movies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            throw RecordingError.moviesFolderUnavailable
        }
        try fileManager.createDirectory(at: movies, withIntermediateDirectories: true)
        let values = try? movies.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < minimumFreeSpace {
            throw RecordingError.lowDiskSpace
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Link Recording \(formatter.string(from: Date()))"
        var url = movies.appendingPathComponent("\(base).mov")
        var counter = 2
        while fileManager.fileExists(atPath: url.path) {
            url = movies.appendingPathComponent("\(base) (\(counter)).mov")
            counter += 1
        }
        return url
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension RecordingController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor in
            guard case .starting = state else { return }
            state = .recording(startedAt: Date())
            if stopRequestedWhileStarting {
                stopRequestedWhileStarting = false
                stopRecording()
            }
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        // A recording interrupted by session teardown (camera unplugged, app
        // shutdown) reports an error yet may still have written a playable
        // file; AVFoundation flags that case in the error's userInfo.
        let failureMessage: String? = {
            guard let error else { return nil }
            let info = (error as NSError).userInfo
            if (info[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true { return nil }
            return error.localizedDescription
        }()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            removeCaptureGraph()
            Task { @MainActor in
                self.finishRecording(url: outputFileURL, failureMessage: failureMessage)
            }
        }
    }
}

// MARK: - Errors

private enum RecordingError: LocalizedError {
    case moviesFolderUnavailable
    case lowDiskSpace

    var errorDescription: String? {
        switch self {
        case .moviesFolderUnavailable:
            "The Movies folder could not be located."
        case .lowDiskSpace:
            "Not enough free disk space to record (200 MB minimum)."
        }
    }
}
