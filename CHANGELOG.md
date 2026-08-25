# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] — 2026-08-25

### Added
- Virtual joystick for the gimbal, now the default control. A puck in a circular
  well sets direction and speed in one gesture — shove it to swing across the room,
  ease it out to creep the last few degrees — where the pad could only say "that
  way, at the one speed on the slider". Releasing snaps the puck home and stops the
  head; so does switching control style or leaving the Dashboard mid-drag, because a
  gimbal left driving is the worst thing this control can do. A deadzone near the
  center keeps a stray click from creeping the head, and an axis that rounds to
  nothing stops rather than crawling, so a near-vertical push does not drift sideways.
- Segmented control in the bar switches between Joystick and D-Pad. The pad is
  unchanged and stays, because a single precise nudge is easier to aim with a button.
- Gimbal section in Settings, exposing the control style and both speed ceilings. It
  binds the same preference keys as the control bar, so the two surfaces are one
  value, live in both directions.
- Favorite presets. Presets starred in the Preset Menu appear as a row of named
  buttons on the Dashboard, directly under the viewfinder, so the handful used
  constantly while framing a shot no longer cost a trip to the sidebar. The row sits
  above the gimbal/speed/zoom strip rather than over the picture — overlaying the
  viewfinder would cover the shot at exactly the moment the user is looking at it to
  choose. It hides itself when nothing is starred, and scrolls horizontally so a long
  list neither squeezes its buttons nor clips the last one.
- `Checks/GimbalMappingCheck.swift` — displacement to direction and speed byte, the
  deadzone, the portrait tilt lockout, the drive limiter's duplicate suppression, and
  the drive-ownership state machine. No app target, no Link attached.

### Changed
- The gimbal speed slider is now two sliders, Pan and Tilt, chained together by
  default — which reproduces exactly what the single slider did, since it was already
  scaled into each axis's own hardware cap (pan 0–30, tilt 0–20). The value is a
  ceiling rather than a fixed speed: full deflection reaches it, half reaches half of
  it, and the D-pad, having no analog range, always drives at it.
- Gimbal drive commands are rate-limited to ~10 Hz, and a payload the camera already
  holds is not sent at all. The command is latched, so an update arriving too soon is
  held and flushed rather than dropped. The stop is exempt: never delayed, never
  coalesced, and it discards any drive still waiting.
- The joystick respects the portrait tilt lockout: while the camera streams a 9:16
  format the puck is held on the horizontal axis, rather than letting you aim at a
  tilt the camera silently drops.
- Presets carry an `isFavorite` flag in `presets.json`. Decoding is hand-written
  rather than synthesized: Swift's synthesized `Decodable` throws `keyNotFound` for a
  missing key even when the property has a default value, and because
  `PresetStore.load()` moves an undecodable file aside to `.unreadable`, the
  synthesized version would have emptied the preset list of every existing user on
  the first launch after upgrading rather than defaulting one field.
- The Preset Menu's "On connect" indicator is drawn as a bolt rather than a star,
  since the star now marks favorites and one glyph cannot mean both in the same row.

### Fixed
- A gimbal stop from one controller could end another's move, and a drive could keep
  running after the user let go. The command is latched and the model had no notion of
  who was driving, so an API client's dead-man timeout could stop the head under the
  user's hand — and, with the opposite priority, a client taking over could leave a
  motorized head turning after their hand came off the control. A drive now has an
  owner; a stop from an owner that no longer holds the head goes nowhere; and while a
  Dashboard control is physically held, an API drive is refused rather than
  superseded, so releasing always stops the head. The rule covers every command that
  moves the head, centering included.

### Verified on hardware
- The joystick was driven by hand against the Link on 2026-08-25: feel and speed
  tracking, releasing mid-drag, switching control style mid-drag, easing the puck just
  past the deadzone, and applying a favorite from the viewfinder row. The 10 Hz update
  rate was not found laggy and the deadzone's first speed step was not found too fast
  to frame with, so neither the interval nor the ramp is being changed.
