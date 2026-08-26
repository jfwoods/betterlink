# Betterlink REST API

Betterlink can expose a small HTTP API so a Stream Deck, a shell script, or
anything else on your machine can drive the camera without touching the
window. It is off by default. Turn it on in **Settings → API**.

The API is a control surface for a *running* Betterlink. It does not start the
app, and the gimbal and recording routes need the app's viewfinder streaming,
because the camera ignores movement commands when nothing has it open.

## Enabling it

Settings → API has three things:

| Setting | Default | What it does |
| --- | --- | --- |
| Enable API | off | Starts and stops the listener. |
| Port | 8787 | The TCP port. |
| Allow access from the local network | off | Off binds `127.0.0.1` only. On binds every interface, so other machines can reach it at your Mac's LAN address. |

Enabling the API mints a bearer token and stores it in the Keychain. The pane
shows it with a **Copy** button and a **Regenerate** button. Regenerating
invalidates the old token immediately.

With local-network access off, the port is genuinely unreachable from anywhere
but this machine — a request to your own LAN address is refused, not merely
rejected.

## Authenticating

Every request needs the token:

```sh
curl -H "Authorization: Bearer $BETTERLINK_TOKEN" http://127.0.0.1:8787/status
```

Without it, or with the wrong one, every path returns `401` — including paths
that do not exist and methods that are not allowed. Authentication happens
before routing, so an unauthenticated caller cannot map the API by probing it.

Requests carrying an `Origin` header are refused with `403`, and no CORS
headers are ever sent. This API is for local tools, not for web pages.

## Routes

| Method | Path | What it does |
| --- | --- | --- |
| `GET` | `/status` | Everything at once: app version, camera, controls, position, zoom, video mode, recording state. |
| `GET` | `/presets` | The preset list — id, name, `isDefault`, `createdAt`. |
| `POST` | `/presets/{id}/apply` | Applies a preset. |
| `POST` | `/gimbal/drive` | Starts the head moving. |
| `POST` | `/gimbal/stop` | Stops it. |
| `POST` | `/gimbal/center` | Recenters it. |
| `PUT` | `/zoom` | Sets the zoom factor. |
| `GET` | `/controls` | Image controls with their ranges. |
| `PATCH` | `/controls` | Sets one or more of them. |
| `GET` | `/recording` | Recording state and elapsed time. |
| `POST` | `/recording/start` | Starts recording to `~/Movies`. |
| `POST` | `/recording/stop` | Stops and finalizes it. |

### Moving the head

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"direction":"left","durationMs":800}' \
     http://127.0.0.1:8787/gimbal/drive
```

`direction` is `up`, `down`, `left` or `right`. `durationMs` is optional: give
it and the head moves for that long, leave it out and the drive runs until you
stop it or a five-second ceiling expires.

That ceiling is a dead man's handle, not a travel limit. It exists so a client
that crashes mid-drive cannot leave the head moving forever. It re-arms on
every drive, so a client that keeps talking can pan as far as it likes. Note
that five seconds is longer than a full sweep: at the speeds this camera runs,
an abandoned drive will reach the end of its travel and stop there.

The response says what it decided:

```json
{"driving": "left", "requestedMs": 800, "stopsInMs": 800, "limit": "duration", "ceilingMs": 5000}
```

`limit` is `duration` when your `durationMs` was honoured and `ceiling` when
the dead man decided — either because you sent none, or because you asked for
longer than the ceiling and it was clamped.

Speed is not a parameter. The head moves at the pan and tilt ceilings set in
Settings → Gimbal, so the API and the on-screen controls stay consistent.

**The Dashboard wins.** While someone is holding the on-screen joystick or
D-pad, a drive, center or stop from the API is refused with `409
gimbal_control_held`. A hand on the control is a deliberate act and the API
does not get to override it. The reverse is not true: the Dashboard can always
take the head from the API.

### Image controls

`PATCH /controls` accepts any of `brightness`, `contrast`, `saturation`,
`sharpness`, `hue`, `whiteBalanceTemperature`, `focus`, `roll` as numbers,
`autoFocus` and `autoWhiteBalance` as booleans, and `antiFlicker` as one of
`off`, `50hz`, `60hz`, `auto`. Send only the keys you want to change; the
response returns the full control state.

Ranges come from the camera and are reported by `GET /controls`, so read them
rather than hardcoding. Setting `focus` while `autoFocus` is on is refused
with `auto_mode_active` — send `"autoFocus": false` in the same request.

Types are not coerced. `{"autoFocus": 1}` is an error, not `true`.

### Recording

`POST /recording/start` returns immediately with state `starting`; the
recording takes a few seconds to actually begin. A stop sent during that window
is accepted and applied as soon as the recording starts, so a record/stop pair
in quick succession does what you meant.

Recording needs the viewfinder streaming — without it you get
`viewfinder_not_streaming`.

## Errors

Every error is JSON:

```json
{"error": {"code": "out_of_range", "message": "'factor' is 5.0 but the camera accepts 1.0…4.0."}}
```

Match on `code`; the `message` is for humans and may change.

| Status | Codes |
| --- | --- |
| `400` | `malformed_json`, `body_required`, `body_not_supported`, `missing_field`, `invalid_type`, `invalid_value`, `out_of_range`, `unknown_field`, `invalid_preset_id`, `query_not_supported`, `body_too_deeply_nested` |
| `401` | `unauthorized` |
| `403` | `forbidden` — an `Origin` header was present |
| `404` | `not_found`, `preset_not_found` |
| `405` | `method_not_allowed` — the `Allow` header lists what is accepted |
| `409` | `gimbal_control_held`, `tilt_unavailable`, `camera_busy`, `recording_in_progress`, `not_recording`, `viewfinder_not_streaming`, `auto_mode_active` |
| `415` | `content_type_required`, `unsupported_media_type` |
| `503` | `camera_unavailable`, `camera_error` |

`tilt_unavailable` is worth knowing about: the camera silently ignores tilt
while the stream is portrait, so rather than accept a command it would drop,
the API refuses it and says to switch the Dashboard's stream to landscape.

## A Stream Deck button

Each button is one `curl`. A preset recall:

```sh
curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
     http://127.0.0.1:8787/presets/38BEE82E-.../apply
```

A nudge left, in a fixed step, which is what a button usually wants:

```sh
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"direction":"left","durationMs":400}' \
     http://127.0.0.1:8787/gimbal/drive
```

Get preset ids from `GET /presets`. They are stable across restarts.
