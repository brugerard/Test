# BG_Sensing — Xcode Project Setup

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
- an Xcode-generated Info.plist (see "Info.plist" below) with the camera
  usage description already set
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

**If you're re-running this after a previous build crashed or behaved oddly**,
also do a clean rebuild once (stale derived data can mask project.yml
changes): in Xcode, **Product → Clean Build Folder** (⇧⌘K), and delete the
app from your iPhone before reinstalling.

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

## Info.plist

There's no physical `Info.plist` file in the source tree. The target uses
`GENERATE_INFOPLIST_FILE: YES` with `INFOPLIST_KEY_*` build settings in
`project.yml` — this is Xcode's own default mechanism for new projects
(Xcode 13+), and is what actually gets the camera usage description
correctly baked into the built app. (An earlier version of this project
used an explicit `Info.plist` file wired up via XcodeGen's `info.path`;
that silently failed to carry `NSCameraUsageDescription` into the build on
at least one XcodeGen setup, causing an immediate launch-time crash with no
permission prompt. The build-setting approach avoids that file-linking step
entirely.) To see or change Info.plist values, edit the
`INFOPLIST_KEY_*` entries directly in `project.yml`, or use Xcode's target →
**Info** tab after generating — either one is reflected in the build.

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
that adds/removes source files or changes `project.yml`, re-run
`xcodegen generate` before building.

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
   (`NSCameraUsageDescription`) = "This app uses the camera together with
   ARKit to record RGB imagery and LiDAR depth for scientific data
   collection."
5. Target → **General** tab → App Icons and Launch Images → set App Icon
   Source to `AppIcon` (from the added asset catalog).
6. Set deployment target iOS 16.0 and your signing team.

## What to test on the iPhone

### Phase 1 (camera/LiDAR preview — should still work)

1. The app launches and shows a **live camera feed** filling the screen.
2. The status overlay top-left shows:
   - **LiDAR / Scene Depth Supported**: green (iPhone 14 Pro has LiDAR).
   - **Scene Depth Active**: green.
   - **Tracking**: should settle to `Normal` after a second or two of moving
     the phone slightly (ARKit needs a bit of motion/visual texture to
     initialize).
   - **AR frames received**: should be climbing continuously.
   - **Depth (m)**: min/mean/max should update continuously and report
     plausible values.
3. Point the phone at a nearby object vs. a far wall and confirm the mean
   depth value changes accordingly.
4. Confirm the app icon (radar/pulse mark) shows correctly on the Home
   Screen after install.

### Phase 2 (recording)

1. Tap **START RECORDING** (large green button at the bottom). It should
   turn into a red **STOP RECORDING** button, and a "● RECORDING" health
   panel should appear showing elapsed time, RGB/depth frame counts ticking
   up (roughly 5/second), dropped-frame count, and disk-error count (both
   should stay at 0 in normal conditions).
2. Move the phone around for 15–30 seconds — walk to a different part of the
   room, point at objects at different distances — then tap **STOP
   RECORDING**.
3. **Verify the files exist and read back correctly.** With the iPhone
   connected to your Mac: open **Finder → your iPhone → Files → BG_Sensing**
   (file sharing is enabled specifically so you can do this without
   building the Phase 7 export feature first). You should see
   `Sessions/Session_<date>_<uuid>/` with `metadata.json`, `rgb/`, `depth/`,
   `sensors/frames.csv` inside. Drag that session folder to your Mac.
4. Quick read-back check (needs Python 3 + numpy: `pip3 install numpy` if
   you don't have it) — run from the folder containing the session:
   ```bash
   python3 - "Session_<date>_<uuid>/depth/depth_000001.json" "Session_<date>_<uuid>/depth/depth_000001.bin" <<'EOF'
   import json, sys, numpy as np
   meta_path, bin_path = sys.argv[1], sys.argv[2]
   meta = json.load(open(meta_path))
   arr = np.fromfile(bin_path, dtype="<f4").reshape(meta["height"], meta["width"])
   print("shape:", arr.shape, "dtype:", arr.dtype)
   print("min/mean/max (m):", np.nanmin(arr), np.nanmean(arr), np.nanmax(arr))
   print("intrinsics:", meta["intrinsics"])
   EOF
   ```
   This should print a sensible shape (e.g. `(192, 256)`) and depth values
   in a plausible range for whatever the camera was pointed at when that
   frame was captured. Also open `rgb/frame_000001.heic` in Preview to
   confirm it's a real (if sideways — see the orientation note in
   `SCIENTIFIC_DATA_FORMAT.md` §6) photo, and skim `sensors/frames.csv` and
   `metadata.json` in a text editor.
5. Try recording again without force-quitting the app in between — confirm
   a second, distinct session folder is created and the frame counters reset
   to 0 at the start of the new recording.
6. **Keep the phone unlocked and the app in the foreground for the whole
   test.** ARKit does not permit camera/GPU work while backgrounded — if you
   lock the phone or switch apps mid-recording, the app now stops the
   recording and pauses the AR session cleanly (rather than repeatedly
   failing to encode frames, which is what happened before this was added).
   That's expected behavior, not a bug: start a fresh recording after
   returning to the app.

## Next phase

Once you've confirmed both of the above on the physical device, Phase 3
adds Core Motion (attitude, acceleration, gyroscope, magnetometer at
~50 Hz). Let me know how the Phase 2 test goes (and paste any Xcode
compiler errors) and I'll proceed.