- The speed arithmetic is backed by measurement rather than assumption. A limit-to-
  limit sweep timed twice in each direction gives pan 65°/s at speed byte 30 and
  33.5°/s at byte 15, tilt 41°/s at byte 20 and 21.7°/s at byte 10 — linear in the
  speed byte to within about 5%, which is exactly what "half deflection is half speed"
  requires. No correction curve is needed in `GimbalSpeedCaps.speedByte`.
- Camera permission survives a rebuild, confirmed by behaviour and not just by
  mechanism: two builds with different code-directory hashes under the same team both
  streamed with no second prompt.

### Not yet verified
- The portrait tilt lockout, which needs the camera streaming portrait, and a drive
  refused against a genuinely held on-screen control, which needs a second commanding
  surface and therefore lands with the REST API rather than here.

### Known
- A relative drive is latched in the camera and outlives the process that sent it, so
  killing or crashing the app mid-drag leaves the head running until it reaches its
  endstop. Releasing the puck, leaving the Dashboard and switching control style all
  stop it; app termination does not, because nothing stops the gimbal on the way out.
  More reachable in this release than before it, the joystick being a held gesture and
  now the default control.

## [0.1.0] — 2026-08-25

First release.

### Changed
- Local builds sign with the Developer ID identity instead of ad hoc. macOS
  stores a code requirement alongside each camera and microphone grant, and an
  ad-hoc signature's requirement is nothing but the code hash — which changes on
  every build, so every rebuild presented itself to the system as a different app
  and re-prompted for camera access. A Developer ID requirement is team-based and
  byte-identical across rebuilds, so the grant keeps matching. Verified by
  comparing two consecutive builds: different `cdhash`, same designated
  requirement. CI and the release workflow both override `CODE_SIGN_IDENTITY` on
  the `xcodebuild` command line, so signed and notarized output is unaffected.
  The first local build on a machine raises a keychain authorization dialog;
  until it is answered `codesign` waits indefinitely and builds in other
  worktrees fail with a misleading `database is locked`.
- Open at Login reads the registration macOS actually holds through
  `SMAppService` rather than a preference stored alongside it, so turning it off
  in System Settings is reflected honestly instead of the toggle lying about it.
- The last-used sidebar pane is recorded and restored on launch. Reopening
  where you left off is the ordinary Mac behavior, so it ships on; the toggle
  in Settings exists for the opposite preference — always land on the camera.
  The pane is recorded on every navigation whether or not the preference is on,
  so turning it on later has something to restore rather than whatever pane
  happened to be showing the day it was switched off.
- The preset-name field no longer suggests an example name. The prompt read
  "e.g. Wide desk shot", which is the name of one of the maintainer's own
  presets — harmless in isolation, but it put personal setup naming into the
  shipped binary, and the field is self-explanatory from its label.
- The `Preset persistence check` CI step compiles `PresetTransfer.swift` too,
  since `PresetStore`'s import methods return a type declared there.
- Renamed the app to **Betterlink**. This covers the user-visible name
  (`CFBundleDisplayName`), the bundle identifier (`com.waverf.LinkController` →
  `me.jfwoods.Betterlink`), the XcodeGen target and scheme, `Sources/LinkController/` →
  `Sources/Betterlink/`, the entitlements file, the `@main` struct, the appcast feed
  title, and every path in the CI and release workflows. Because nothing has been
  released yet there is no update-continuity cost; after the first release the bundle
  identifier and the preset store path would both be expensive to move.
- Preset storage moved from `~/Library/Application Support/LinkController/presets.json`
  to `~/Library/Application Support/Betterlink/presets.json`, following the rename. No
  migration shim ships, since no build has ever been distributed — a local development
  copy can simply be moved into place.
- `SUFeedURL` now points at the real appcast
  (`https://jfwoods.github.io/betterlink/appcast.xml`) instead of the `OWNER`
  placeholder, and `SUPublicEDKey` carries the real Sparkle EdDSA public key. Both
  are permanent for the life of the app: installed copies keep the values they
  shipped with, so changing either one strands them.
