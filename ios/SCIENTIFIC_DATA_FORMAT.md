# PhoneSensors — Scientific Data Format

This document describes the on-disk data format produced by the PhoneSensors
iOS app, so that a researcher who receives only an exported recording session
plus this document can interpret the dataset correctly without the app.

**Status: Phase 1 only.** No recording/export exists yet — this document will
grow with each phase (see `SETUP.md` for the phase plan) and must stay in sync
with the code. Sections below are marked `[Phase N]` to show when they become
accurate.

## 1. Overview

The app acquires RGB imagery, LiDAR depth, motion, GPS, and barometric data
from an iPhone simultaneously, and — starting in Phase 7 — saves each
recording as one self-contained "session" directory. Every measurement is
timestamped so streams can be synchronized during offline analysis; the app
does not attempt to force streams into artificial simultaneity.

## 2. Coordinate systems `[Phase 1 — ARKit conventions fixed now]`

Several distinct coordinate systems are involved. They are **not**
interchangeable and must not be confused:

| System | Description | Units |
|---|---|---|
| **ARKit world coordinates** | Right-handed coordinate system established when the AR session starts tracking (`ARWorldTrackingConfiguration`, `worldAlignment = .gravity`). With gravity alignment: +Y points up (opposite gravity), and the X/Z plane is horizontal. The origin is wherever the device was when tracking began — it is **not** geographic and resets every session. | meters |
| **ARKit camera coordinates** | Right-handed, camera-relative: +X right, +Y up, +Z out of the screen toward the user (i.e. the camera looks down -Z). The camera transform (Section 5) maps camera coordinates into world coordinates. | meters |
| **Image pixel coordinates** | Origin top-left, +X right, +Y down, in pixels of the captured RGB image at its *captured* resolution (Phase 2 will not rescale images). | pixels |
| **Depth-map coordinates** | Origin top-left, +X right, +Y down, in pixels of the depth map, which is typically lower resolution than the RGB image. Phase 2's metadata will record the depth map's own width/height and how it corresponds to the RGB frame. | pixels |
| **Device coordinates** | Core Motion's reference frame for attitude/acceleration/rotation, relative to the device casing, not the camera. Documented in full in Phase 3. | — |
| **Geographic WGS84** | Latitude/longitude from Core Location. | decimal degrees |
| **Mean-sea-level (MSL) altitude** | GPS-derived altitude as reported by Core Location (`CLLocation.altitude`), which on iOS is referenced to mean sea level, not the WGS84 ellipsoid. | meters |
| **WGS84 ellipsoidal altitude** | Height above the WGS84 ellipsoid, if/when exposed distinctly from MSL altitude. Documented fully in Phase 4 once implemented. | meters |
| **Relative barometric altitude** | `CMAltimeter`'s relative altitude, referenced to wherever the barometer session started (device power-on / app session start) — **not** sea level and **not** GPS altitude. Documented fully in Phase 5. | meters |

GPS altitude and barometric altitude are always stored as separate fields.
They are never combined or used to correct one another.

### 2.1 Depth pixel → 3-D point (reference for later phases)

Once Phase 2 lands, an external program can back-project a depth-map pixel
`(u, v)` with depth value `d` (meters, in the camera's local Z) into a 3-D
point in ARKit camera coordinates using the pinhole model and the frame's
camera intrinsics `K`:

```
x_cam = (u - cx) * d / fx
y_cam = (v - cy) * d / fy
z_cam = d
```

where `fx, fy, cx, cy` come from the saved 3x3 intrinsics matrix for that
frame. The camera-space point is then transformed into ARKit world
coordinates by multiplying with the frame's 4x4 camera transform matrix
(Section 5), which encodes the camera's position and orientation in world
space at capture time. This document will give the exact matrix layout and
a worked example once Phase 2 is implemented.

## 3. Timestamps `[Phase 1 — policy fixed now, fields land in Phase 6]`

Every measurement will carry multiple timestamp fields; none is treated as a
substitute for another:

1. **`sessionTimeSeconds`** — floating-point seconds since `t = 0`, defined as
   the moment START RECORDING is pressed. This is the common analysis
   timeline across all sensor streams.
2. **`systemMonotonicTime`** — the raw monotonic clock reading at the moment
   the measurement was captured/received (not wall-clock, immune to clock
   adjustments), used to derive `sessionTimeSeconds`.
3. **`utcTimestamp`** — wall-clock UTC date/time, for human reference and for
   correlating against external logs. Never used as the primary
   synchronization key because system clock adjustments can make it
   non-monotonic.
4. **`nativeSensorTimestamp`** — the timestamp the originating framework
   attaches to the sample, in its own time base, preserved as-is. For
   example, `ARFrame.timestamp` is seconds since the `ARSession` was started
   (its own monotonic domain, distinct from `systemMonotonicTime`); Core
   Motion samples carry their own `timestamp` (boot-relative); Core Location
   attaches its own `CLLocation.timestamp` (wall-clock, device-reported).

Where a sensor's native time base differs from the app's monotonic clock, the
exact mapping between them will be documented here when that sensor's phase
is implemented (Phase 3 for Core Motion, Phase 4 for Core Location). No
measurement's timestamp is ever fabricated or interpolated to "line up" with
another stream — true acquisition times are preserved so alignment can be
done deliberately during analysis.

## 4. Units and missing-data convention `[Phase 1]`

- Distances/altitudes: meters. Angles: radians unless noted. Pressure:
  kilopascals (`CMAltimeter`/`CMAltitudeData` native unit). Accuracy fields:
  same unit as the value they describe.
- A sensor that is unavailable, denied, or produced no reading for a given
  moment is represented by an explicit missing-data marker (`null` in JSON,
  empty field in CSV, or `NaN` for floating-point values that must remain
  numeric) — never by a fabricated zero. `sensorAvailability` in
  `metadata.json` (Phase 7) records which sensors were present for the whole
  session.

## 5. Camera pose / ARKit camera transform `[Phase 1 — semantics fixed, persisted in Phase 2]`

`ARFrame.camera.transform` is a 4x4, column-major matrix (`simd_float4x4`)
that maps ARKit camera-space coordinates to ARKit world-space coordinates.
When persisted (Phase 2), it will be written in full (all 16 values, row by
row: `m11..m14, m21..m24, m31..m34, m41..m44`) — never reduced to
pitch/roll/yaw — so that later 3-D reconstruction has the exact pose ARKit
used at capture time.

## 6. Phase 1 implementation notes

Phase 1 verifies, on-device, that:

- `ARSession` can be started with `ARWorldTrackingConfiguration`.
- The device's LiDAR-derived scene depth is available
  (`ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`) and,
  when available, is enabled via `configuration.frameSemantics.insert(.sceneDepth)`.
- Each `ARFrame.sceneDepth?.depthMap` is a `Float32` `CVPixelBuffer` in
  meters; the app samples it on a coarse grid purely to display live
  min/mean/max statistics as a sanity check. This sampling is a UI
  convenience only — it is **not** how depth will be recorded starting
  Phase 2, which persists the full-resolution buffer losslessly.

No files are written to disk yet in Phase 1.
