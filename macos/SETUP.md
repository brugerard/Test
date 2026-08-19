# BG_Viewer — macOS Companion App

A point-cloud viewer for BG_Sensing recording sessions (the iPhone app in
`../ios`). Reads an exported `Session_.../` folder, back-projects every
depth frame to 3-D, places each frame in ARKit world space using its own
camera transform, colors points from the paired RGB photo, and renders the
combined cloud with orbit/pan/zoom.

**Status: v1.** Loads a whole session at once into one static point cloud.
No timeline scrubbing, no mesh reconstruction, no export yet — see "Ideas
for later" at the bottom.

## Setup

Same XcodeGen approach as the iOS project:

```bash
brew install xcodegen   # once, if you don't already have it (you do, from the iOS setup)
cd macos
xcodegen generate
open BG_Viewer.xcodeproj
```

In Xcode: select the `BG_Viewer` target → **Signing & Capabilities** → pick
your team (Automatic signing) — same as the iOS app. Then **Run** (▶️). This
is a plain Mac app; no physical device or special hardware needed to run
the viewer itself (obviously the *recordings* it visualizes come from the
iPhone app).

## How to use it

1. Get a session folder onto your Mac — e.g. via BG_Sensing's "Share Last
   Session" → AirDrop (see `../ios/SETUP.md`), then unzip it.
2. In BG_Viewer, click **Open Session…** and select the unzipped
   `Session_.../` folder (the one directly containing `metadata.json`,
   `rgb/`, `depth/`, `sensors/`).
3. It loads in the background (a progress spinner shows) and then renders.
   **Drag to orbit, scroll/pinch to zoom, right-drag (or two-finger drag)
   to pan** — standard SceneKit `allowsCameraControl` behavior.
4. If a session is dense/long and loading feels slow, increase **Pixel
   stride** and/or **Frame stride** before reopening — these keep a
   1-in-N subset of depth pixels/frames respectively, trading density for
   speed. Reopen the same folder to reload at the new strides.

## What to verify first

Load the session you already validated by hand (the one with the frame
count / depth min-mean-max you checked earlier) and confirm:

- The cloud roughly resembles the room/objects you pointed the phone at.
- Points from different frames of the same static scene overlap
  reasonably rather than forming obviously duplicated, offset copies of
  the room (a good sanity check that the world-space transform math is
  right, not just the depth/intrinsics math).
- Colors look like real colors from the scene, not scrambled/mirrored
  (this would indicate an RGB-to-depth pixel-mapping or a vertical-flip
  bug in `PointCloudBuilder.loadRGBPixels`).
- Nothing appears mirrored or rendered from "inside out"/behind the
  camera (this would indicate the camera-space sign convention — see
  `../ios/SCIENTIFIC_DATA_FORMAT.md` §3.1 — is wrong).

**This is a first pass I haven't been able to compile-check** (no
Xcode/macOS in the session that wrote it). If Xcode reports errors, the
`SCNGeometrySource`/`SCNGeometryElement` point-cloud construction in
`Services/PointCloudGeometryBuilder.swift` is the area I'd bet on first —
it's the least common of the APIs used here. Paste any errors and I'll fix
them the same way as the iOS app's build issues.

## Ideas for later (not built yet)

- Load a specific frame range / scrub through the recording over time
  instead of one static merged cloud.
- Export the merged cloud as `.ply` (a natural pairing with the iOS app's
  own deferred "Future capabilities" list in its
  `SCIENTIFIC_DATA_FORMAT.md`).
- Proper point-cloud fusion/denoising instead of naively pooling every
  frame's points (currently points from imperfect ARKit tracking across
  frames will show some visible drift/doubling rather than a clean
  surface).
- A session browser (open the whole `Sessions/` folder, pick from a list)
  instead of picking one session folder at a time.