- Automatic update checks are on (`SUEnableAutomaticChecks`). The release workflow
  publishes the appcast in the same run that publishes the DMG, so the feed exists
  by the time anyone can install a build that reads it — leaving this off would have
  required a second release just to turn it on.
- `.gitignore` now covers `*.p8`, `*.p12`, and `PRIVATETODOs.md` so signing material and
  private notes cannot be committed by accident.

### Added
- **Settings is a real pane** rather than a placeholder, in three sections.
  *General* carries Open at Login and Reopen the Last Pane on Launch. *Presets*
  exports the saved preset list to a file and imports one back, offering a merge
  or a replace. *Updates* surfaces automatic update checks, their frequency, a
  Check for Updates Now button, and the running version and build.
- Presets can be exported and imported. The file is a versioned wrapper —
  `format`, `version`, `exportedAt`, `presets` — rather than a bare array, so a
  later schema change has something to branch on and an import can tell a preset
  file from any other JSON. Presets inside are encoded through `Preset`'s own
  `Codable` conformance, so a field added later cannot quietly stop
  round-tripping. Import validates the entire file before the store is touched:
  format marker, exact version, duplicate identifiers, blank names, and every
  value against the camera's envelope. A rejected file is reported and changes
  nothing, in memory or on disk.
- Merging an imported file is additive: a preset already saved under the same
  identifier is skipped rather than overwritten, because overwriting would
  destroy a local edit and re-identifying it would breed near-duplicates. An
  imported "Apply on Connect" mark never displaces one the user set — but it is
  allowed to fill an empty slot, since nothing of theirs is overwritten and
  importing onto a fresh machine is the main reason the feature exists. The
  summary says when that happened, because it changes what the camera does on
  the next connect and nothing asked the user to approve it. Replacing is
  destructive, says so with the count it will delete, and honors the file's own
  default.
- `Checks/PresetTransferCheck.swift` covers the export/import round-trip, every
  rejection path, and the merge and replace semantics — including the empty-slot
  default rule. Runs in CI, needs no camera.
- A real README: what the app does, install and build instructions, the preset
  model and where it is stored, requirements, an honest "known limits" list, the
  repository layout, and badges for the latest release, the DMG download, CI,
  platform, and Swift version. Screenshots of the Dashboard, Preset Menu, and
  Preset Builder live in `docs/images/`. They are captured with a color-bar
  stand-in in the viewfinder rather than a real camera feed; the README says so
  under the hero image. The build section explains why local builds sign with a
  Developer ID rather than ad-hoc — TCC pins an ad-hoc requirement to the code
  hash, so every rebuild re-prompted for camera access — and warns about the
  one-time keychain authorization dialog that hangs `codesign` until answered.
  A Settings section covers the three panes, and the Presets section documents
  the export/import file format, what import validates before touching the
  store, and the merge rule for an imported "Apply on Connect" mark — it never
  displaces one you set, but it fills an empty slot. `docs/images/settings.png`
  is captured from a real build; the login-item toggle photographs in whatever
  state the machine is actually in, rather than being switched on for the shot.
- App icon. The mark is two arcs on the same profile as the reference ring (inner/outer
  diameter 0.75, arc width 12.5% of the outer diameter), blended where they meet and
  wrapped in one continuous outline whose straight segment reads as the stem of a B.
  Ships as `Sources/Betterlink/Assets.xcassets/AppIcon.appiconset` and is wired up
  through `CFBundleIconName` and `ASSETCATALOG_COMPILER_APPICON_NAME`. Per the Human
  Interface Guidelines the artwork is square and unmasked — macOS applies the rounded
  corner shape itself — with the mark kept inside the 824-of-1024 content grid so the
  system mask never clips it. Only the rendered PNG set is tracked; the vector source
  and the script that regenerates it are kept locally in `Design/`, which is not in the
  repository.

