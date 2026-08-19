# PhoneSensors — Xcode Project Setup (Phase 1)

There is no `.xcodeproj` in this repo yet — Xcode project files are a
macOS/Xcode artifact and this session has no Xcode to generate one correctly.
The Swift source files are written and organized already; you just need to
wrap them in an Xcode project shell. This takes about 5 minutes.

## 1. Create the project

1. Open Xcode → **File → New → Project…**
2. Choose **iOS → App**, click Next.
3. Product Name: `PhoneSensors`
   Interface: **SwiftUI**
   Language: **Swift**
   Uncheck "Use Core Data" and "Include Tests" (not needed for the MVP).
4. Save it **inside `ios/`** in this repo, i.e. so the generated
   `PhoneSensors.xcodeproj` sits at `ios/PhoneSensors.xcodeproj` next to the
   `PhoneSensors/` source folder already in the repo. Xcode will create its
   own `PhoneSensors/` folder with a default `ContentView.swift` and
   `PhoneSensorsApp.swift` — that's fine, you'll replace them next.

## 2. Replace the generated files with the repo's source

1. In Finder/Xcode, **delete** the Xcode-generated `ContentView.swift` and
   `PhoneSensorsApp.swift` (move to trash — they're placeholders).
2. In Xcode's project navigator, right-click the `PhoneSensors` group →
   **Add Files to "PhoneSensors"…**, and add the folders already in this
   repo:
   - `ios/PhoneSensors/App/PhoneSensorsApp.swift`
   - `ios/PhoneSensors/Views/ContentView.swift`
   - `ios/PhoneSensors/Views/ARCameraPreviewView.swift`
   - `ios/PhoneSensors/Services/ARCaptureManager.swift`
   - `ios/PhoneSensors/Models/` (currently empty — a placeholder for later phases; Xcode will let you create an empty group instead if it won't add an empty folder)

   Use "Create groups" (not folder references) and make sure the
   `PhoneSensors` app target's checkbox is ticked for each file.

## 3. Permissions (Info.plist)

Xcode 15+ projects manage `Info.plist` via build settings by default (no
physical file). The easiest path:

1. Select the `PhoneSensors` target → **Info** tab.
2. Under "Custom iOS Target Properties", add:
   - **Privacy - Camera Usage Description** (`NSCameraUsageDescription`) =
     `This app uses the camera together with ARKit to record RGB imagery and LiDAR depth for scientific data collection.`
   - **Required device capabilities** (`UIRequiredDeviceCapabilities`) → array
     with one item: `arkit`

   (`ios/PhoneSensors/Info.plist` in the repo has these same keys as a
   reference/backup if you prefer to use an explicit Info.plist file instead
   — set `GENERATE_INFOPLIST_FILE = NO` and point `INFOPLIST_FILE` at it.)

3. Location and Motion usage descriptions are **not** needed yet — they'll be
   added in Phases 4 and 3 respectively. Don't add them prematurely.

## 4. Build settings

- **Deployment target**: iOS 16.0 (matches iPhone 14 Pro's shipped OS; scene
  depth itself only requires iOS 14+, but 16 is a safe modern floor).
- **Signing**: set your Apple ID / team under Signing & Capabilities so you
  can deploy to your physical iPhone.

## 5. Run destination

**You must run on the physical iPhone 14 Pro, not the Simulator.** The
Simulator has no camera and no LiDAR — `ARWorldTrackingConfiguration` will
report scene depth as unsupported and the camera preview will be blank at
best. Connect the iPhone, select it as the run destination, and press Run.
On first launch, iOS will prompt for camera permission — allow it.

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

## Next phase

Once you've confirmed the above on the physical device, Phase 2 adds actual
recording: writing RGB frames + full-resolution depth maps + intrinsics/pose
to disk. Let me know how the Phase 1 test goes (and paste any Xcode compiler
errors) and I'll proceed.
