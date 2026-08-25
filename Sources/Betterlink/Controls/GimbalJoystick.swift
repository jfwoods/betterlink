import CoreGraphics

// The pure half of gimbal driving: displacement in, XU 0x16 payload out, the
// rate limiter that decides whether a payload is worth a USB transfer, and the
// ownership rule that decides whose stop is allowed to end a move.
// Deliberately free of SwiftUI, the model and the transport so
// Checks/GimbalMappingCheck.swift can compile it against UVCTypes.swift alone.

/// The four gimbal pad directions, mapped onto the XU relative pan/tilt axes.
///
/// Both direction signs ARE hardware-verified (§9, 2026-08-21): pan 0x01
/// drives right and the absolute reading rises to the right; tilt runs the
/// opposite sense, and the mapping below was flipped to match. Every
/// direction in the app derives from this enum, so if up/down or left/right
/// ever move the wrong way, flip it here — nowhere else. Do not "correct"
/// tilt to match pan: they genuinely disagree on the wire.
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

/// One latched relative pan/tilt command: the two direction bytes and the two
/// speed bytes that XU 0x16 carries together. The camera keeps moving at this
/// until the next one arrives, so it describes the head's whole state, which
/// is why `GimbalDriveLimiter` can skip a resend by comparing two of these.
struct GimbalDrive: Equatable, Sendable {
    var pan: GimbalDirection
    var panSpeed: UInt8
    var tilt: GimbalDirection
    var tiltSpeed: UInt8

    /// What `UVCTransport.stopGimbal()` puts on the wire: stopped on both
    /// axes at speed 1, never all zeros (§7).
    static let stopped = GimbalDrive(pan: .stop, panSpeed: 1, tilt: .stop, tiltSpeed: 1)

    /// The pad's drive. The pad has no analog range, so it runs both axes at
    /// their ceiling and lets the direction bytes decide which one moves.
    init(pad direction: GimbalPadDirection, caps: GimbalSpeedCaps) {
        self.init(pan: direction.pan, panSpeed: caps.panCeiling,
                  tilt: direction.tilt, tiltSpeed: caps.tiltCeiling)
    }

    init(pan: GimbalDirection, panSpeed: UInt8, tilt: GimbalDirection, tiltSpeed: UInt8) {
        self.pan = pan
        self.panSpeed = panSpeed
        self.tilt = tilt
        self.tiltSpeed = tiltSpeed
    }
}

/// The per-axis speed ceilings the two sliders set: a fraction of each axis's
/// hardware maximum. A ceiling, not a speed — a full joystick deflection
/// reaches it and anything less is a proportion of it.
///
/// The maxima are passed in rather than read from `UVCTransport` so this file
/// carries no transport dependency; `CameraControlsModel` supplies the
/// verified caps (pan 30, tilt 20, §4).
struct GimbalSpeedCaps: Equatable, Sendable {
    /// 0.05...1.0 of `maxPanSpeed`.
    var pan: Double
    /// 0.05...1.0 of `maxTiltSpeed`.
    var tilt: Double
    var maxPanSpeed: UInt8
    var maxTiltSpeed: UInt8

    /// The speed byte a full deflection reaches — and the byte the bar shows,
    /// because this is what actually goes to the camera.
    var panCeiling: UInt8 { Self.speedByte(pan, of: maxPanSpeed) }
    var tiltCeiling: UInt8 { Self.speedByte(tilt, of: maxTiltSpeed) }

    /// Never zero: a nonzero direction with speed 0 makes the head creep (§7),
    /// so an axis that is meant to move gets at least 1.
    static func speedByte(_ fraction: Double, of maximum: UInt8) -> UInt8 {
        let scaled = Int((fraction * Double(maximum)).rounded())
        return UInt8(min(max(scaled, 1), Int(maximum)))
    }
}

/// Maps a joystick puck's displacement onto a drive command.
enum GimbalJoystick {
    /// Fraction of the well's travel that does nothing. Without it the puck
    /// resting a pixel off center — or a click that lands just beside it —
    /// would creep the head, and the head only stops when told to.
    static let deadzone = 0.15

