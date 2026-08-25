import Foundation

// How long an API-initiated gimbal drive is allowed to run, and the timer that
// enforces it. Foundation only and no camera anywhere in sight, so
// Checks/APIProtocolCheck.swift can exercise both the arithmetic and the timer
// firing for real, with no hardware and no app running.
//
// Two mechanisms, because they answer different questions:
//
//   `durationMs` is the caller saying how far it wants to move. It is the
//   normal way to pan a fixed amount from a single Stream Deck press.
//
//   The ceiling is the dead man's handle. It applies to every drive — with a
//   `durationMs`, without one, and over the top of a `durationMs` that asks
//   for longer. It exists for the case where the caller stops existing: a
//   crashed plugin, a yanked network cable, a laptop lid closed mid-press.
//   Without it, `POST /gimbal/drive` with no matching stop drives the head
//   until it hits the endstop.

/// Resolves a requested drive duration against the ceiling.
enum GimbalDrivePolicy {
    /// The dead man's handle: no API-initiated drive runs longer than this,
    /// whatever was asked for.
    ///
    /// Five seconds. The reasoning, and its weakness, both stated plainly:
    ///
    /// The ceiling does NOT bound how far a *working* client can pan — one can
    /// simply send another drive, and each one re-arms this. So its only job is
    /// to bound travel for a client that has stopped talking, and the number
    /// that matters is ceiling × the gimbal's angular rate.
    ///
    /// That rate has now been measured (2026-08-25, limit to limit, twice in
    /// each direction): pan runs at 65°/s at speed byte 30 and 33.5°/s at byte
    /// 15, tilt at 41°/s at byte 20 and 21.7°/s at byte 10 — linear in the
    /// speed byte to within about 5%.
    ///
    /// Those numbers contradict what this constant was originally chosen for.
    /// The pan envelope is ±145°, so from centre an abandoned drive reaches the
    /// endstop in 2.2s at full speed and 4.3s at the old default cap of 0.5;
    /// tilt's usable travel is ~142° total, reached in 1.7s and 3.3s. Five
    /// seconds does not keep an abandoned drive off the stop at any speed this
    /// camera offers. It was picked to, and it does not.
    ///
    /// It is kept at five seconds anyway, for now, because the failure it
    /// actually prevents is unbounded travel rather than a hard stop — the head
    /// parks against its limit and sits there, which is jarring but harmless —
    /// and because this number also sets the collision window with the
    /// Dashboard (see `APIRouter.armGimbalDeadMan`), so shortening it is not a
    /// free change. Holding to the original intent means something nearer
    /// 1.5s, or a ceiling that scales with the speed byte. That is a live
    /// decision, not an oversight.
    static let ceilingMilliseconds = 5_000

    /// Largest `durationMs` the API will parse. Anything inside this range and
    /// over the ceiling is clamped (and the response says so); anything beyond
    /// it is a 400, because it is a nonsense value rather than a long pan.
    static let maximumRequestedMilliseconds = 600_000

    /// Which limit actually decided the drive's length. Reported to the caller
    /// so a Stream Deck can show the real figure rather than the one it asked
    /// for.
    enum Limit: String, Sendable, Equatable {
        /// The caller's `durationMs` was honoured as sent.
        case duration
        /// The ceiling decided it: either no `durationMs` was given, or the one
        /// given was longer than the ceiling and was clamped.
        case ceiling
    }

    struct Resolution: Sendable, Equatable {
        /// How long the drive will actually run.
        var milliseconds: Int
        var limit: Limit
        /// What the caller asked for, when it asked for anything.
        var requestedMilliseconds: Int?

        var duration: Duration { .milliseconds(milliseconds) }
    }

    /// - Parameter requestedMilliseconds: the caller's `durationMs`, already
    ///   validated as a positive integer within `maximumRequestedMilliseconds`.
    static func resolve(requestedMilliseconds: Int?) -> Resolution {
        guard let requested = requestedMilliseconds else {
            return Resolution(milliseconds: ceilingMilliseconds, limit: .ceiling,
                              requestedMilliseconds: nil)
        }
        // Exactly at the ceiling counts as honoured — the caller got what it
        // asked for, so calling that a clamp would be a lie.
        guard requested > ceilingMilliseconds else {
            return Resolution(milliseconds: requested, limit: .duration,
                              requestedMilliseconds: requested)
        }
        return Resolution(milliseconds: ceilingMilliseconds, limit: .ceiling,
                          requestedMilliseconds: requested)
    }
}

