# Implementation Roadmap

Derived from `specifications.md` and `investigation-findings.md`. Section references (§) point to
`investigation-findings.md`.

## Scope decisions (confirmed 2026-08-21)

- View modes (Whiteboard / Overhead / DeskView): **out of scope**.
- Single camera, single model (this Link, VID `0x2E1A` / PID `0x4C01`): no multi-camera handling,
  no per-model capability gating.
- Presets: **one unified system** — a preset is a single snapshot of PTZ position + zoom +
  image/color params, restored together. (Diverges deliberately from the first-party app's three
  separate systems, §3.4.)

## Phase 0 — Scaffold (serial; blocks everything)

- Xcode project, SwiftUI app shell.
- Sidebar navigation: OVERVIEW → Dashboard; PRESETS → Preset Menu, Preset Builder; Settings.
- Empty pane placeholders, CHANGELOG.md.

## Phase 1 — Foundations (three parallel tracks, separate worktrees)

| Track | Work | Depends on |
|---|---|---|
| A: UVC transport | IOKit device-level EP0 user client (ported from `insta360link-joystick-controller`), actor-serialized transfers, standard UVC + XU get/set, device discovery by VID/PID | Phase 0 |
| B: Viewfinder | AVFoundation capture session, live preview as the UI centerpiece | Phase 0 |
| C: CI/CD + updates | GitHub Actions build/sign/notarize, Sparkle appcast (patterns from Pacer) | Nothing |

Tracks A and B are independent: transport uses EP0 control transfers, the viewfinder uses the
AVFoundation stream; they coexist (§2).

## Phase 2 — Features (parallel after A + B merge)

| Feature | Needs | Risk |
|---|---|---|
| PTZ + speed control | A | Low — selectors verified (XU 0x16, 0x1A, CT 0x0B/0x0D) |
| Image controls (brightness/contrast/saturation/sharpness/hue/WB/focus/anti-flicker) | A | Low — standard UVC, ranges verified (§4) |
| Recording start/stop | B | Low — host-side `AVAssetWriter`, no camera command (§3.3) |
| Resolution / fps | A | Medium — XU sel 0x1C write side unverified (§9) |
| Orientation (flip / portrait / roll) | A | High — selector names known (§2.1), numbers/encodings unknown; needs live probe or USB capture of the official app |
| Presets (Menu + Builder UI, unified snapshot/restore, local store) | A + PTZ | Low-medium — absolute pan/tilt readable; direction sign unverified |

The camera is one shared physical resource: hardware probe/verification tasks serialize even when
code tracks run in parallel. Do orientation + resolution probing as one dedicated hardware session.

## Phase 3 — Ship

- Settings pane (device settings, hotkeys, appearance).
- Hardware verification pass (§9 checklist) — serial, needs the Link attached.
- First tagged release through the Track C pipeline.

## Known hardware-verification debts (§9)

### Findings from the 2026-08-21 live hardware session (unit `IBJLA24053R34Y`, firmware v1.4.5.8_build1)

- **Tilt is refused while the camera streams a portrait format.** Not a payload bug: with a
  1080 × 1920 stream the camera accepts every tilt command (relative XU `0x16` and absolute
  `CT_PANTILT_ABSOLUTE` alike), echoes the new value back in `GET_CUR`, and never moves the
  head. Under a 1920 × 1080 stream both paths work. AVFoundation negotiated the portrait
  format by default on this unit, which is why tilt looked dead; the viewfinder now selects
  the landscape format on the device.
- **A roll write aborts an in-flight gimbal move** and returns the head to where the move
  started. Preset restore wrote roll right after the position, which is why it reported
  success and changed nothing. Only roll does this — zoom, focus-auto, WB-auto and
  anti-flicker writes issued in the same burst leave the move alone.
- **Direction senses.** Pan: `0x01` = right, and the absolute value rises to the right;
  `GimbalPadDirection` was already correct. Tilt is the opposite sense — `0x01` drives the
  head *down* (absolute value falls); the pad mapping is now flipped to match.
- **XU 9 selector `0x1A` is absolute pan/tilt, not "center".** Its `GET_CUR` mirrors
  `CT_PANTILT_ABSOLUTE` as two int32 LE in the order `{tilt, pan}`; writing eight zero bytes
  is simply "move to (0, 0)", which is why it worked as a center command.
- **XU `0x1C` (video mode) is read-only in practice.** With no stream it reads all zeros and
  writes do not stick; with a stream it reports the format the *host* negotiated. Resolution
  and frame rate are therefore an AVFoundation `activeFormat` choice, not a camera setting —
  session presets are no help, since every preset still resolves to the portrait format on
  this unit.
- Verified working: relative pan and tilt, gimbal center, absolute position write (as long as
  no roll write follows it), zoom, all PU image controls, WB/focus auto toggles, preset
  capture and full preset restore including position, host-side recording.
- **Stream formats.** 720p60, 1080p60 and 3840x2160@30 all stream and leave the gimbal fully
  controllable, so 4K is usable despite the USB 2.0 link. An `activeFormat` assignment only
  sticks if it is repeated once the session is running; without that the camera falls back to
  its portrait default, which is why the apply path re-asserts the format and guards against
  a portrait result.

### Open debts


- Exposure comp/ISO/shutter/AE, HDR, mirror H/V, roll selector numbers + payload encodings.
- Settle times for absolute moves are still unmeasured (restore fires and returns; nothing waits
  for the head to arrive). Direction signs are now verified for both axes (above).
- Sparkle throws "Unable to Check For Updates" on every launch even with
  `SUEnableAutomaticChecks = false`, because `SUFeedURL`/`SUPublicEDKey` are still placeholders
  (docs/RELEASING.md). Harmless but user-visible; disappears once the feed and key are real.

## Opportunities for future work

Not scheduled; captured so they aren't lost.

- **Preset path builder** — choreographed camera moves built from keyframes. Each keyframe is a
  preset-style snapshot plus a dwell time (how long the camera holds there); between keyframes the
  user picks the transition: shortest-distance route over a configurable time interval, or a
  custom recorded path. UI: an iMovie-style timeline docked at the bottom of the window, with the
  viewfinder remaining top and center.
