# BG_Sensing — Xcode Project Setup (Phase 1)

There is no `.xcodeproj` committed to this repo — it's a generated artifact
(see "Why generated, not committed" below). Generate it with **XcodeGen**
from `ios/project.yml`, which takes one command.

## 1. Install XcodeGen (once)

```
brew install xcodegen
```

(Requires Homebrew. See https://github.com/yonaskolb/XcodeGen if you don't
use Homebrew.)

## 2. Generate the project

```
cd ios
xcodegen generate
```

This reads `project.yml` and the `BG_Sensing/` source folder (already in
the repo) and produces `BG_Sensing.xcodeproj`, wired up with:
- all Swift files under `BG_Sensing/App`, `Views`, `Services`, `Models`
- `BG_Sensing/Info.plist` as the app's Info.plist (camera usage
  description + `UIRequiredDeviceCapabilities: [arkit]` already set)
- `BG_Sensing/Assets.xcassets/AppIcon.appiconset` as the app icon
- deployment target iOS 16.0, iPhone-only, automatic code signing
- a default `BG_Sensing` scheme, ready to run

## 3. Open on your Mac

```
cd ios
xcodegen generate && open BG_Sensing.xcodeproj
```

That's the one command to run in Terminal once you have this repo checked
out locally (`git pull` first if you haven't already). It regenerates the
project (picking up any changes) and opens it in Xcode.

## 4. Sign

In Xcode: select the `BG_Sensing` target → **Signing & Capabilities** →
pick your Apple ID/team under "Team" (Automatic signing). `project.yml`
doesn't hardcode a team, since that's specific to your Apple Developer
account.

## 5. Run destination

**Run on the physical iPhone 14 Pro, not the Simulator.** The Simulator has
no camera and no LiDAR — `ARWorldTrackingConfiguration` will report scene
depth as unsupported and the camera preview will be blank at best. Connect
the iPhone, select it as the run destination, press Run. On first launch,
iOS will prompt for camera permission — allow it.

## App icon

`BG_Sensing/Assets.xcassets/AppIcon.appiconset/AppIcon.png` is a single
1024×1024 source image (a radar/sensor-pulse mark: crosshair + glowing
center pulse + three colored nodes for camera/LiDAR/GPS fusion, on a dark
scientific-grid background). It uses Xcode 14+'s "single size" app icon
format — Xcode generates every smaller size it needs from this one PNG
automatically, so there's nothing else to add. If you want a different
design later, just replace that PNG (must stay 1024×1024, no alpha/transparency)
and re-run `xcodegen generate`.

## Why generated, not committed

`.xcodeproj` is really a directory of XML/plist files keyed by opaque
UUIDs. Hand-editing or hand-writing one outside Xcode is error-prone and
easy to corrupt, and this session has no Xcode/macOS to generate or verify
one directly. XcodeGen's `project.yml` is plain, diffable text — safe for
me to edit as new phases add files (new manager classes, new Info.plist
keys, new capabilities) — and running `xcodegen generate` regenerates a
correct `.xcodeproj` from it deterministically. `ios/.gitignore` excludes
the generated project so it can never go stale relative to `project.yml` or
cause merge conflicts.

**Regenerate after pulling changes**: any time you pull an update from me
that adds/removes source files or changes `project.yml`/`Info.plist`,
re-run `xcodegen generate` before building.

## Fallback: manual project creation (skip if XcodeGen worked)

If you'd rather not install XcodeGen, you can wrap the same source files in
a project by hand:

1. Xcode → **File → New → Project… → iOS → App**. Product Name
   `BG_Sensing`, Interface **SwiftUI**, Language **Swift**. Uncheck Core
   Data / Include Tests. Save it inside `ios/`.
2. Delete Xcode's generated `ContentView.swift` / `BG_SensingApp.swift`.
3. Right-click the `BG_Sensing` group → **Add Files to "BG_Sensing"…**
   and add the existing `App/`, `Views/`, `Services/`, `Models/`,
   `Assets.xcassets/` folders from the repo (Create groups, target
   checkbox ticked).
4. Target → **Info** tab → add **Privacy - Camera Usage Description**
   (`NSCameraUsageDescription`) and **Required device capabilities**
   (`UIRequiredDeviceCapabilities` = `[arkit]`) — values are in
   `BG_Sensing/Info.plist` if you want to copy them verbatim.
5. Target → **General** tab → App Icons and Launch Images → set App Icon
   Source to `AppIcon` (from the added asset catalog).
6. Set deployment target iOS 16.0 and your signing team.

## What to test on the iPhone (Phase 1)

1. The app launches and shows a **live camera feed** filling the screen.
2. The status overlay top-left shows:
   - **LiDAR / Scene Depth Supported**: green (iPhone 14 Pro has LiDAR).
   - **Scene Depth Active**: green.
   - **Tracking**: should settle to `Normal` after a second or two of moving
     the phone slightly (ARKit needs a bit of motion/visual texture to
     initialize).
   - **AR frames received**: should be climbing continuously.
   - **Depth (m)**: min/mean/max should update continuously and report
     plausible values (e.g. mean depth roughly matching the distance from
     the phone to whatever it's pointed at, min not close to 0 unless
     something is right against the lens).
3. Point the phone at a nearby object vs. a far wall and confirm the mean
   depth value changes accordingly — this is the sanity check that scene
   depth is real, live LiDAR data and not a stale/placeholder buffer.
4. Confirm the app icon (radar/pulse mark) shows correctly on the Home
   Screen after install.

## Next phase

Once you've confirmed the above on the physical device, Phase 2 adds actual
recording: writing RGB frames + full-resolution depth maps + intrinsics/pose
to disk. Let me know how the Phase 1 test goes (and paste any Xcode compiler
errors) and I'll proceed.