/// The timer itself: arm it when a drive starts, disarm it when something else
/// legitimately ends the drive, and if neither happens it stops the gimbal on
/// its own.
///
/// The stop action is injected rather than reached for directly, which is what
/// lets the check drive this with a counter instead of a camera — the timing
/// behaviour is the part worth testing and it has nothing to do with USB.
@MainActor
final class GimbalDeadMan {
    private let stop: @MainActor () -> Void
    private var task: Task<Void, Never>?
    /// Bumped by every arm and every disarm. `Task.cancel()` cannot stop a
    /// timer that has already finished sleeping and is suspended on the hop
    /// back onto the main actor, so cancellation alone would still let a
    /// disarmed timer fire a stop into a drive that has since been replaced.
    private var generation = 0

    init(stop: @escaping @MainActor () -> Void) {
        self.stop = stop
    }

    /// True while a drive is outstanding and this timer is what will end it.
    var isArmed: Bool { task != nil }

    func arm(for duration: Duration) {
        generation += 1
        let generation = self.generation
        task?.cancel()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            self?.fire(generation: generation)
        }
    }

    /// Called when the drive is ended by something else — an explicit stop, a
    /// centre, or the server shutting down. Leaves the gimbal alone; the caller
    /// is responsible for whatever stop it is doing instead.
    func disarm() {
        generation += 1
        task?.cancel()
        task = nil
    }

    private func fire(generation: Int) {
        guard generation == self.generation else { return }
        task = nil
        stop()
    }
}

// MARK: - Answering the client

// How `CameraControlsModel`'s two ownership answers become HTTP. Kept here,
// beside the duration arithmetic and away from the router, so the check can
// pin the status taxonomy without standing up a camera.

extension GimbalDrivePolicy {
    /// How a drive request is answered. `nil` means `.accepted` and the caller
    /// should go on to arm the dead-man and report the duration.
    ///
    /// The two refusals get different statuses on purpose, because they are
    /// different things to a Stream Deck and only one of them needs the user
    /// to go and do something.
    static func refusal(for result: GimbalDriveResult) -> APIFault? {
        switch result {
        case .accepted:
            return nil

        case .refusedControlHeld:
            // 409, matching `camera_busy` — the closest thing already in this
            // API's taxonomy and the same shape exactly: somebody else has the
            // camera this moment, nothing is broken, try again shortly. RFC
            // 9110 §15.5.10 is a good fit on its own terms ("conflict with the
            // current state of the target resource", resubmittable), but the
            // consistency argument is the stronger one — an API whose statuses
            // are predictable beats one where each case was argued from first
            // principles and landed somewhere different.
            //
            // Deliberately not 503: in this API 503 means the camera is absent
            // or not answering, which is a device problem that will not clear
            // by itself. Folding "a person is using it" into that would erase
            // the one distinction worth drawing here.
            //
            // Deliberately not 423 Locked: apt in the abstract, but a WebDAV
            // extension that generic HTTP clients and Stream Deck plugins do
            // not recognise, which buys the caller nothing.
            //
            // No `Retry-After`: it lasts as long as a person holds a control,
            // which is unknowable, and inventing a number would be fabricating
            // data the server does not have.
            return APIFault(
                status: .conflict, code: "gimbal_control_held",
                message: "Somebody is using Betterlink's on-screen gimbal controls right now. "
                    + "While a control is held, API drives wait so that letting go always "
                    + "stops the camera. This clears by itself — retry in a moment.")

        case .refusedCameraNotReady:
            return APIFault(
                status: .serviceUnavailable, code: "camera_unavailable",
                message: "The camera's controls are not ready.")
        }
    }

    /// What `POST /gimbal/stop` says, given whether the stop actually reached
    /// the camera.
    struct StopOutcome: Sendable, Equatable {
        var stopped: Bool
        var status: HTTPStatus
        /// Machine-readable, present only when `stopped` is false.
        var reason: String?
        var detail: String
    }

    /// - Parameter stopped: `endGimbalDrive(owner: .api)`'s answer. False does
    ///   not mean the stop failed — it means somebody else holds the head, so
    ///   there was nothing of ours to end.
    static func stopOutcome(stopped: Bool) -> StopOutcome {
        guard stopped else {
            // 200, not 202. This API documents 202 as "queued on the camera
            // write queue, may not have landed yet", and in this branch
            // nothing was queued at all — the model returned before touching
            // the wire. The outcome is already final, which is what 200 says.
            // Answering 202 here would be a smaller version of the exact lie
            // this return value exists to stop telling.
            //
            // Still 2xx: nothing went wrong and there is nothing to retry.
            // This owner's drive is over either way. What the caller must not
            // be allowed to conclude is that the camera is stationary.
            return StopOutcome(
                stopped: false, status: .ok, reason: "control_held",
                detail: "This drive is over, but the gimbal is under the Dashboard's control "
                    + "and may still be moving. It stops when the person using it lets go.")
        }
        return StopOutcome(stopped: true, status: .accepted, reason: nil,
                           detail: "The gimbal has been told to stop.")
    }
}
