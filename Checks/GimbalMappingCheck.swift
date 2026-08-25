import Foundation

// Runnable check for the gimbal logic that has no UI and no camera in it: the
// joystick's displacement → direction + speed mapping, its deadzone and its
// portrait lockout, and the drive limiter's duplicate suppression. Not part of
// the app target — compile and run it with the bare toolchain:
//
//   swiftc -swift-version 6 -parse-as-library \
//     Sources/Betterlink/Transport/UVCTypes.swift \
//     Sources/Betterlink/Controls/GimbalJoystick.swift \
//     Checks/GimbalMappingCheck.swift \
//     -o /tmp/gimbal-mapping-check && /tmp/gimbal-mapping-check
//
// No hardware needed: everything under test is a pure function of a
// displacement, a ceiling and a clock reading.

@main
struct GimbalMappingCheck {
    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            if condition {
                print("ok   \(label)")
            } else {
                failures += 1
                print("FAIL \(label)")
            }
        }

        // Pan 0.5 of 30 and tilt 0.5 of 20 are the shipped defaults, and the
        // pair the control bar shows as "Pan 15 · Tilt 10".
        let caps = GimbalSpeedCaps(pan: 0.5, tilt: 0.5, maxPanSpeed: 30, maxTiltSpeed: 20)
        let radius: CGFloat = 35
        func drive(_ x: CGFloat, _ y: CGFloat, allowsTilt: Bool = true) -> GimbalDrive {
            GimbalJoystick.drive(offset: CGSize(width: x, height: y), radius: radius,
                                 caps: caps, allowsTilt: allowsTilt)
        }

        // 1. The hardware senses (§9), pinned here because every joystick
        //    direction is derived from them. Pan 0x01 is right; tilt runs the
        //    opposite way round, 0x01 driving the head down.
        expect(GimbalPadDirection.right.pan == .positive && GimbalPadDirection.left.pan == .negative,
               "pan 0x01 is right")
        expect(GimbalPadDirection.up.tilt == .negative && GimbalPadDirection.down.tilt == .positive,
               "tilt 0x01 is down — the opposite sense to pan")

        expect(caps.panCeiling == 15 && caps.tiltCeiling == 10, "the default ceilings are pan 15, tilt 10")
        expect(GimbalDrive.stopped == GimbalDrive(pan: .stop, panSpeed: 1, tilt: .stop, tiltSpeed: 1),
               "the stop payload is [0, 1, 0, 1], never all zeros")

        // 2. Screen vector → direction. Right is right, and up is up even
        //    though up sends the lower direction byte.
        expect(drive(radius, 0) == GimbalDrive(pan: .positive, panSpeed: 15, tilt: .stop, tiltSpeed: 1),
               "puck right pans right at the ceiling")
        expect(drive(-radius, 0) == GimbalDrive(pan: .negative, panSpeed: 15, tilt: .stop, tiltSpeed: 1),
               "puck left pans left")
        expect(drive(0, -radius) == GimbalDrive(pan: .stop, panSpeed: 1, tilt: .negative, tiltSpeed: 10),
               "puck up tilts up at the ceiling")
        expect(drive(0, radius) == GimbalDrive(pan: .stop, panSpeed: 1, tilt: .positive, tiltSpeed: 10),
               "puck down tilts down")

        // 3. The ceiling is a ceiling: half out is half of it, and a puck
        //    dragged past the rim is still only the ceiling.
        expect(drive(radius / 2, 0).panSpeed == 8, "half deflection is half the ceiling")
        expect(drive(radius * 4, 0) == drive(radius, 0), "dragging past the rim clamps to the ceiling")
        expect(drive(0, -radius * 4).tiltSpeed == 10, "so does dragging past it vertically")

        // 4. Deadzone: a jitter near the center must not creep the head, and
        //    the first step past it must actually move.
        expect(drive(radius * 0.1, 0) == .stopped, "inside the deadzone nothing moves")
        expect(drive(radius * 0.1, radius * 0.1) == .stopped, "the deadzone is radial, not per-axis")
        expect(drive(radius * 0.2, 0) == GimbalDrive(pan: .positive, panSpeed: 3, tilt: .stop, tiltSpeed: 1),
               "just past the deadzone drives slowly")

        // 5. An axis that rounds to nothing stops rather than crawling: a
        //    nonzero direction at speed 1 would creep the head sideways for as
        //    long as the puck is held (§7).
        expect(drive(radius * 0.02, -radius * 0.9).pan == .stop,
               "a near-vertical push does not creep in pan")

        // 6. Portrait lockout (§9): tilt is dropped by the camera, so the
        //    puck never leaves the horizontal axis and never asks for it.
        let locked = drive(radius * 0.7, -radius * 0.7, allowsTilt: false)
        expect(locked.tilt == .stop && locked.pan == .positive,
               "portrait keeps pan and drops tilt")
        expect(GimbalJoystick.puckOffset(for: CGSize(width: 10, height: -30),
                                         radius: radius, allowsTilt: false).height == 0,
               "portrait pins the puck to the horizontal axis")
        expect(GimbalJoystick.puckOffset(for: CGSize(width: 100, height: 0),
                                         radius: radius, allowsTilt: true).width == radius,
               "the puck stays inside the well")

        // 7. The limiter. A drag is a mouse-move per frame; only ~10 Hz of
        //    them may reach the transport, and a payload the camera already
        //    holds may not reach it at all.
        var limiter = GimbalDriveLimiter()
        let start = ContinuousClock.now
        let right = drive(radius, 0)
        let slower = drive(radius / 2, 0)
        expect(limiter.decision(for: right, at: start) == .send, "the first update goes out immediately")
        limiter.markSent(right, at: start)
        expect(limiter.decision(for: right, at: start.advanced(by: .milliseconds(1))) == .skip,
               "the same payload is not sent twice")
        expect(limiter.decision(for: right, at: start.advanced(by: .seconds(5))) == .skip,
               "and is still not sent twice much later — the camera is latched")
        expect(limiter.decision(for: slower, at: start.advanced(by: .milliseconds(40)))
                   == .wait(.milliseconds(60)),
               "a different payload too soon waits out the rest of the interval")
        expect(limiter.decision(for: slower, at: start.advanced(by: .milliseconds(100))) == .send,
               "and goes out once the interval is up")
        limiter.reset()
        expect(limiter.decision(for: right, at: start.advanced(by: .milliseconds(101))) == .send,
               "after a stop, an identical drive is sent again rather than skipped")

        // 8. Drive ownership. Two things reach for one head and the drive
        //    command is latched, so the danger is not two drives racing but a
        //    stop arriving from whoever is no longer driving. The safety
        //    property: a stop from X never ends a drive owned by Y.
        var ownership = GimbalDriveOwnership()
        expect(GimbalDriveOwner.allCases.allSatisfy { ownership.allowsStop(from: $0) },
               "an unowned stop is let through — there is no move for it to end")

        expect(ownership.claim(.api), "a head nobody is holding can be claimed by the API")
        expect(ownership.owner == .api, "driving claims the head")
        expect(!ownership.allowsStop(from: .dashboard),
               "a Dashboard release does not stop an API drive")
        expect(ownership.allowsStop(from: .api), "an owner may stop its own drive")

        // The bug this exists for: the user grabs the control inside the API's
        // dead-man window, and the dead-man then expires.
        expect(ownership.claim(.dashboard), "a hand on the control takes the head from a script")
        expect(!ownership.allowsStop(from: .api),
               "the API's dead-man is refused once the Dashboard has taken over")
        expect(ownership.release(from: .dashboard), "an owner's own release stops the head")
        expect(ownership.owner == nil, "stopping lets go of the head")
        expect(GimbalDriveOwner.allCases.allSatisfy { ownership.allowsStop(from: $0) },
               "so the next stop from anyone is harmless rather than refused")

        // 9. The priority rule: while a person has a control physically down,
        //    a script waits. Last-writer-wins alone would let the API take the
        //    head mid-press, and the user's release would then be refused —
        //    leaving a motorized head moving after the hand came off it.
        var held = GimbalDriveOwnership()
        held.beginDashboardHold()
        expect(held.isDashboardControlHeld, "grabbing a control marks the head as held")
        expect(!held.claim(.api), "an API drive is refused while a control is held")
        expect(held.owner == nil, "and a refused claim takes nothing")
        expect(held.claim(.dashboard), "the hold does not lock the Dashboard out of its own head")
        expect(held.claim(.dashboard), "and the pad and joystick do not lock each other out")

        expect(held.release(from: .dashboard),
               "the release still stops the head after a refused API drive")
        expect(!held.isDashboardControlHeld, "and lets go of the hold")
        expect(held.claim(.api), "so the same API drive succeeds once the control is released")

        // 10. The lock-out failure, which is quieter and worse than the bug
        //     ownership set out to fix: a hold that survives its release locks
        //     the API out of the gimbal until the view is rebuilt. The hold
        //     must therefore clear on the disappear path too — the one where
        //     the stop itself is refused, because the well vanished while the
        //     API still owned the head.
        var vanished = GimbalDriveOwnership()
        expect(vanished.claim(.api), "the API is driving")
        vanished.beginDashboardHold()   // the puck is grabbed but not yet moved
        expect(!vanished.release(from: .dashboard),
               "a release from a Dashboard that never took the head leaves the API's drive alone")
        expect(!vanished.isDashboardControlHeld,
               "but it still lets go of the hold — a refused stop must not strand it")
        expect(vanished.claim(.api), "so the API is not locked out")

        // A camera that stops answering disables the control bar, which can
        // interrupt a gesture without ever delivering its release.
        var lost = GimbalDriveOwnership()
        lost.beginDashboardHold()
        expect(lost.claim(.dashboard), "a control is held and driving")
        lost.abandon()
        expect(!lost.isDashboardControlHeld && lost.owner == nil,
               "losing the camera lets go of both the head and the hold")
        expect(lost.claim(.api), "so a camera dropping mid-press cannot lock the API out")

        // 11. The contract endGimbalDrive(owner:) hands the API, pinned here
        //     because that branch is about to depend on it: true means the
        //     stop reached the camera, false means somebody else holds the
        //     head — a refusal, not a failure. A stop that reported
        //     unconditional success would leave a client rendering "stopped"
        //     beside a camera that is still moving.
        var contract = GimbalDriveOwnership()
        expect(contract.claim(.dashboard), "the Dashboard is driving")
        expect(!contract.release(from: .api),
               "a stop from a non-owner answers false — somebody else holds the head")
        expect(contract.owner == .dashboard, "and leaves that owner's drive running")
        expect(contract.release(from: .dashboard), "an effective stop answers true")

        // 12. Centering is a movement too, so the priority rule has to cover
        //     that door as well — a script swinging the head home under a held
        //     pad is the same failure by a different route.
        var centering = GimbalDriveOwnership()
        expect(centering.claim(.api), "the API is driving")
        expect(centering.recenter(by: .dashboard), "the Dashboard may center")
        expect(centering.owner == nil, "an accepted center takes the head and gives it straight back")
        expect(centering.recenter(by: .api), "and the API may center a head nobody is holding")

        var busy = GimbalDriveOwnership()
        busy.beginDashboardHold()
        expect(busy.claim(.dashboard), "a person has a control down and is driving")
        expect(!busy.recenter(by: .api), "an API center is refused while a control is held")
        // The one most likely to pass for the wrong reason, so it is asserted
        // three ways: a refused center must be a *total* no-op. Letting go of
        // the head or the hold on its way out would refuse the center and then
        // hand the API the very thing it was refused a moment later.
        expect(busy.owner == .dashboard, "and leaves the holder's ownership untouched")
        expect(busy.isDashboardControlHeld, "and the hold untouched")
        expect(!busy.claim(.api), "so the API is still refused for a drive afterwards")
        expect(!busy.recenter(by: .api), "and still refused for another center")
        expect(busy.release(from: .dashboard), "the holder's own release still stops the head")
        expect(busy.recenter(by: .api), "and once released the API's center goes ahead")

        // A Dashboard center during its own hold must not open the door
        // either: the hand has not come off the control because it centered.
        var centeredWhileHeld = GimbalDriveOwnership()
        centeredWhileHeld.beginDashboardHold()
        expect(centeredWhileHeld.recenter(by: .dashboard), "the Dashboard may center while it holds")
        expect(centeredWhileHeld.isDashboardControlHeld,
               "and centering does not let go of the hold")
        expect(!centeredWhileHeld.claim(.api), "so the API stays refused through a center")

        if failures > 0 {
            print("\(failures) check(s) FAILED")
            exit(1)
        }
        print("All gimbal mapping checks passed.")
    }
}