### Fixed
- USB control transfers now carry a timeout. `USBDeviceHandle` issued them with
  `DeviceRequest`, which waits forever, so a camera that stopped answering
  blocked the `UVCTransport` actor permanently — and because the whole app
  shares one transport, that hung the Dashboard, the presets and the inspector
  together, recoverable only by relaunching. Transfers now use
  `DeviceRequestTO` with a 2 s no-data and 5 s completion timeout, which
  required moving up to `IOUSBDeviceInterface182` — the oldest interface
  version exposing it. The bounds are deliberately far looser than any healthy
  transfer needs: a control transfer only queues the camera's work, so they
  bound a wedged device rather than a slow one.
- Applying a video mode could strand the stream in the camera's portrait format — which
  disables tilt — because the format assignment only takes effect if it is repeated once
  the session is running again. The apply path now re-asserts it and falls back to the
  landscape default if the camera still lands on a portrait format.
- Gimbal tilt did nothing — no motion from the D-pad, and presets never restored a
  tilt. The camera silently refuses every tilt command, relative and absolute alike,
  while it is streaming one of its portrait formats, and AVFoundation was negotiating
  1080x1920 by default on this unit. The viewfinder now selects the 1920x1080 landscape
  format on the device itself (session presets do not help — they all still resolve to
  the portrait format here), which restores full tilt control.
- Tilt on the gimbal pad ran upside down: the tilt direction byte is the opposite sense
  to pan's, so "up" drove the head down. Flipped in `GimbalPadDirection`.
- Applying a preset reported success but left the camera where it was. The restore wrote
  roll immediately after the absolute pan/tilt move, and a roll write aborts an in-flight
  gimbal move and sends the head back to its starting position. Roll is now written
  before the position rather than after.
- Nothing under the viewfinder overlay was clickable — the recording start/stop button in
  particular. `ScrollWheelZoomView`'s `NSView` covers the whole live preview to catch scroll
  events and, being an AppKit view, swallowed every mouse click behind it. It now hit-tests
  only for scroll events, so clicks fall through to the SwiftUI content.
- Viewfinder went dead ("Camera Unavailable") after navigating away from the Dashboard and
  back: the preview layer was owned by the transient view, and deallocating a layer still
  attached to a running session makes macOS 26's capture stack post runtime error -11800
  (OSStatus -67520) on re-attach. The layer is now owned by the viewfinder model so its
  lifetime matches the session's.

### Changed
- Resolution and frame rate now actually work. The picker drove the XU 0x1C write, which
  hardware testing showed to be a no-op — the camera reports the format the *host*
  negotiated, so the real control is `AVCaptureDevice.activeFormat`. The picker is now
  built from the camera's own format list and applies through the capture session
  (verified on hardware at 720p60, 1080p60 and 4K30). Only landscape formats are offered:
  streaming portrait silently disables the gimbal's tilt axis. The XU 0x1C read stays as
  the "Current Mode" readout, and applying a mode is blocked while recording so a format
  swap cannot be pulled out from under the movie file. `UVCTransport.setVideoMode` and the
  hand-maintained `VideoModePreset` table are gone.
- The Dashboard and the preset panes now share one `UVCTransport` instead of opening a USB
  handle each, and applying a preset re-reads the camera, so the Dashboard's sliders no
  longer show pre-preset values until "Reload From Camera" is pressed.

### Added
- Portrait (9:16) toggle in the Dashboard's Video Mode section. Off, the viewfinder pins
  the camera's landscape formats (today's default, which keeps the gimbal's tilt axis
  working); on, it streams the camera's 9:16 formats — what AVFoundation negotiated by
  default before the landscape pin. The resolution picker follows the toggle, and the
  gimbal pad's tilt buttons disable themselves while portrait is streaming, because the
  camera ignores every tilt command in that state (§9) and the failure is otherwise silent.

- `Checks/GimbalProbe.swift` — a hardware probe for the control channel (XU selector
  scan, absolute-position readout, raw GET/SET). Needs the Link attached, so it is not
  part of CI; build instructions are in its header.

