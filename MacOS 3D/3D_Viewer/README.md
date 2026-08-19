# 3D_Viewer

A macOS SwiftUI app that opens a session recorded by **BG_Sensing** (the
companion iPhone LiDAR/RGB-D capture app) and renders it as a 3-D point
cloud, so you can inspect a scan on your Mac without writing any analysis
code. It implements exactly the back-projection math and file layout
described in that project's `SCIENTIFIC_DATA_FORMAT.md`.

## What it does

- Open a `Session_<datetime>_<uuid8>/` folder (drag-and-drop-free — uses the
  system folder picker) and it:
  - Parses `metadata.json` and `sensors/frames.csv`.
  - Reads every `depth/depth_NNNNNN.bin` + `.json` pair, back-projects each
    depth pixel to a 3-D point in ARKit world coordinates using that frame's
    own scaled intrinsics and camera transform (Section 3.1/5 of the format
    doc), and optionally samples the paired `rgb/frame_NNNNNN.heic` image to
    color each point.
- View a single frame's point cloud, or merge every frame in the session
  into one cloud (frames already share one consistent world coordinate
  system, so this "just works" for a walk-around scan).
- Color points by sampled RGB, raw depth (heat gradient), world height, or
  LiDAR confidence.
- Adjust pixel stride (density vs. build speed), point size, and toggle the
  camera-position trajectory line.
- Orbit/pan/zoom with the trackpad (SceneKit's built-in camera controller).

## Project layout

```
project.yml                Xcode project spec (see "Building" below)
3D_Viewer/
  App/ViewerApp.swift       App entry point
  Models/
    SessionModels.swift      Session/frame/metadata Codable types
    GeometryMath.swift        Row-major transform/intrinsics -> simd, back-projection
    ColorMode.swift            Color modes + a small heat colormap
  Services/
    SessionLoader.swift        Parses a session folder into a Session
    PointCloudBuilder.swift    Depth .bin + confidence + RGB -> point cloud
    RGBImageSampler.swift      Decodes HEIC/JPEG once for fast pixel sampling
  Views/
    ContentView.swift          Sidebar controls + scene host
    PointCloudSceneView.swift  NSViewRepresentable wrapping SCNView
```

## Building and running

You need a Mac with Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) — the `.xcodeproj` is generated, not committed
(same reasoning as the BG_Sensing iOS project: it's a derived artifact).

```
xcodegen generate && open 3D_Viewer.xcodeproj
```

Then select the `3D_Viewer` target, set your own Team under **Signing &
Capabilities** (the entitlements only request read-only access to a
user-picked folder — no network, no full-disk access), and press **Run**.

**XcodeGen version note**: on XcodeGen 2.46, the `info:` key requires an
explicit `path:` even when only `properties:` are used to generate the
Info.plist from scratch — omitting it fails with `Decoding failed at
"path": Nothing found` at parse time, before any generation step runs. This
`project.yml` sets `path: Generated-Info.plist` for that reason (also
`.gitignore`d, since it's regenerated every time).

## Getting a session onto your Mac

Sessions live in BG_Sensing's `Documents/Sessions/` on the iPhone. Since
that app sets `UIFileSharingEnabled`, you can copy a session folder off the
phone via Finder (device › BG_Sensing) or AirDrop, then open it here with
**Open Session Folder…**.

## Coordinate/format assumptions

This viewer trusts `SCIENTIFIC_DATA_FORMAT.md` as authoritative: raw
`sceneDepth` in meters, row-major transforms/intrinsics, depth pixels
mapped to RGB pixels by the same resolution ratio the depth intrinsics were
scaled by (no rotation — both streams are stored in ARKit's unrotated
landscape-sensor orientation). If that document's format changes, this
app's `SessionModels`/`GeometryMath`/`PointCloudBuilder` need to change with
it.