    /// Where the puck actually sits for a raw displacement from the center of
    /// the well: clamped to `radius`, and to the horizontal axis while tilt is
    /// locked out. The view draws this and `drive(offset:…)` commands from the
    /// same raw displacement, so what is on screen is what is on the wire.
    static func puckOffset(for offset: CGSize, radius: CGFloat, allowsTilt: Bool) -> CGSize {
        // Tilt is silently ignored while the camera streams portrait (§9) —
        // the camera even echoes the new value back in GET_CUR — so the puck
        // is held on the horizontal axis rather than letting the user aim at a
        // command that will be dropped.
        let raw = CGSize(width: offset.width, height: allowsTilt ? offset.height : 0)
        let distance = (raw.width * raw.width + raw.height * raw.height).squareRoot()
        guard distance > radius, distance > 0 else { return raw }
        let scale = radius / distance
        return CGSize(width: raw.width * scale, height: raw.height * scale)
    }

    /// Direction and speed together: which way the puck points, and how far
    /// out it is as a proportion of each axis's ceiling. `offset` is in the
    /// view's coordinate space, where y grows downward.
    static func drive(offset: CGSize, radius: CGFloat,
                      caps: GimbalSpeedCaps, allowsTilt: Bool) -> GimbalDrive {
        guard radius > 0 else { return .stopped }
        let travel = puckOffset(for: offset, radius: radius, allowsTilt: allowsTilt)
        let x = Double(travel.width / radius)
        let y = Double(travel.height / radius)
        // Radial, not per-axis: the well is a circle, so what matters is how
        // far from center the puck is, whatever direction it went.
        guard (x * x + y * y).squareRoot() > deadzone else { return .stopped }
        // The puck is already clamped inside the well, so neither component
        // exceeds 1 and each axis simply asks for its share of its ceiling.
        // The direction bytes come from GimbalPadDirection rather than from
        // the raw enum, so the hardware-verified senses (§9) — including
        // tilt's, which runs opposite pan's — are stated in exactly one place.
        let (pan, panSpeed) = axis(x, ceiling: caps.panCeiling,
                                   rising: GimbalPadDirection.right.pan,
                                   falling: GimbalPadDirection.left.pan)
        // Screen space grows downward: a negative height is the puck pushed up.
        let (tilt, tiltSpeed) = axis(-y, ceiling: caps.tiltCeiling,
                                     rising: GimbalPadDirection.up.tilt,
                                     falling: GimbalPadDirection.down.tilt)
        return GimbalDrive(pan: pan, panSpeed: panSpeed, tilt: tilt, tiltSpeed: tiltSpeed)
    }

    /// One axis: `rising` is the direction byte for a positive fraction.
    private static func axis(_ fraction: Double, ceiling: UInt8,
                             rising: GimbalDirection,
                             falling: GimbalDirection) -> (GimbalDirection, UInt8) {
        let speed = Int((abs(fraction) * Double(ceiling)).rounded())
        // Rounding to zero means this axis is not really being asked for —
        // a near-vertical push has a little pan in it. Rounding that up to 1
        // the way a ceiling does would creep the head sideways forever, so
        // the axis stops instead.
        guard speed > 0 else { return (.stop, 1) }
        return (fraction > 0 ? rising : falling, UInt8(min(speed, Int(ceiling))))
    }
}

/// Rate limiter for the latched drive command. A drag emits a mouse-move per
/// frame and every one of those would otherwise be a USB control transfer on
/// the actor-serialized transport, so updates go out at ~10 Hz — and a payload
/// the camera already holds does not go out at all, which is most of a drag
/// that stays inside one speed bucket.
///
/// The stop deliberately does not come through here (see
/// `CameraControlsModel.endGimbalDrive(owner:)`): it must never wait for the
/// interval and must never be suppressed as a duplicate. Whether it is allowed
/// to go out at all is a separate question, answered by `GimbalDriveOwnership`
/// below.
struct GimbalDriveLimiter {
    /// ~10 Hz: fast enough that the head answers a drag immediately, slow
    /// enough that a drag cannot outrun the transport.
    static let interval = Duration.milliseconds(100)