- Phase 2 — host-side recording (`Sources/LinkController/Recording/`): start/stop button
  with elapsed-time readout overlaid on the viewfinder. Records the live capture session
  via `AVCaptureMovieFileOutput` (the camera has no record command) to a timestamped .mov
  in `~/Movies`, revealed in Finder when it finishes. Audio prefers the Link's own
  microphone, falling back to the system default input; the mic is only held open while
  recording. Refuses to start under 200 MB free disk and surfaces disk, permission, and
  mid-recording disconnect failures in the control instead of crashing.
- Phase 2 camera controls on the Dashboard. The viewfinder keeps center stage, with a
  control bar below it — press-and-hold gimbal pad driving XU relative pan/tilt with a
  guaranteed stop on release, center button, speed slider scaled into the pan 0–30 /
  tilt 0–20 caps, and a 1.0×–4.0× zoom slider with scroll-to-zoom over the live
  preview — plus a trailing inspector for image adjustments (brightness, contrast,
  saturation, sharpness, hue, white balance with auto toggle, focus with autofocus
  toggle, roll, anti-flicker) and a resolution/framerate picker. Values and ranges are
  read from the camera on connect (mirroring the viewfinder's Link discovery) and all
  controls disable when no Link is attached. The XU 0x1C video-mode write side is now
  implemented in the transport but is not yet hardware-verified.
- Phase 2 — unified preset system (`Sources/LinkController/Presets/`): a preset is one
  snapshot of pan/tilt position + zoom + image parameters (brightness, contrast,
  saturation, sharpness, hue, white balance temp/auto, focus/auto, roll, anti-flicker),
  captured from and restored to the camera through the transport's typed API. Presets
  persist as JSON in `~/Library/Application Support/LinkController/presets.json` with
  name, created date, and an at-most-one "apply on connect" default flag (the connect
  hook itself lands in a later phase). Preset Menu pane lists saved presets with
  apply / rename / delete / set-default; Preset Builder captures the camera's current
  state under a new name; progress and errors surface in a non-modal banner. Restore
  writes position first, then image params, skips manual WB/focus while their auto
  modes are on, and tolerates individual control failures. A standalone persistence
  check (`Checks/PresetPersistenceCheck.swift`) pins the on-disk schema and store
  round-trip, and runs in CI.
- Phase 1 Track A — USB/UVC transport layer (`Sources/LinkController/Transport/`):
  device discovery by VID `0x2E1A` / PID `0x4C01` via the device-level IOKit user
  client (EP0 control transfers only, video interfaces untouched), all transfers
  serialized through the `UVCTransport` actor with close + re-discover on failure,
  and a typed API for the verified Camera Terminal / Processing Unit controls plus
  the known XU 9 selectors (relative pan/tilt with stop quirk, center, video-mode
  read, device name). Write paths compile but are not yet hardware-verified.
- Phase 1 Track B: live viewfinder on the Dashboard — an AVFoundation capture preview that
  auto-selects the Insta360 Link (USB VID 0x2E1A / PID 0x4C01, falling back to any external
  camera) and handles no-camera, permission-denied, and disconnect/reconnect states.
- CI/CD and update pipeline (Phase 1 Track C, modeled on Pacer): GitHub Actions CI
  workflow (verify build on push/PR) and tag-driven release workflow (build, Developer ID
  sign, notarize, DMG, Sparkle EdDSA-signed appcast on `gh-pages`). Sparkle 2.x
  integrated with a "Check for Updates…" menu item; `SUFeedURL`/`SUPublicEDKey` ship as
  placeholders. Setup and release flow documented in `docs/RELEASING.md`.
- Implementation roadmap (`ROADMAP.md`) with confirmed scope decisions.
- Phase 0 scaffold: SwiftUI app shell with sidebar navigation (Dashboard, Preset Menu,
  Preset Builder, Settings) and placeholder panes. Project generated with XcodeGen
  (`xcodegen` then open `LinkController.xcodeproj`).
