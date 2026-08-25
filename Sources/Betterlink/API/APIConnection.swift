import Foundation
import Network

// One accepted TCP connection: read a single bounded request, answer it, close.
//
// One request per connection on purpose. Keep-alive would save a Stream Deck a
// round trip and cost this server pipelining state, a second set of framing
// bugs to get wrong, and an idle-socket timer to leak descriptors through.
// Closing after every response means the only state a connection can be in is
// "still reading its one request", which is the state the deadline below
// bounds.
//
// An actor rather than a queue-confined class: every Network framework type
// used here is Sendable under Swift 6, so the callbacks can hop into actor
// isolation directly, and the one hop that matters — onto the main actor to
// touch the camera models — is spelled out in `serve(_:)`.
actor APIConnection {
    /// Wall-clock budget from accept to a complete request. This is a total
    /// deadline, not an inter-read idle timer: a client that opens a socket
    /// and says nothing is closed by it, and so is one that dribbles a byte at
    /// a time to hold the connection open (slowloris), which an idle timer
    /// would happily let run forever.
    private static let requestDeadlineSeconds = 10
    private static let requestDeadline = Duration.seconds(requestDeadlineSeconds)

    /// Budget for getting the response out once it has been built. The read
    /// deadline is stood down while the camera does its work — a preset
    /// restore legitimately takes seconds — so the write phase needs its own,
    /// or a client that stops reading would pin the connection open forever.
    private static let sendDeadline = Duration.seconds(10)

    /// Budget for the router's own work — the camera round trips. Generous,
    /// because a preset restore legitimately writes a dozen USB control
    /// transfers, but not unbounded: `IOUSBDevRequest`'s `DeviceRequest` has
    /// no timeout of its own, so a camera that stops answering blocks the
    /// transport actor forever. Without a ceiling here those requests would
    /// pin every one of the server's connection slots and the API would stay
    /// unreachable until the app was quit.
    private static let workDeadlineSeconds = 20
    private static let workDeadline = Duration.seconds(workDeadlineSeconds)


    /// Never read more in one go than the parser will accept in one chunk, so
    /// the parser's ceilings are the only ceilings that need to be right.
    private static let readChunkBytes = 16 * 1024

    private let id: UUID
    private let connection: NWConnection
    private let router: APIRouter
    private let queue: DispatchQueue

    private var parser = HTTPRequestParser()
    private var deadlineTask: Task<Void, Never>?
    private var onFinish: (@Sendable (UUID) -> Void)?
    private var isFinished = false
    /// True once a response is on its way out, so an expiring deadline closes
    /// the connection instead of trying to write a second response into it.
    private var isResponding = false
    /// Bumped by every arm and every cancel. `Task.cancel()` cannot stop a
    /// deadline task that has already passed its cancellation check and is
    /// suspended on the hop back into this actor, so cancellation alone is not
    /// enough: without this, a deadline cancelled the instant before it fired
    /// could still answer 408 for a request whose camera write had already
    /// landed, or tear the connection down in the middle of a send.
    private var deadlineGeneration = 0

    init(id: UUID, connection: NWConnection, router: APIRouter, queue: DispatchQueue) {
        self.id = id
        self.connection = connection
        self.router = router
        self.queue = queue
    }

    // MARK: - Lifecycle

    nonisolated func start(onFinish: @escaping @Sendable (UUID) -> Void) {
        Task { await self.begin(onFinish: onFinish) }
    }

    nonisolated func cancel() {
        Task { await self.finish() }
    }

    private func begin(onFinish: @escaping @Sendable (UUID) -> Void) {
        // `start(onFinish:)` and `cancel()` each enqueue an unordered task, so
        // a cancel can arrive first. Finishing is terminal: never re-arm a
        // deadline or re-start a connection that has already been torn down.
        guard !isFinished else { return }
        self.onFinish = onFinish
        armDeadline(Self.requestDeadline)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.stateChanged(state) }
        }
        connection.start(queue: queue)
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            receive()
        case .failed, .cancelled:
            finish()
        default:
            break
        }
    }

    private func armDeadline(_ duration: Duration) {
        deadlineGeneration += 1
        let generation = deadlineGeneration
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            await self?.deadlineExpired(generation: generation)
        }
    }

    private func cancelDeadline() {
        deadlineGeneration += 1
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func deadlineExpired(generation: Int) {
        // The generation, not `Task.isCancelled`, is what makes this safe: a
        // task already suspended on the hop into this actor runs to completion
        // regardless of cancellation.
        guard generation == deadlineGeneration, !isFinished else { return }
        guard !isResponding else {
            // The peer stopped reading mid-response. Nothing left to say.
            finish()
            return
        }
        respond(APIFault(status: .requestTimeout, code: "request_timeout",
                         message: "The request was not complete within "
                             + "\(Self.requestDeadlineSeconds) seconds of connecting.").response)
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        cancelDeadline()
        connection.stateUpdateHandler = nil
        connection.cancel()
        onFinish?(id)
        onFinish = nil
    }

    // MARK: - Reading

    private func receive() {
        guard !isFinished else { return }
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: Self.readChunkBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.received(data, isComplete: isComplete, error: error) }
        }
    }

    private func received(_ data: Data?, isComplete: Bool, error: NWError?) async {
        guard !isFinished else { return }
        if error != nil {
            finish()
            return
        }
        if let data, !data.isEmpty {
            do {
                switch try parser.append(data) {
                case .complete(let request):
                    await serve(request)
                    return
                case .needMoreData:
                    break
                }
            } catch {
                // A protocol-level refusal is answered rather than dropped:
                // a client that sent a body one byte over the cap deserves a
                // 413 it can act on, not a bare RST. These answers say nothing
                // about the camera, the presets, or the token.
                respond(APIFault(status: error.status, code: error.code,
                                 message: error.description).response)
                return
            }
        }
        if isComplete {
            // The peer half-closed before finishing its request.
            finish()
            return
        }
        receive()
    }

    // MARK: - Answering

    private func serve(_ request: HTTPRequest) async {
        // The request is fully read, so the read deadline is stood down: the
        // camera work below is legitimately slow (a preset restore writes a
        // dozen USB control transfers) and must not be cut off by a timer
        // meant for a stalled socket. The write phase re-arms its own.
        cancelDeadline()
        guard !isFinished else { return }
        let response = await respondWithinWorkDeadline(to: request)
        respond(response, suppressBody: request.method == .head)
    }

    /// Runs the router against a deadline, abandoning it rather than waiting
    /// if it overruns.
    ///
    /// Abandoning is the whole point, and it is why this is not a task group:
    /// a group waits for every child when its scope exits, which is exactly
    /// the wait being avoided. A blocked synchronous USB transfer will not
    /// notice cancellation either, so the losing task is simply let go — it
    /// finishes whenever the transport does, having resumed nothing. What is
    /// recovered is the connection slot, so a wedged camera degrades the API
    /// to prompt 503s instead of making it unreachable.
    private func respondWithinWorkDeadline(to request: HTTPRequest) async -> HTTPResponse {
        let router = self.router
        let timedOut = APIFault(
            status: .serviceUnavailable, code: "camera_timeout",
            message: "The camera did not respond within \(Self.workDeadlineSeconds) seconds.")
            .response
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let timeout = Task {
                try? await Task.sleep(for: Self.workDeadline)
                once.resume(timedOut)
            }
            Task {
                let response = await router.respond(to: request)
                timeout.cancel()
                once.resume(response)
            }
        }
    }

    private func respond(_ response: HTTPResponse, suppressBody: Bool = false) {
        guard !isFinished, !isResponding else { return }
        isResponding = true
        armDeadline(Self.sendDeadline)
        connection.send(content: response.serialized(suppressBody: suppressBody),
                        completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            Task { await self.finish() }
        })
    }
}

/// Resumes a continuation exactly once, whichever of two racing tasks reaches
/// it first. A continuation resumed twice is a crash, and one never resumed is
/// a hung connection, so the single-resume rule is enforced here rather than
/// left to the ordering of the two tasks above.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