    enum Decision: Equatable {
        /// Put it on the wire now.
        case send
        /// The camera is already driving exactly this; no transfer.
        case skip
        /// Too soon after the last send — retry after this long. The caller
        /// must arm a timer rather than drop the update: the user can stop
        /// moving the mouse at any moment, and whatever was last sent is what
        /// the head keeps doing.
        case wait(Duration)
    }

    private var lastSent: GimbalDrive?
    private var lastSentAt: ContinuousClock.Instant?

    func decision(for drive: GimbalDrive, at now: ContinuousClock.Instant) -> Decision {
        if drive == lastSent { return .skip }
        guard let sentAt = lastSentAt else { return .send }
        let elapsed = sentAt.duration(to: now)
        guard elapsed < Self.interval else { return .send }
        return .wait(Self.interval - elapsed)
    }

    mutating func markSent(_ drive: GimbalDrive, at now: ContinuousClock.Instant) {
        lastSent = drive
        lastSentAt = now
    }

    /// Forgets what the camera holds. Called when a drive ends: the stop that
    /// follows clears the head, so an identical next press has to be sent
    /// again rather than being skipped as a duplicate.
    mutating func reset() {
        lastSent = nil
        lastSentAt = nil
    }
}

/// Who is driving the gimbal.
///
/// The head is one physical thing with more than one hand reaching for it: the
/// Dashboard's controls, and clients of the local REST API. Because the drive
/// command is latched — the head keeps moving until something says otherwise —
/// the dangerous case is not two drives racing but a *stop* arriving from
/// whoever is no longer driving.
enum GimbalDriveOwner: String, Sendable, CaseIterable {
    case dashboard
    case api
}

/// Which owner holds the head, who is allowed to take it, and whose stop is
/// allowed to end a move.
///
/// Two rules, and they answer different questions.
///
/// **A stop from an owner that no longer holds the head goes nowhere.** The
/// bug that motivates it: an API client sends a drive and crashes without
/// stopping; the user grabs a Dashboard control inside the API's dead-man
/// window; the dead-man expires and stops the head under the user's hand —
/// and since the pad and joystick only command on press, it stays stopped
/// until the user lets go and presses again.
///
/// **A drive is refused while a Dashboard control is physically down.**
/// Claiming is otherwise last-writer-wins, which is what makes an abandoned
/// API drive safe to leave lying around: its dead-man is refused when it
/// fires and needs no chasing down. But last-writer-wins alone would let the
/// API take the head mid-press, and the user's release would then be refused
/// — leaving a motorized head moving after the hand came off the control.
/// That trade runs the wrong way for a device with a motor in it: the bug
/// above is annoying but safe, because the head *stops*. So the narrow
/// exception: while somebody is holding a control, a script waits.
///
/// The exception really is narrow, but it has to cover *every* door that
/// moves the head — starting a drive and centering alike, since a script
/// swinging the head home under a held pad is the same failure arriving by a
/// different route. It covers nothing else: the API may still stop its own
/// drive, may still take a head nobody is holding, and Dashboard controls do
/// not lock each other out, the pad and the joystick being the same owner.
struct GimbalDriveOwnership {
    private(set) var owner: GimbalDriveOwner?

    /// True while a Dashboard control is physically down. Set when one is
    /// grabbed, and let go of on exactly the paths the views' own stop
    /// guarantee already covers — `onEnded` and `onDisappear` — plus the
    /// backstop in `abandon()`. A hold left set would lock the API out of the
    /// gimbal until the view was rebuilt, which is a worse bug than the one
    /// this prevents, and a much quieter one.
    private(set) var isDashboardControlHeld = false

