import Foundation

/// One row of `sensors/frames.csv`, per the BG_Sensing scientific data format
/// (SCIENTIFIC_DATA_FORMAT.md, Section 6).
struct FrameRecord: Identifiable {
    let frameID: Int
    let sessionTimeSeconds: Double
    let imageWidth: Int
    let imageHeight: Int
    let orientation: String
    /// Row-major 3x3, flattened: [fx,0,cx, 0,fy,cy, 0,0,1].
    let intrinsics: [Float]
    /// Row-major 4x4 ARKit camera->world transform, flattened.
    let transform: [Float]
    let trackingState: String
    let correspondingDepthFrameID: Int?

    var id: Int { frameID }
}

/// Sidecar `depth/depth_NNNNNN.json`, per Section 7.
struct DepthFrameInfo: Decodable {
    let depthFrameID: Int
    let sessionTimeSeconds: Double
    let width: Int
    let height: Int
    let dataType: String
    let byteOrder: String
    let units: String
    let hasConfidence: Bool
    let intrinsics: [Float]
    let transform: [Float]
    let correspondingRGBFrameID: Int?
}

/// A resolved depth frame: its metadata plus the paths needed to load the
/// raw binary payloads and, if present, the paired RGB image.
struct DepthFrame: Identifiable {
    let info: DepthFrameInfo
    let binURL: URL
    let confidenceURL: URL?
    let rgbURL: URL?
    let rgbImageSize: (width: Int, height: Int)?
    /// Peak angular velocity magnitude (radians/second) from `motion.csv`
    /// within a small window around this frame's capture time, or nil if
    /// the session predates that file. See `MotionSample`.
    let peakRotationRate: Float?

    var id: Int { info.depthFrameID }
}

/// Minimal subset of `metadata.json` (Section 9) needed for a summary panel.
struct SessionMetadata: Decodable {
    struct RecordingConfiguration: Decodable {
        let rgbFormat: String?
        let rgbCaptureRateHz: Double?
        let depthFormat: String?
        let depthType: String?
        let confidenceFormat: String?
    }
    struct SensorAvailability: Decodable {
        let camera: Bool?
        let lidarSceneDepth: Bool?
    }
    struct FrameCounts: Decodable {
        let rgbFramesWritten: Int?
        let depthFramesWritten: Int?
    }

    let sessionID: String?
    let deviceHardwareIdentifier: String?
    let systemVersion: String?
    let sessionStartUTC: String?
    let sessionEndUTC: String?
    let recordingConfiguration: RecordingConfiguration?
    let sensorAvailability: SensorAvailability?
    let frameCounts: FrameCounts?
}

/// A loaded BG_Sensing session: its directory plus every frame pair found.
struct Session: Identifiable {
    let id = UUID()
    let directoryURL: URL
    let metadata: SessionMetadata?
    let depthFrames: [DepthFrame]

    var displayName: String { directoryURL.lastPathComponent }
}
