import Foundation

/// Mirrors the JSON schema BG_Sensing (the iPhone app) writes to
/// `depth_NNNNNN.json` — see `ios/BG_Sensing/Models/SessionModels.swift`'s
/// `DepthFrameMetadata` and `ios/SCIENTIFIC_DATA_FORMAT.md` §7 for the
/// authoritative definition. Duplicated here rather than shared via a
/// cross-platform module to keep this viewer's build simple; keep the two
/// in sync if the phone app's depth JSON schema changes. Only the fields
/// this viewer actually needs are declared — `JSONDecoder` ignores the rest.
struct DepthFrameMirror: Codable {
    let width: Int
    let height: Int
    /// Row-major 3x3, already scaled to this depth map's resolution (fx, 0, cx, 0, fy, cy, 0, 0, 1).
    let intrinsics: [Float]
    /// Row-major 4x4, ARKit world<-camera transform.
    let transform: [Float]
    let correspondingRGBFrameID: Int
}