    /// A Dashboard control went down. Deliberately separate from `claim`:
    /// grabbing the joystick puck must protect the user's grip immediately,
    /// but it must not take the head, because taking it without moving it
    /// would refuse the previous owner's dead-man while its drive was still
    /// running.
    mutating func beginDashboardHold() {
        isDashboardControlHeld = true
    }

    /// Whether `owner` may take the head from whoever has it — the priority
    /// rule itself, in one place because two doors consult it.
    ///
    /// The Dashboard is never refused, and the leading clause is what makes
    /// that *structural*. It would otherwise rest on a pointer only being in
    /// one place at a time, which is true of a mouse and not of a rule.
    func allowsOverride(by owner: GimbalDriveOwner) -> Bool {
        owner == .dashboard || !isDashboardControlHeld
    }

    /// Takes the head, unless a person has a control down and this is not
    /// them. Returns whether the claim happened; a refused claim changes
    /// nothing at all.
    mutating func claim(_ owner: GimbalDriveOwner) -> Bool {
        guard allowsOverride(by: owner) else { return false }
        self.owner = owner
        return true
    }

    /// A center has been asked for by `owner`: returns whether it may go
    /// ahead, and lets go of the head when it does.
    ///
    /// Centering takes the head and immediately gives it back, because it
    /// overrides whatever is running and ends in its own stop (§7) — so it
    /// leaves the head held by nobody, and the loser's later stop is
    /// harmlessly let through rather than refused.
    ///
    /// It does not let go of the *hold*: a hand on a control has not come off
    /// it because something centered, and dropping the hold here would refuse
    /// the API its center and then hand it the head a moment later.
    mutating func recenter(by owner: GimbalDriveOwner) -> Bool {
        guard allowsOverride(by: owner) else { return false }
        clear()
        return true
    }

    /// Whether a stop from `owner` should reach the camera.
    ///
    /// Refused in exactly one case — somebody else holds the head — and that
    /// is the whole safety property. An *unowned* stop is allowed through on
    /// purpose: it is the belt-and-braces path (a view leaving the hierarchy
    /// mid-drag, a camera coming back after a reconnect) and it cannot end
    /// anybody's move, because there is no move to end.
    func allowsStop(from owner: GimbalDriveOwner) -> Bool {
        self.owner == nil || self.owner == owner
    }

    /// A drive has ended. Returns whether the stop should reach the camera.
    ///
    /// One step, because the *order* is the safety property: the control is
    /// let go of first, and only then does the stop have to justify itself.
    /// A release that is refused — the view vanished while the API owned the
    /// head — must still let go of the hold, or a person who is no longer
    /// touching anything would keep the API locked out.
    mutating func release(from owner: GimbalDriveOwner) -> Bool {
        if owner == .dashboard { isDashboardControlHeld = false }
        guard allowsStop(from: owner) else { return false }
        clear()
        return true
    }

    /// Lets go of the head without ending a hold.
    mutating func clear() {
        owner = nil
    }

    /// The camera stopped answering. Nobody owns a head that is not there,
    /// and — the part that matters — a control bar that has just been
    /// disabled can have its gesture interrupted without ever delivering the
    /// release that would let go of the hold. Letting go of both here is what
    /// keeps a camera dropping mid-press from locking the API out.
    mutating func abandon() {
        clear()
        isDashboardControlHeld = false
    }
}

/// What became of a drive request. The Dashboard never reads it — its claim
/// cannot be refused — but the API answers its client with it, and a client
/// deserves better than a success that did nothing.
///
/// The two refusals are genuinely different and the API will want to say so:
/// a held control is a person using the camera right now, which resolves on
/// its own in a moment, while a camera that is not ready is a device problem
/// that will not.
enum GimbalDriveResult: Sendable, Equatable {
    case accepted
    /// Somebody has a Dashboard control physically down. Try again shortly.
    case refusedControlHeld
    /// No Link attached, or its controls have not been read yet.
    case refusedCameraNotReady
}
