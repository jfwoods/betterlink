# Insta360 Link Controller — Investigation Findings

Grounded understanding of the first-party **Insta360 Link Controller.app v2.2.1** (Qt 5, bundle
`com.insta360.linkcontroller`, © Arashi Vision), assembled to inform a new native macOS (Swift)
controller aiming at near feature-parity.

**Investigated 2026-08-21** via four parallel workstreams: live UI exploration (computer-use on
the running app with a Link attached), static analysis of the app binary (994-string translation
table + 115 QML files recovered from compressed `qrc` blobs + protobuf/moc tables), read-only
USB/UVC probing of the live camera, and code archaeology of the prior
`insta360link-joystick-controller` project. Full raw evidence is in the scratchpad files listed
at the end; this document is the consolidated conclusion.

---

## 1. Executive summary

- **All camera control is plain USB UVC** — standard Camera-Terminal / Processing-Unit controls
  **plus three vendor Extension Units (XUs)**. Confirmed three independent ways (prior project's
  working code, live descriptor probe, and the app binary's own source-path/GUID strings).
  **No helper daemon, no serial port, no localhost server is needed** for camera control.
  QtSerialPort/QtRemoteObjects are dead leftover deps. The WebSocket+protobuf server exists only
  for the **phone remote** (QR-code pairing). The virtual camera is a **separate CMIO system
  extension** (effects pipeline only).
- **"Recording" is host-side**: the app captures the UVC stream to an `.mp4`/`.mov` via
  AVFoundation `AVAssetWriter`. The Link has no onboard storage and no start-recording camera
  command. Parity = an AVFoundation capture pipeline, not a camera command.
- **Everything else in scope is a real camera setting over UVC**: resolution, framerate, aspect,
  mirror/flip, roll, PTZ, zoom, exposure/WB/focus/image, anti-flicker, HDR, presets, device
  settings. The exact selector names are known (§4).
- **The prior project proves the transport** (IOKit device-level EP0 control transfers, no root,
  coexists with the macOS UVC driver) but only implemented 4 ops (relative pan/tilt, stop, center,
  absolute zoom). Everything else is **new work**.
- **The camera exposes absolute pan/tilt** (`CT_PANTILT_ABSOLUTE`, pan ±145°, tilt −90°…+100°,
  1° resolution) — readable, so genuine position-based presets are possible (the old
  velocity-only code could not do this).

---

## 2. Device identity & control transport

| Fact | Value |
|---|---|
| USB Vendor ID | **0x2E1A** (Insta360) |
| USB Product ID | **0x4C01** (this Link) |
| USB serial string | **none** (`iSerialNumber = 0`). For per-unit identity read XU 9 sel `0x03`. |
| Device class | Composite IAD `0xEF/0x02/0x01`, USB 2.0 High-Speed |
| Interfaces | IF0 VideoControl, IF1 VideoStreaming (BULK, single alt), IF2/IF3 Audio. **No 0xFF, no HID.** |
| Firmware (this unit) | `v1.4.5.8_build1`; on-screen name `Link-53R34Y` (XU 9 sel `0x0C` = `IBJLA24053R34Y`) |

**Control channel.** macOS `UVCAssistant` owns both video interfaces exclusively, so you cannot
claim interface 0/1. The working path (proven live and used by the prior project) is to open the
**device-level `IOUSBHostDevice`** user client and issue UVC class control transfers on endpoint 0
— this coexists with the Apple UVC driver, so the Link stays a live webcam in Zoom/QuickTime while
you control it. **No root, no entitlements.** (The first-party app instead takes interface-level
UVC access via libusb+IOKit — `deps/UVCCamera/src/mac/uvc_camera_control_imp.mm` — but the
device-level EP0 path is simpler and equally valid.)

**UVC control-transfer encoding** (identical for standard and XU controls):

```
GET:  bmRequestType 0xA1   bRequest 0x81 (GET_CUR)   wValue selector<<8   wIndex entityID<<8   wLength n
SET:  bmRequestType 0x21   bRequest 0x01 (SET_CUR)   wValue selector<<8   wIndex entityID<<8   wLength n
      wIndex low byte = 0x00 (VideoControl interface 0)
      also GET_INFO 0x86 / MIN 0x82 / MAX 0x83 / RES 0x84 / LEN 0x85 / DEF 0x87
```

Entities on VideoControl interface 0:

| Entity | ID | Role |
|---|---|---|
| Camera Terminal | 1 | zoom, focus, **absolute pan/tilt**, roll (standard UVC) |
| Processing Unit | 5 | brightness, contrast, hue, saturation, sharpness, WB temp, power-line freq |
| Extension Unit #1 (`UVC_EXTENSION_UNIT_ID`) | **9** | `FAF1672D-B71B-4793-8C91-7B1C9B7F95F8` — PTZ / resolution / exposure / AI. 32 live selectors. |
| Extension Unit #2 (`…UNIT2_ID`) | 10 | `E307E649-4618-A3FF-82FC-2D8B5F216773` |
| Extension Unit #3 (`…UNIT3_ID`) | 11 | `A8BD5DF2-1A98-474E-8DD0-D92672D194FA` |

> XU descriptors' `bNumControls`/`bmControls` are unreliable — enumerate selectors with `GET_LEN`
> and always `GET_INFO` first (several selectors are GET-only or SET-only).

### 2.1 Named XU control-selector table (from the app's `ControlSelector` enum)

The app addresses XU 9 through this enum. Selectors relevant to in-scope features are flagged:

```
XU_VIDEO_MODE_CONTROL        AI/scene mode (out of scope)
XU_PTZ_CMD_CONTROL           pan/tilt/zoom command            ← PTZ
XU_EXPOSURE_VALUE_CONTROL    exposure compensation            ← exposure
XU_ISO_CONTROL               ISO                              ← exposure
XU_EXPOSURE_TIME_ABSOLUTE_CONTROL  shutter                   ← exposure
XU_AE_MODE_CONTROL           auto-exposure on/off             ← exposure
XU_EXPOSURE_CURVE_CONTROL    custom spline exposure curve     ← exposure (advanced)
XU_AF_MODE_CONTROL           auto/manual focus mode           ← focus
XU_VIDEO_RES_CONTROL         resolution                       ← resolution
XU_PANTILT_ABSOLUTE_CONTROL / XU_PANTILT_RELATIVE_CONTROL     ← PTZ
XU_TRACK_SPEED_CONTROL / XU_LAYOUT_STYLE_CONTROL / XU_TRACK_TARGET_CONTROL / XU_HEAD_LIST_CONTROL  (AI, out of scope)
XU_GESTURE_STATUS_CONTROL / XU_GESTURE_BIND_CONTROL          (gesture, out of scope)
XU_DEVICE_INFO_CONTROL / XU_DEVICE_SN_CONTROL / XU_DEVICE_STATUS_CONTROL / XU_DEVICE_PARAM_CONTROL   device info
XU_FIRMWARE_UPGRADE_CONTROL / XU_UPLOAD_FILE_CONTROL / XU_DOWNLOAD_FILE_CONTROL / XU_USB_MODE_SWITCH_CONTROL   firmware/logs
XU_TAKE_PICTURE_CONTROL      in-camera still
XU_NOISE_CANCEL_CONTROL      audio DSP
XU_FUNC_ENABLE_CONTROL / XU_BIAS_CONTROL / XU_BLEND_DRAW_CONTROL / XU_EXEC_SCRIPT_CONTROL / XU_DEVICE_LICENSEN_CONTROL / XU_MOBVOI_PUBKEY_CONTROL
```

The higher-level app maps every parameter to a `ParamType` (78-value enum) carried in the
protobuf `UVCRequest{paramType, value}` / `UVCExtendRequest{paramType, selector, presetPosIndex}`.
The names below (§3/§4) use these `PARAM_*` tokens.

**Confirmed numeric selector mappings** (correlating the prior project + live probe with the named
enum):

| Numeric sel (XU 9) | Named / meaning | Evidence |
|---|---|---|
| `0x16` (4 B) | relative pan/tilt `[pan_dir,pan_speed,tilt_dir,tilt_speed]` = `XU_PANTILT_RELATIVE_CONTROL` | prior project + live probe |
| `0x1A` (8 B) | gimbal center/reset | prior project + live probe |
| `0x1C` (10 B) | resolution+fps `{u32 w, u32 h, u16 fps}` = `XU_VIDEO_RES_CONTROL` | live probe read `1920,1080,50` |
| `0x03` (170 B) | identity blob (serial, UUID, firmware) = `XU_DEVICE_INFO/SN` | live probe |
| `0x0C` (32 B) | device name ASCII | live probe |
| `0x14` (240 B, GET) | tracking target bbox (AI, out of scope) | live probe (inferred) |

Zoom is **standard UVC** (`CT_ZOOM_ABSOLUTE`, entity 1 sel `0x0B`), not an XU selector.

---

## 3. Feature map (first-party app) — the four priorities and beyond

### 3.1 Resolution & framerate  *(priority #1 — in scope)*

Bottom-bar picker with 3 columns **Ratio × Resolution × Frame**. The app's full internal table
(binary offset `0x545a024`) — richer than what the camera advertises over UVC at any one moment:

| Ratio | Resolutions | Framerates |
|---|---|---|
| **16:9** landscape | 4K `3840×2160`, 1080p `1920×1080`, 720p `1280×720`, **360p `640×360`** | 60/50/30/25/24; **4K = 30/25/24**, **360p = 30/25/24** |
| **9:16** portrait | 4K `2176×3840`, 1080p `1088×1920` & `1080×1920`, 720p `736×1280` | 60/50/30/25/24 (4K = 30/25/24) |

- The **live UI showed only 4K/1080p/720p (16:9)** because two gates were off:
  - **360p** requires **Settings → "Low Resolution"** enabled (`PARAM_LOWER_RES`; restarts device).
  - **9:16 / 50-60fps** requires **"Portrait Resolution and High Frame Rate"** enabled
    (`PARAM_VERTICAL_SCREEN`; restarts device; "may have issues with conferencing software"; the
    virtual camera can't do 50/60fps).
- Only hard dependency inside a ratio: **4K caps at 30fps**. Current mode string e.g. `1080p50`;
  fallback `1920x1080P30`.
- Cannot change resolution/fps **while recording** or while the stream is claimed
  (`stream_is_locked`). Overhead mode locks the framerate list.
- **Camera-advertised UVC formats** (live descriptor, current gating): MJPEG + H.264 (no YUY2) at
  1920×1080/1920×1440/1280×720/1280×960 @60/50/30/25/24, 3840×2160 @30/25/24, and portrait
  1088×1920/1080×1920/736×1280 @60/50/30/25/24.
- **Transport:** `XU_VIDEO_RES_CONTROL` (sel `0x1C`, struct `{w,h,fps}`), `PARAM_RESOLUTION` /
  `PARAM_FRAME_RATE` / `PARAM_4K_RESOLUTION` / `PARAM_LOWER_RES` / `PARAM_VERTICAL_SCREEN`.

### 3.2 Orientation  *(priority #2 — in scope)* — six distinct concepts

| Concept | Control | Proto | Notes |
|---|---|---|---|
| **Aspect (portrait/landscape)** | `switchHorizontalVertical()` | `PARAM_VERTICAL_SCREEN` | Changes the actual UVC format (§3.1); enabling portrait restarts device |
| **Horizontal flip (mirror)** | `mirrorChecked` | `PARAM_MIRROR_HOR` | *(the toggle seen live off the resolution caret)* |
| **Vertical flip** | `verticallyMirrorChecked` | `PARAM_MIRROR_VER` | gated by `supportMirrorvertically` |
| **Roll / "Horizontal fine-tuning"** | `setRoll(v)`, range `minRoll…maxRoll` | `PARAM_ROLL` / `PARAM_FINE_TUNING` | step **0.1°**, range read from device; standard-UVC `CT_ROLL_ABSOLUTE` also present (±100) |
| **Auto Horizon Lock** | `setHorizontalCorrectionChecked` | — | auto-levels from mount angle; disabled at 4K; mutually exclusive with Whiteboard/DeskView |
| **"Lock vertical shot"** | `setForcedVertical()` | `PARAM_VER_SCREEN_LOCK` | rotates the gimbal 90° and pins it **without** changing resolution |

(The live UI surfaced only Horizontal Flip + the 9:16 ratio; the rest live in submenus / are
per-model. No 180° image rotation control — `cameraRotate` 0/1/2/3 is internal geometry only.)

### 3.3 Recording  *(priority #3 — in scope)* — host-side

- `Previewer.record()` toggles capture; implementation `mac_camera_recorder.mm` →
  `AVAssetWriter` (VideoToolbox H.264; FFmpeg/libx264 also linked). Container `.mp4` (Settings
  offers **mp4 / mov**). Filename `yyyyMMdd-hhmmss`.
- **Settings → General**: Recording Save Location (`recordingPath`, default `~/Desktop`),
  **Recording Format** (`record/format`, default `1080p30`, list built from camera formats),
  Screenshot Save Location (`capturePath`, default `~/Desktop`).
- Guards: **200 MB** free-space floor; stops on preview close / mic disconnect / disk full;
  blocked during resolution switch; can't record in Privacy Mode.
- Audio: `Previewer.audioDevices` host-side picker (mic caret lists every system input; "Insta360
  Link" selected). Mic selection applies only to recordings. Screenshot = `capturePic()`
  (host-side); a separate in-camera still exists (`XU_TAKE_PICTURE_CONTROL`).
- **New-app implication:** `AVCaptureSession` → `AVCaptureMovieFileOutput` (Link video + chosen
  audio). Not a camera command.

### 3.4 Presets  *(priority #4 — in scope)* — **three** systems + hotkeys

1. **Scene presets** (`PresetSceneManager`, the sidebar "Scene presets") — **hard cap 10**. Ops
   `UPDATE | DELETE | RENAME | SELECT | DEFAULT | UNDEFAULT`. Captures a composite bundle:
   *AI mode + field-of-view/view + effects + image params*. Stored host-side in
   `*_preset_scene.json`. A preset can be marked **default** ("automatically apply each time the
   camera is connected"). This is the primary "Preset" feature.
2. **PTZ position presets** (`PtzPositionManager`) — `savePTZ/addPTZ/usePTZ/renamePTZ/delPTZ`,
   `savedPTZCount`; message `PresetPosInfo{index,name,is_default,thumbnail,createTime}`. Some
   firmware also has on-camera presets (`supportFirmwarePreset`, `goto preset id`). These are the
   position-only presets bound to the **10 hotkeys** `Option+1…Option+0`.
3. **Image/color param presets** ("Color Presets", `ImgTemplateManager`) — separate templates for
   image/color settings; can be set as startup params on the camera.

**New-app recommendation:** implement scene presets as a local composite store, and use
**`CT_PANTILT_ABSOLUTE` + zoom read/write** to snapshot/restore exact position (a strict superset
of the old velocity-only project). The camera also has a `presetPosIndex` field on the XU-extend
message if on-camera position memory is wanted.

### 3.5 Pan / tilt / zoom  *(in scope)*

- Pan/tilt: `movePanTilt(panSpeed,tiltSpeed)` (velocity, virtual joystick), `addPanTilt(rel)`
  (arrow step), `setPanTilt(yaw,pitch)` (absolute), `dragMovePanTilt` (drag-in-preview),
  `resetPTZ()` (center). Fixed "HOST" models use digital `setHostPTZ`. XUs
  `XU_PANTILT_{ABSOLUTE,RELATIVE}_CONTROL` + `XU_PTZ_CMD_CONTROL`; `PTZParam{panSpeed,tiltSpeed,
  panValue,tiltValue,hostPTZx,hostPTZy}`.
- Zoom: **1.0×–4.0×, step 0.1×** (`setZoom/addZoom/reduceZoom`); standard UVC `CT_ZOOM_ABSOLUTE`
  100–400, readable. Scroll-to-zoom, drag-to-pan in the preview.
- Prior-project quirks to carry over: **stop = XU sel `0x16` payload `[0,1,0,1]`** (not zeros;
  `dir≠0/speed=0` causes creep); always `stop` after `center`; serialize all transfers; close +
  re-discover on failure. **Direction sign is inverted vs docs in the old CLI — verify on hardware.**

### 3.6 View modes: Whiteboard / Overhead / DeskView  *(likely in scope — NOT AI tracking)*

Bottom-bar buttons (hotkeys `Option+W/O/D`), part of the `VideoModeType` enum
(`WHITEBOARD_MODE / OVERHEAD_MODE / DESKVIEW_MODE`), via `XU_VIDEO_MODE_CONTROL`. Distinct from AI
tracking. DeskView is unavailable in portrait; Overhead locks the framerate list. **Confirm scope
with user** (see §8).

### 3.7 Exposure / white balance / image  *(in scope)* — full ranges

| Control | Range / values | Step | Transport |
|---|---|---|---|
| Auto Exposure | on/off | — | `XU_AE_MODE_CONTROL` / `PARAM_AUTO_EXPOSURE` |
| Exposure Compensation | **−3 … +3** | 0.30 (≈⅓ EV) | `XU_EXPOSURE_VALUE_CONTROL` |
| ISO (manual) | **100 … 3200** (device list) | index | `XU_ISO_CONTROL` |
| Shutter (manual) | **1/30 … 1/8000** (device list) | index | `XU_EXPOSURE_TIME_ABSOLUTE_CONTROL` |
| Exposure curve | spline control points | — | `XU_EXPOSURE_CURVE_CONTROL` (advanced; likely defer) |
| Auto WB | on/off | — | `PU_WHITE_BALANCE_TEMPERATURE_AUTO` |
| Color temperature | **2000 … 10000 K** | 50 K | `PU_WHITE_BALANCE_TEMPERATURE` |
| Brightness / Contrast / Saturation / Sharpness | **0 … 100 %** | 1 % (hold = 3%) | Processing Unit (`PU_*`) |
| Hue | −15 … 15 | 1 | `PU_HUE` (present, not surfaced) |
| **HDR** | on/off | — | `PARAM_HDR`; **disables manual exposure**; unavailable at 4K or 50/60fps (PUC3/Pro exception) |
| Anti-Flicker | **0 Auto / 1 50 Hz / 2 60 Hz** | — | `PARAM_AUTI_FLICK` (maps to `PU_POWER_LINE_FREQUENCY`) |
| Auto Focus | on/off | — | `XU_AF_MODE_CONTROL` |
| Manual Focus | device min/max (`CT_FOCUS_ABSOLUTE` 0–100) | — | `XU_AF_MODE_CONTROL` / `CT_FOCUS_*` |
| Reset image | — | — | `PARAM_IMAGEPARAM_RESET` |
| Color filters | Neon, Vintage1, Vintage2, Daylight, Clear, Portrait | — | `PARAM_IMAGE_FILTER` |

This explains the live observation that Exposure appeared gated: **HDR (on by default) disables
manual exposure**, and HDR itself is off at 4K/50-60fps. Standard-UVC exposure stalls on this
camera; exposure is XU-only — hence the app routes it through XU 9.

### 3.8 Device settings & app prefs  *(in scope, selectively)*

- **Per-model capability flags** (`CameraDeviceSupporter`) gate features by model; `CameraType` ∈
  `LINK, PUC2{PTZ,HOST}{B,W}, PUC3{PTZ,HOST}{B,W}` (PUC2 = Link 2 / 2C, PUC3 = Link 2 Pro / 2C
  Pro; **PTZ = gimbal, HOST = fixed**). This unit is the original **LINK** (gimbal). A parity app
  should read these flags and hide unsupported controls.
- **Firmware update** (`XU_FIRMWARE_UPGRADE_CONTROL` / `XU_UPLOAD_FILE_CONTROL`; per-model `.bin`),
  serial/version display (`XU_DEVICE_SN/INFO_CONTROL`), **factory reset**
  (`resetCameraSettings()`), read-only USB/log mode (`XU_USB_MODE_SWITCH_CONTROL` — restarts),
  gimbal self-check, **Privacy Mode** (gimbal-down or lens-cover; `PARAM_PRIVACY_MODE`).
- **Audio DSP (device-side):** capture modes and beamforming (`XU_NOISE_CANCEL_CONTROL`,
  `PARAM_AUDIO_MODE`) — Omni / Cardioid / Supercardioid; Standard/Wide/Focus/Original.
- **App prefs** (`AppSettings`, QSettings): `capturePath`, `recordingPath`, `record/format`,
  `curLanguage`, Appearance Dark/Light/Auto, global hotkeys, selected audio device, multi-camera
  (`cameraList`, up to 4 device hotkeys `Ctrl+Option+1…4`), UI modes MainWindow/Toolbar/SystemTray.

### 3.9 Hotkeys (defaults, all `Option + …`)

`Gimbal Up/Down/Left/Right = Arrows, Center = R, Zoom In/Out = + / −, AI Tracking = T,
Whiteboard = W, Overhead = O, DeskView = D, Toggle Toolbar = M, Preset 1–10 = 1…0,
Device 1–4 = Ctrl+Option+1…4.` Master switch `enableGlobalHotkey`. (No record/screenshot hotkey.)

---

## 4. Protocol reference (verified against the live camera)

**Standard UVC controls that WORK** (read-verified INFO/MIN/MAX/RES/DEF):

| Control | Entity | Sel | Len | Range |
|---|---|---|---|---|
| `CT_ZOOM_ABSOLUTE` | 1 | 0x0B | 2 | 100…400 (1.00×–4.00×), uint16 LE |
| `CT_PANTILT_ABSOLUTE` | 1 | 0x0D | 8 | pan ±522000 (±145°), tilt −324000…+360000 (−90°…+100°), res 3600 (1°); two int32 LE arc-sec |
| `CT_ROLL_ABSOLUTE` | 1 | 0x0F | 2 | −100…100 |
| `CT_FOCUS_ABSOLUTE` / `CT_FOCUS_AUTO` | 1 | 0x06 / 0x08 | 2 / 1 | 0…100 / 0-1 (manual writable when auto off) |
| `PU_BRIGHTNESS/CONTRAST/SATURATION/SHARPNESS` | 5 | 0x02/0x03/0x07/0x08 | 2 | 0…100 def 50 |
| `PU_HUE` | 5 | 0x06 | 2 | −15…15 |
| `PU_WHITE_BALANCE_TEMPERATURE` / `_AUTO` | 5 | 0x0A / 0x0B | 2 / 1 | 2000…10000 def 6400 / 0-1 |
| `PU_POWER_LINE_FREQUENCY` | 5 | 0x05 | 1 | 0…3 (Anti-Flicker) |

**Stall (not implemented) as standard UVC:** all exposure controls, iris, `CT_PANTILT_RELATIVE`
(declared but stalls), zoom-relative, privacy, gain, gamma, backlight. → exposure & relative
pan/tilt & HDR are **XU-only**.

**XU 9 known selectors:** `0x16` relative pan/tilt (4 B `[pan_dir,pan_speed,tilt_dir,tilt_speed]`,
dir 0x01/0xFF/0x00, pan 0–30, tilt 0–20); `0x1A` center (8 zero B); `0x1C` resolution+fps (10 B
`{w,h,fps}`); `0x0C` device name; `0x03` identity. Named enum in §2.1. XU 10/11 purpose unknown
(would need USB traffic capture of the official app).

---

## 5. Scope

**In scope (parity target):** resolution, framerate, aspect/orientation (portrait, H-flip, V-flip,
roll fine-tune, horizon lock, lock-vertical), host-side recording + screenshot + audio-source
select, presets (scene ×10 composite, PTZ-position, color templates), pan/tilt/zoom/center,
exposure (comp/ISO/shutter/AE)/WB/focus/brightness/contrast/saturation/sharpness/anti-flicker/HDR,
color filters, device settings (firmware, serial, factory reset, privacy mode, audio DSP),
hotkeys, PiP, multi-camera, appearance. View modes (Whiteboard/Overhead/DeskView) **pending user
confirmation**.

**Out of scope (per request):** Gesture Control (5 gestures × bindable actions), AI Tracking /
Auto-Framing / Smart Composition / tracking areas, AI Recording (InSight cloud transcription,
login + paid plan). Also virtual-camera-only effects (background blur/replace, green screen,
beautify/makeup) are AI/effects pipeline — treat as out of scope unless the user says otherwise.

---

## 6. Implications & recommendations for the new Swift app

1. **Transport:** device-level `IOUSBHostDevice` user client (VID 0x2E1A / PID 0x4C01), UVC class
   control transfers on EP0, do **not** seize interfaces. Serialize transfers (actor/serial
   queue). Match VID/PID, not serial (none); read XU 9/0x03 for identity in multi-camera setups.
2. **Recording** = an independent AVFoundation capture pipeline.
3. **Most image controls are plain standard-UVC** — implement straight from §4. Exposure, HDR,
   relative pan/tilt, resolution, mirror/flip are **XU** — implement via XU 9 selectors in §2.1/§4.
4. **Presets:** local composite store + absolute-PTZ snapshot/restore.
5. **Gate the UI by per-model capability flags** so the same app supports Link / Link 2 / 2C / Pro.
6. **Verify on hardware** the write-side selectors before shipping (§9).

---

## 7. Prior project (`insta360link-joystick-controller`) — carry-over

- Proven IOKit transport, VID/PID, wire format. Implemented ops: relative pan/tilt (XU 0x16), stop
  (`[0,1,0,1]`), center (XU 0x1A), absolute zoom (CT 0x0B r/w). **No** resolution/framerate/
  orientation/recording/presets/image — those are new.
- Architecture: C `linkctl-daemon` (only thing touching the camera) + ESP32 joystick over
  WebSocket + TCP CLI. Behaviors worth reusing: auto-stop on idle, stop-after-center, deadzone +
  quadratic response, mutex around camera access, close/re-discover on failure.
- **Caveat:** the CLI's pan/tilt direction is inverted vs its own docs — trust hardware, not docs.

---

## 8. Open questions for the user (do not assume)

1. **View modes** (Whiteboard / Overhead / DeskView): include for parity? They're framing modes,
   not AI tracking — presumed in scope, please confirm.
2. **Multi-camera / multi-model** support wanted, or single Link only? (Affects identity handling
   and per-model capability gating.)
3. **Presets:** match the first-party model (composite "Scene presets" ×10 + PTZ-position presets +
   color templates), or a simpler single PTZ-position preset system?
4. **Virtual-camera effects** (background blur/replace, green screen, beautify) — these ride the
   CMIO extension + AI models; confirmed out of scope, but flagging since they're prominent in the
   first-party app.

## 9. Needs hardware verification before shipping (probe writes / capture)

- Write-side of `XU_VIDEO_RES_CONTROL` (sel `0x1C`, `{w,h,fps}`) and device-restart behavior;
  the Low-Resolution and Portrait mode enable/restart flows.
- Exact numeric selectors + payload formats for: exposure comp/ISO/shutter/AE, HDR, mirror
  H/V, roll, view modes, privacy mode (the **names** are known from §2.1; the **numbers/encodings**
  need a probe or a USB capture of the official app).
- Absolute pan/tilt direction sign, settle times.
- XU 10 / XU 11 function.

---

## Sources (scratchpad)

- `scratchpad/app-static.md` — full static analysis of the 2.2.1 bundle: transport, the named XU
  `ControlSelector` (35) + `ParamType` (78) enums, protobuf/moc API surface, the verbatim
  resolution table, exposure/WB ranges, the three preset systems, device settings, and the
  in/out-of-scope split. Recovered QML in `scratchpad/qml/`, strings in `bin-strings*.txt`,
  `en-US.txt`.
- `scratchpad/uvc-usb.md` — live read-only USB/UVC enumeration: descriptor topology, resolution
  matrix, standard-UVC control ranges, XU-9 selector probe. Raw dumps `desc.txt`, `uvcctl.txt`,
  `avf_out.txt`, `ioreg_insta.txt`.
- `scratchpad/prior-art.md` — protocol extraction from the joystick project with `file:line`
  citations and a wire-format cheat sheet; recovered deleted design docs in `scratchpad/recovered/`.
</content>
