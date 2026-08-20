# BG_Sensing V2 — Scientific Data Format

This document describes the on-disk data format produced by the
**BG_Sensing V2** iOS app (a separate, independently-installed app from V1 —
see `ios/project.yml`'s `BG_Sensing_V2` target), so that a researcher who
receives only an exported recording session plus this document can interpret
the dataset correctly without the app.

It starts as an exact copy of `SCIENTIFIC_DATA_FORMAT.md` (V1's format,
frozen and still accurate for the V1 app) and will diverge from here as V2's
capture-quality work lands — new capture modes, raw+smoothed depth, mesh
anchors, high-resolution texture keyframes. Until a section below is
specifically updated for a V2 change, treat it as identical to V1's.

**V2 changelog** (reliability/internal fixes that don't change the on-disk
format, tracked here since they affect what a recorded session can be
trusted to contain):
- Bounded write queue + a real drain barrier on stop: V1's per-frame write
  admission was effectively unbounded (an unstructured `Task` per frame with
  no cap), and its `dropped`-frame counter could never actually trigger
  under sustained I/O backpressure because `DataWriter`'s actor calls have
  no internal suspension point, so the "in-flight write" count could never
  exceed 1. V1's `stopRecording()` also didn't wait for a session's last
  in-flight writes before finalizing `metadata.json`, so the final
  frame/sample counts and "session ready to share" signal could both be
  emitted before every file was actually on disk. V2 fixes both: frame
  writes are admitted against an explicit outstanding-writes cap (rejecting
  and correctly counting a drop instead of piling up retained pixel
  buffers), and stopping a recording now awaits every outstanding write
  before finalizing metadata and marking the session shareable.

**Status: Phase 4 (inherited from V1) + V2 reliability fixes.** RGB + LiDAR
depth recording, Core Motion, and Core Location (GPS + heading) are
implemented. Barometer and export/zip land in later phases (see
`SETUP.md`) and this document will grow accordingly. Sections are marked
`[Phase N]` to show when they became accurate.

## 1. Overview

The app acquires RGB imagery, LiDAR depth, motion, GPS, and barometric data
from an iPhone simultaneously, and saves each recording as one self-contained
session directory under the app's Documents folder:
`Documents/Sessions/Session_<local-datetime>_<uuid8>/`. Every measurement is
timestamped so streams can be synchronized during offline analysis; the app
does not attempt to force streams into artificial simultaneity.

## 2. Session directory layout `[Phase 2]`

```text
Session_2026-08-19_11-45-32_a1b2c3d4/
    metadata.json

    rgb/
        frame_000001.heic
        frame_000002.heic
        ...

    depth/
        depth_000001.bin
        depth_000001.json
        confidence_000001.bin        (only if the device reported a confidence map)
        depth_000002.bin
        depth_000002.json
        ...

    sensors/
        frames.csv                   (per RGB/depth frame-pair metadata)
        motion.csv                   (Core Motion, ~50 Hz — Section 12)
        location.csv                 (GPS fixes — Section 13)
        heading.csv                  (compass headings — Section 13)
        altimeter.csv                (Phase 5)
```

RGB and depth frames share the same 6-digit, 1-based frame index and are
captured from the *same* `ARFrame` (same native timestamp) — `frame_000042.heic`
and `depth_000042.bin`/`.json` are always the same instant. This is the
project's synchronization mechanism for these two streams: rather than
timestamp-matching two independent capture pipelines, both are read out of one
ARKit frame, so they're exactly simultaneous by construction.

## 3. Coordinate systems `[Phase 1 conventions; Phase 2 adds the worked example]`

Several distinct coordinate systems are involved. They are **not**
interchangeable and must not be confused:

| System | Description | Units |
|---|---|---|
| **ARKit world coordinates** | Right-handed coordinate system established when the AR session starts tracking (`ARWorldTrackingConfiguration`, `worldAlignment = .gravity`). With gravity alignment: +Y points up (opposite gravity), and the X/Z plane is horizontal. The origin is wherever the device was when tracking began — it is **not** geographic and resets every session. | meters |
| **ARKit camera coordinates** | Right-handed, camera-relative: +X right, +Y up, +Z out of the screen toward the user (i.e. the camera looks down -Z). The camera transform (Section 5) maps camera coordinates into world coordinates. | meters |
| **Image pixel coordinates** | Origin top-left, +X right, +Y down, in pixels of the captured RGB image at its *captured*, unrescaled resolution. See Section 7 on orientation. | pixels |
| **Depth-map coordinates** | Origin top-left, +X right, +Y down, in pixels of the depth map, which is a lower resolution than the RGB image (typically 256x192 on iPhone 14 Pro). Use each depth frame's own *scaled* intrinsics (Section 6), never the RGB frame's. | pixels |
| **Device coordinates** | Core Motion's reference frame for attitude/acceleration/rotation, relative to the device casing, not the camera. See Section 12.1. | — |
| **Geographic WGS84** | Latitude/longitude from Core Location (`location.csv`, Section 13). | decimal degrees |
| **Mean-sea-level (MSL) altitude** | GPS-derived altitude as reported by Core Location (`CLLocation.altitude`, `location.csv`'s `altitude` column), which on iOS is referenced to mean sea level, not the WGS84 ellipsoid. | meters |
| **WGS84 ellipsoidal altitude** | Height above the WGS84 ellipsoid (`CLLocation.ellipsoidalAltitude`, `location.csv`'s `ellipsoidalAltitude` column) — distinct from MSL altitude above; never combined with it. Empty if the device doesn't report it for a given fix. | meters |
| **Relative barometric altitude** | `CMAltimeter`'s relative altitude, referenced to wherever the barometer session started (device power-on / app session start) — **not** sea level and **not** GPS altitude. Documented fully in Phase 5. | meters |

GPS altitude and barometric altitude are always stored as separate fields.
They are never combined or used to correct one another.

### 3.1 Depth pixel → 3-D point (worked example) `[Phase 2, corrected]`

Given a depth-map pixel `(u, v)` from `depth_NNNNNN.bin`, with depth value
`d` (meters) at that pixel, and the *depth frame's own* `intrinsics` array
from `depth_NNNNNN.json` (row-major 3x3: `[fx, 0, cx, 0, fy, cy, 0, 0, 1]`),
back-project to a point in ARKit camera coordinates:

```
x_cam =  (u - cx) * d / fx
y_cam = -(v - cy) * d / fy
z_cam = -d
```

**The Y and Z signs matter and are easy to get backwards** (an earlier
version of this document had them wrong: `z_cam = d`, no sign flips). The
naive pinhole formula (`x=(u-cx)d/fx, y=(v-cy)d/fy, z=d`) assumes a
computer-vision-style camera space where +Y is down and +Z points into the
scene. ARKit's camera space (Section 2) is different: +Y is **up** and the
camera looks down **-Z** — the same convention SceneKit's own cameras use,
which is exactly why ARKit's `camera.transform` can be dropped straight
onto a SceneKit camera node (as `ARSCNView` does) and just work. Converting
from the image-plane back-projection into that convention means flipping Y
(image rows go down, world Y goes up) and flipping Z (a positive depth
means "in front of the camera," i.e. the -Z direction).

Then transform into ARKit world coordinates using the same JSON file's
`transform` array (row-major 4x4, Section 5) — treat `[x_cam, y_cam, z_cam, 1]`
as a column vector and left-multiply by the transform matrix:

```
[x_world]   [m11 m12 m13 m14]   [x_cam]
[y_world] = [m21 m22 m23 m24] * [y_cam]
[z_world]   [m31 m32 m33 m34]   [z_cam]
[   1   ]   [m41 m42 m43 m44]   [  1  ]
```

**Do not use the RGB frame's own `intrinsics` from `frames.csv` for this** —
those are calibrated for the RGB image's resolution, not the depth map's. See
Section 6.

## 4. Timestamps `[Phase 2 — implemented; corrects a Phase 1 documentation error]`

Every measurement carries multiple timestamp fields; none is treated as a
substitute for another:

1. **`sessionTimeSeconds`** — floating-point seconds since `t = 0`, defined as
   the moment START RECORDING is pressed. This is the common analysis
   timeline across all sensor streams. Computed as
   `nativeSensorTimestamp - sessionStartMonotonic`, where
   `sessionStartMonotonic` is the `systemMonotonicTime` reading captured the
   instant recording started.
2. **`systemMonotonicTime`** — seconds since device boot
   (`ProcessInfo.processInfo.systemUptime`, the same clock domain as
   `CACurrentMediaTime()`). Not wall-clock, immune to clock/timezone
   adjustments.
3. **`utcTimestamp`** — wall-clock UTC date/time (ISO 8601), for human
   reference and for correlating against external logs. Never used as the
   primary synchronization key because system clock adjustments can make it
   non-monotonic.
4. **`nativeSensorTimestamp`** — the timestamp the originating framework
   attaches to the sample, preserved as-is.

**Correction from Phase 1:** the Phase 1 version of this document stated that
`ARFrame.timestamp` is "seconds since the ARSession started." That was wrong
— it is actually seconds since **device boot**, i.e. the *same* clock domain
as `systemMonotonicTime` above (and, per Apple's documentation, the same
domain Core Motion's sample timestamps use). It is **not** reset when the
ARSession starts or restarts. This turns out to simplify synchronization: for
AR frames and (from Phase 3) Core Motion samples,
`nativeSensorTimestamp == systemMonotonicTime` exactly — no cross-domain
conversion needed, just subtract the session's start time. Core Location's
timestamps are wall-clock (`Date`), a genuinely different domain — see
Section 13.1 for how `location.csv`/`heading.csv` handle that.

No measurement's timestamp is ever fabricated or interpolated to "line up"
with another stream — true acquisition times are preserved so alignment can
be done deliberately during analysis.

## 5. Camera pose / ARKit camera transform `[Phase 2]`

`ARFrame.camera.transform` is a 4x4 matrix that maps ARKit camera-space
coordinates to ARKit world-space coordinates. It is stored in **row-major**
order as a flat 16-element array: `[m11,m12,m13,m14, m21,m22,m23,m24,
m31,m32,m33,m34, m41,m42,m43,m44]` — never reduced to pitch/roll/yaw, so
later 3-D reconstruction has the exact pose ARKit used at capture time.

(Implementation note: `simd_float4x4` stores matrices *column*-major
internally; `GeometryUtilities.rowMajor(_:)` in the app's source performs the
transpose when flattening for output, so the row-major convention documented
here is what actually ends up on disk.)

The RGB frame's `transform` (in `frames.csv`) and its paired depth frame's
`transform` (in `depth_NNNNNN.json`) are always identical, since both come
from the same `ARFrame`.

## 6. RGB frames (`rgb/frame_NNNNNN.heic` + `sensors/frames.csv`) `[Phase 2]`

- **Image file**: HEIC, encoded from `ARFrame.capturedImage` via Core
  Image/ImageIO at quality 0.9, at the camera's full captured resolution —
  never rescaled. No color management beyond ARKit's own ISP defaults; no
  white-balance/exposure lock. This is compressed capture from ARKit's
  continuous video feed, not a RAW/ProRAW photo pipeline.
- **`frames.csv`** has one row per captured RGB/depth pair, columns:

| Column | Meaning |
|---|---|
| `frameID` | 1-based index, matches the `NNNNNN` in the filenames |
| `sessionTimeSeconds`, `systemMonotonicTime`, `utcTimestamp`, `nativeSensorTimestamp` | See Section 4 |
| `imageWidth`, `imageHeight` | Pixels, of the saved HEIC |
| `orientation` | Always `landscapeRight_rawSensor_unrotated` currently — see below |
| `intrinsics_m11`..`intrinsics_m33` | Row-major 3x3, **at the RGB image's own resolution** — do not use on depth pixels (Section 3.1) |
| `transform_m11`..`transform_m44` | Row-major 4x4 ARKit world<-camera transform (Section 5) |
| `trackingState` | ARKit tracking state at capture (`Normal`, `Limited (...)`, etc.) — treat frames captured while not `Normal` with caution for pose-dependent analysis |
| `correspondingDepthFrameID` | Same as `frameID` when a depth frame was captured alongside; empty if scene depth was momentarily unavailable for that frame |

**Exposure metadata is not recorded.** The spec asked for exposure-related
metadata "where reasonably available" — it isn't: ARKit's public `ARFrame`
API does not expose exposure duration, EV offset, or ISO (an earlier version
of this code assumed `ARFrame.exposureDuration`/`.exposureOffset` existed;
they don't — this was caught by a real compiler error, not by inspection).
The underlying `AVCaptureDevice` that owns real exposure/ISO values isn't
accessible while ARKit's session owns the camera. Rather than fabricate
placeholder columns, they're omitted entirely.

**Orientation caveat**: ARKit delivers `capturedImage` in the camera's native
landscape sensor orientation and does **not** rotate it to match the app's
(portrait-locked) UI — this app does not rotate the pixels either, to avoid
extra processing and any resampling quality loss. A consumer displaying these
images "right side up" for a portrait capture typically needs to rotate 90°
clockwise. This is a fixed, documented convention for this MVP rather than
live-tracked device orientation.

## 7. Depth frames (`depth/depth_NNNNNN.bin` + `.json` [+ `confidence_NNNNNN.bin`]) `[Phase 2]`

- **`depth_NNNNNN.bin`**: raw **Float32, little-endian, row-major**, exactly
  `width * height * 4` bytes, no header, no padding (row padding present in
  the source `CVPixelBuffer` is stripped when written — see
  `DataWriter.packedRasterData` in the source). Units: **meters**. This is
  ARKit's *raw* `sceneDepth` (not the smoothed/interpolated variant) — the
  least-processed scientifically useful depth ARKit provides. A zero or
  non-finite value has no special meaning reserved in this raw file; treat
  per-pixel validity via the paired confidence map if present.
- **`confidence_NNNNNN.bin`** (only written if the device reports a
  confidence map): raw **UInt8, row-major**, `width * height` bytes, one byte
  per pixel, ARKit's `ARConfidenceLevel` raw values: `0` = low, `1` = medium,
  `2` = high.
- **`depth_NNNNNN.json`** sidecar, fields:

| Field | Meaning |
|---|---|
| `depthFrameID` | Matches `NNNNNN` and the paired RGB frame's `frameID` |
| `sessionTimeSeconds`, `systemMonotonicTime`, `utcTimestamp`, `nativeSensorTimestamp` | Identical to the paired RGB frame's — same `ARFrame` |
| `width`, `height` | Pixels, of this depth map (not the RGB image's resolution) |
| `dataType` | `"Float32"` |
| `byteOrder` | `"littleEndian"` |
| `units` | `"meters"` |
| `depthType` | `"raw_sceneDepth"` (reserved values for a future smoothed-depth or LiDAR-mesh option, not yet implemented — see `RecordingConfiguration.depthType` in `metadata.json`) |
| `hasConfidence` | Whether `confidence_NNNNNN.bin` was written |
| `intrinsics` | Row-major 3x3, **scaled from the RGB frame's intrinsics to this depth map's resolution** — see `intrinsicsNote` and Section 3.1 |
| `intrinsicsNote` | States the exact scale factors used, for auditability |
| `transform` | Row-major 4x4, identical to the paired RGB frame's (Section 5) |
| `correspondingRGBFrameID` | Matches the paired `rgb/frame_NNNNNN.heic` |

### 7.1 Why depth intrinsics are scaled

`ARFrame.camera.intrinsics` is calibrated for the RGB image's resolution
(e.g. 1920x1440). The LiDAR depth map is a different, lower resolution (e.g.
256x192). Using the RGB intrinsics directly on depth-map pixel coordinates
would silently produce wrong 3-D points. Each depth JSON file's `intrinsics`
field has already been scaled (`fx' = fx * depthWidth/imageWidth`, `cx' = cx
* depthWidth/imageWidth`, and similarly for `fy`/`cy` with the height ratio)
so it can be used directly with that depth map's own pixel coordinates
(Section 3.1's worked example).

## 8. Units and missing-data convention `[Phase 1; units list extended in Phase 3]`

- Distances/altitudes: meters. Angles: radians unless noted. Pressure:
  kilopascals (`CMAltimeter`/`CMAltitudeData` native unit). Accuracy fields:
  same unit as the value they describe. Acceleration (`userAcceleration`,
  `gravity`): **g** (9.80665 m/s² per g), Core Motion's native unit — not
  raw m/s². Rotation rate: radians/second. Magnetic field: microtesla (µT).
- A sensor that is unavailable, denied, or produced no reading for a given
  moment is represented by an explicit missing-data marker (`null` in JSON,
  empty field in CSV, or `NaN` for floating-point values that must remain
  numeric) — never by a fabricated zero. `sensorAvailability` in
  `metadata.json` records which sensors were present for the whole session.

## 9. `metadata.json` `[Phase 2 — real schema; grows in later phases]`

Written twice: once when recording starts (so a crash mid-session still
leaves a valid, if incomplete, description of what was being recorded), and
again — overwriting the first — when recording stops, with final counts.

| Field | Meaning |
|---|---|
| `appVersion` | `CFBundleShortVersionString (CFBundleVersion)` |
| `sessionID` | Matches the session's directory name |
| `sessionStartUTC`, `sessionEndUTC` | ISO 8601. `sessionEndUTC` is `null` in the start-of-session copy |
| `deviceHardwareIdentifier` | Raw identifier from `uname()`, e.g. `"iPhone15,2"` (an iPhone 14 Pro) — not translated to a marketing name, so it stays accurate as new hardware ships |
| `systemVersion` | iOS version |
| `recordingConfiguration` | `{rgbFormat, rgbCaptureRateHz, captureMode, depthFormat, depthType, confidenceFormat}` — `captureMode` is `"continuous"` or `"manual"` (Section 11.1); `rgbCaptureRateHz` is meaningless for a `"manual"` session (frames are irregular, operator-triggered) |
| `coordinateSystems` | Human-readable description of each coordinate system in use (Section 3), embedded so the dataset is self-describing even without this file |
| `units` | Same idea, for units (Section 8) |
| `sensorAvailability` | `{camera, lidarSceneDepth, motion, location, heading}` as booleans — a boolean for barometer arrives with Phase 5 |
| `frameCounts` | `{rgbFramesWritten, depthFramesWritten, motionSamplesWritten, locationSamplesWritten, headingSamplesWritten}` — `null` in the start-of-session copy |
| `droppedFrames` | Count of frames skipped due to write backpressure (disk couldn't keep up) — `null` in the start-of-session copy |
| `diskWriteErrors` | Count of write failures (not backpressure — actual I/O errors) — `null` in the start-of-session copy |
| `notes` | Free text, currently used to flag which copy (start vs. final) this is |

## 10. Recording health / data-loss reporting `[Phase 2]`

Two distinct "something didn't get written" cases are tracked and reported
separately, both in the live UI while recording and in the final
`metadata.json`:

- **Dropped frames**: the write pipeline (`DataWriter`) had too many writes
  already in flight (more than 6 concurrent) and skipped this frame rather
  than let memory grow unboundedly. This means disk I/O can't keep up with
  the configured capture rate on this device.
- **Disk write errors**: an actual I/O failure (e.g. out of space, permission
  error) while attempting a write.

Neither is silent — both increment a visible counter and the most recent
error message is shown in the recording health panel.

## 11. Implementation notes `[Phase 2]`

- RGB capture rate defaults to 5 Hz (`RecordingSessionManager.rgbCaptureRateHz`),
  throttled by comparing each AR frame's `sessionTimeSeconds` to the last
  captured frame's. Depth is captured in lockstep with RGB (same `ARFrame`),
  not on an independent schedule — see Section 2.
- All disk I/O (HEIC encode, raw binary writes, JSON, CSV append) happens on
  a dedicated `DataWriter` actor, off both the main thread and ARKit's
  delegate callback thread, so recording never blocks the UI or frame
  acquisition.
- Cross-thread recording state (is-recording flag, frame counter, session
  start time) is protected by `OSAllocatedUnfairLock`, since it's written
  from the main thread (Start/Stop buttons) and read/written from ARKit's
  background delegate queue (every frame).
- `sensors/frames.csv`'s header line is written synchronously (not via the
  async `DataWriter`) before recording is allowed to start, to guarantee it
  can never race with — and land after — the first data row.

### 11.1 Capture mode: Continuous vs. Manual

Chosen before START RECORDING (a segmented control on the main screen;
`RecordingSessionManager.captureMode`, not safe to change mid-session) and
recorded in `metadata.json`'s `recordingConfiguration.captureMode`:

- **`"continuous"`** (default): the behavior described above — auto-capture
  throttled to `rgbCaptureRateHz`. Frame timing is regular
  (`sessionTimeSeconds` deltas ≈ `1/rgbCaptureRateHz`).
- **`"manual"`**: nothing is captured automatically. A CAPTURE button
  writes exactly one RGB+depth+sensor snapshot per tap, from whichever AR
  frame ARKit most recently delivered at that instant (typically within one
  frame interval, ~16ms, of the tap — not the tap's own wall-clock moment).
  Frame timing is irregular and operator-driven; `frameID`s are still
  sequential and gapless, same file layout, same `frames.csv`/depth-JSON
  schema — a session recorded this way is not distinguishable file-format-wise
  from a sparse continuous one except via `recordingConfiguration.captureMode`.

Manual mode exists because continuous capture-while-moving produces motion
blur and heavy frame-to-frame overlap (adjacent frames of a slowly-panned
scene are nearly identical, which shows up as streaky, doubled geometry when
multiple frames' point clouds are merged — see `../macos/BG_Viewer`).
Deliberate stand-still-and-tap capture — closer to traditional photogrammetry
workflow — trades data density for per-frame sharpness and reduced redundancy.

**Motion (Section 12) always records continuously at ~50 Hz regardless of
`captureMode`** — the mode setting only governs RGB/depth. Motion samples are
cheap (a CSV row, no image encode) and dense continuous tracking is the whole
point, so there's no motion equivalent of "manual" capture.

## 12. Motion (`sensors/motion.csv`) `[Phase 3]`

Core Motion device-motion samples at a target rate of 50 Hz
(`CMMotionManager.deviceMotionUpdateInterval = 1/50`; actual delivered rate
depends on device load). Recorded continuously whenever a recording is
active — see 11.1. Unlike RGB/depth, motion has no frame-pairing with
anything else; each row is independent.

### 12.1 Device coordinate system

Core Motion's own frame, **distinct from ARKit's world/camera frames**
(Section 3) — do not mix the two without an explicit transform. With the
device held in portrait, screen facing the user: **+X points right, +Y
points toward the top of the device, +Z points out of the screen toward the
user.** This is Apple's standard convention across `CMAttitude`,
`CMAcceleration`, `CMRotationRate`, and `CMMagneticField` alike.

### 12.2 `motion.csv` columns

| Column | Meaning |
|---|---|
| `sampleID` | 1-based, independent sequence from `frameID` (Section 6) |
| `sessionTimeSeconds`, `systemMonotonicTime`, `utcTimestamp`, `nativeSensorTimestamp` | See Section 4 — same boot-relative domain as AR frames, so motion and RGB/depth timestamps are directly comparable with no cross-domain conversion |
| `attitudeReferenceFrame` | `"xMagneticNorthZVertical"` or `"xArbitraryZVertical"` — see 12.3 |
| `roll`, `pitch`, `yaw` | Radians. Device attitude (Euler angles) in the reference frame above |
| `quaternionX/Y/Z/W` | Same attitude as a unit quaternion — prefer this over roll/pitch/yaw for composing rotations (no gimbal lock) |
| `rotationMatrix_m11`..`m33` | Same attitude again, as a row-major 3x3 rotation matrix, dimensionless |
| `userAccelerationX/Y/Z` | Gravity-**removed** acceleration from device motion, in **g** (not m/s²) |
| `gravityX/Y/Z` | Direction of gravity in the device frame, in g (magnitude ≈ 1.0) |
| `rotationRateX/Y/Z` | Gyroscope, radians/second |
| `magneticFieldX/Y/Z` | Magnetometer, **microtesla (µT)** |
| `magneticFieldCalibrationAccuracy` | `"uncalibrated"` / `"low"` / `"medium"` / `"high"` — Core Motion's own compass calibration confidence; filter or flag low-confidence samples accordingly |

**Never mix `userAcceleration` and `gravity`** — they are the gravity-corrected
and gravity-only decomposition of the same physical acceleration
respectively, not raw combined accelerometer output. There is no separate
"raw accelerometer" column: `CMDeviceMotion` (used here, not the lower-level
`CMAccelerometerData`) only exposes this decomposed pair, which is the more
scientifically useful form Apple's own sensor fusion produces.

### 12.3 Attitude reference frame vs. compass heading

`attitudeReferenceFrame` is `"xMagneticNorthZVertical"` when the device
supports it (checked via `CMMotionManager.availableAttitudeReferenceFrames()`
at recording start), falling back to `"xArbitraryZVertical"` — arbitrary,
not tied to any compass direction — if not.

**This is not the same as `heading.csv`'s compass heading (Section 13.3),
and is intentionally not as precise:**
- It is **uncalibrated for magnetic declination** (the offset between
  magnetic north and true/geographic north, which varies by location).
- It came from Core Motion directly rather than `CLHeading` in Phase 3,
  because `CLHeading` requires Core *Location* permission — which Phase 3
  deliberately didn't request yet, to keep it scoped to Core Motion only.
  Phase 4 (Section 13) now adds the real thing.

Treat `heading.csv`'s `magneticHeading`/`trueHeading` as the authoritative
compass reading; `motion.csv`'s `yaw` is a directionally-useful but coarser
proxy, not a replacement — keep using it for attitude (roll/pitch/yaw as a
consistent triple), not as a compass.

## 13. Location & heading (`sensors/location.csv`, `sensors/heading.csv`) `[Phase 4]`

Core Location: GPS fixes (`location.csv`) and compass headings
(`heading.csv`), in separate files since they arrive as independent,
asynchronously-rated update streams from `CLLocationManager` — see 13.4.
Recorded continuously whenever a recording is active, at whatever rate iOS
delivers updates (no throttling applied, matching the spec's "do not
discard poor-accuracy observations" — every update iOS delivers is
recorded, accuracy field included, rather than filtered).

Requires "When In Use" location authorization
(`NSLocationWhenInUseUsageDescription`), requested on first launch after
this phase. If denied, `sensorAvailability.location`/`.heading` are `false`
and no location/heading files are written for that session — this is
surfaced in the live status panel ("GPS auth: Denied") and via
`RecordingSessionManager`'s error message, not silently.

### 13.1 Why Core Location's timestamps get different treatment

Unlike `ARFrame.timestamp`/`CMDeviceMotion.timestamp` (both boot-relative,
Section 4), `CLLocation.timestamp` and `CLHeading.timestamp` are **wall-clock
`Date` values** — a genuinely different domain, flagged back in Section 4 as
needing special handling once this phase landed. Two wall-clock fields are
recorded, not one:

- **`utcTimestamp`** — wall-clock at the instant this app's delegate
  callback *received* the update (captured via `Date()` right when the
  callback fires), matching the semantics `utcTimestamp` has in every other
  file in this format.
- **`nativeLocationTimestampUTC`** / **`nativeHeadingTimestampUTC`** —
  `CLLocation`/`CLHeading`'s own timestamp: when the fix or heading reading
  was actually computed. This can meaningfully lag `utcTimestamp` by GPS's
  computation/delivery latency (typically small, but not zero, and worth
  keeping separate rather than assuming they're identical).

`sessionTimeSeconds`/`systemMonotonicTime` are still boot-relative and still
directly comparable to every other stream's — they're derived from
`ProcessInfo.processInfo.systemUptime` captured at the same delegate-callback
receipt instant as `utcTimestamp`, not from `CLLocation`'s own timestamp
(which has no boot-relative equivalent to draw from).

### 13.2 `location.csv` columns

| Column | Meaning |
|---|---|
| `sampleID` | 1-based, independent sequence from every other stream's IDs |
| `sessionTimeSeconds`, `systemMonotonicTime`, `utcTimestamp` | See 13.1 — receipt-time based |
| `nativeLocationTimestampUTC` | See 13.1 — `CLLocation`'s own fix time |
| `latitude`, `longitude` | Decimal degrees, WGS84 |
| `altitude` | Meters, **mean sea level** — see coordinate system table (Section 3), never combined with `ellipsoidalAltitude` or with `altimeter.csv`'s relative altitude (Phase 5) |
| `ellipsoidalAltitude` | Meters, WGS84 ellipsoid. Empty field if unavailable |
| `horizontalAccuracy`, `verticalAccuracy` | Meters. **Negative means invalid** (`CLLocation`'s own convention) — never discarded or clamped, always recorded as-is per the "don't discard poor-accuracy observations" requirement |
| `speed`, `speedAccuracy` | Meters/second. Negative = invalid |
| `course`, `courseAccuracy` | Degrees from true north, 0..<360. Negative = invalid |

### 13.3 `heading.csv` columns

| Column | Meaning |
|---|---|
| `sampleID` | Independent sequence from `location.csv`'s |
| `sessionTimeSeconds`, `systemMonotonicTime`, `utcTimestamp` | See 13.1 |
| `nativeHeadingTimestampUTC` | See 13.1 — `CLHeading`'s own reading time |
| `magneticHeading` | Degrees, 0..<360, 0 = magnetic north, increasing clockwise. Negative = invalid |
| `trueHeading` | Degrees, 0..<360, corrected for magnetic declination using the current location. Negative = invalid — commonly the case for the first few headings before any location fix has arrived, since true heading needs one to compute declination |
| `headingAccuracy` | Degrees. Negative = invalid |

### 13.4 Why two files instead of one

`location.csv` and `heading.csv` are both "Core Location," but GPS fixes and
compass headings are delivered by separate `CLLocationManagerDelegate`
callbacks (`didUpdateLocations` / `didUpdateHeading`) at independent rates —
heading typically updates much faster than GPS. Forcing them into one file
would mean either duplicating GPS rows for every heading update or leaving
half the columns empty on most rows; two files with their own `sampleID`
sequences (matching how `motion.csv` is already separate from `frames.csv`)
avoids that ambiguity entirely.
