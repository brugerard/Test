import Foundation

// MARK: - metadata.json

struct RecordingConfiguration: Codable {
    var rgbFormat: String = "HEIC"
    var rgbCaptureRateHz: Double
    /// "continuous" (auto-capture throttled to rgbCaptureRateHz) or "manual"
    /// (only operator-triggered captures — rgbCaptureRateHz is then
    /// meaningless and should be ignored when interpreting this session).
    var captureMode: String = "continuous"
    var depthFormat: String = "Float32 little-endian raw binary (.bin) + JSON sidecar"
    var depthType: String = "raw_sceneDepth"
    var confidenceFormat: String = "UInt8 raw binary (.bin), ARConfidenceLevel raw values (0=low,1=medium,2=high), same width/height as depth"
}

struct SensorAvailability: Codable {
    var camera: Bool
    var lidarSceneDepth: Bool
}

struct FrameCounts: Codable {
    var rgbFramesWritten: Int
    var depthFramesWritten: Int
}

struct SessionMetadata: Codable {
    var appVersion: String
    var sessionID: String
    var sessionStartUTC: String
    var sessionEndUTC: String?
    var deviceHardwareIdentifier: String
    var systemVersion: String
    var recordingConfiguration: RecordingConfiguration
    var coordinateSystems: [String: String]
    var units: [String: String]
    var sensorAvailability: SensorAvailability
    var frameCounts: FrameCounts?
    var droppedFrames: Int?
    var diskWriteErrors: Int?
    var notes: String

    static func coordinateSystemDescriptions() -> [String: String] {
        [
            "arKitWorld": "Right-handed, gravity-aligned (+Y up, opposite gravity), meters. Origin is wherever the device was when this session's ARSession started tracking — not geographic, resets every session.",
            "arKitCamera": "Right-handed, camera-relative: +X right, +Y up, +Z out of the screen toward the user (camera looks down -Z). The per-frame 4x4 transform maps camera coordinates to arKitWorld coordinates.",
            "imagePixels": "Origin top-left, +X right, +Y down, in pixels of the saved RGB image at its captured (unrescaled) resolution.",
            "depthPixels": "Origin top-left, +X right, +Y down, in pixels of the depth map, which is a lower resolution than the RGB image. Use the depth frame's own scaled intrinsics, not the RGB frame's, to back-project depth pixels.",
            "wgs84": "Geographic latitude/longitude, decimal degrees (added in Phase 4).",
        ]
    }

    static func unitDescriptions() -> [String: String] {
        [
            "distance": "meters",
            "angle": "radians",
            "pressure": "kilopascals",
            "time": "seconds",
        ]
    }
}

// MARK: - depth/depth_NNNNNN.json

struct DepthFrameMetadata: Codable {
    let depthFrameID: Int
    let sessionTimeSeconds: Double
    let systemMonotonicTime: Double
    let utcTimestamp: String
    let nativeSensorTimestamp: Double
    let width: Int
    let height: Int
    let dataType: String
    let byteOrder: String
    let units: String
    let depthType: String
    let hasConfidence: Bool
    /// Row-major 3x3 intrinsics, SCALED to this depth map's resolution — see `intrinsicsNote`.
    let intrinsics: [Float]
    let intrinsicsNote: String
    /// Row-major 4x4 ARKit world<-camera transform, identical to the paired RGB
    /// frame's transform since both come from the same `ARFrame`.
    let transform: [Float]
    let correspondingRGBFrameID: Int
}

// MARK: - sensors/frames.csv

struct FrameCSVRow {
    let frameID: Int
    let sessionTimeSeconds: TimeInterval
    let systemMonotonicTime: TimeInterval
    let utcTimestamp: Date
    let nativeSensorTimestamp: TimeInterval
    let imageWidth: Int
    let imageHeight: Int
    let orientation: String
    /// Row-major 3x3 intrinsics, at the RGB image's own (unscaled) resolution.
    let intrinsics: [Float]
    /// Row-major 4x4 ARKit world<-camera transform.
    let transform: [Float]
    let trackingState: String
    let correspondingDepthFrameID: Int?

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let csvHeader = [
        "frameID", "sessionTimeSeconds", "systemMonotonicTime", "utcTimestamp", "nativeSensorTimestamp",
        "imageWidth", "imageHeight", "orientation",
        "intrinsics_m11", "intrinsics_m12", "intrinsics_m13",
        "intrinsics_m21", "intrinsics_m22", "intrinsics_m23",
        "intrinsics_m31", "intrinsics_m32", "intrinsics_m33",
        "transform_m11", "transform_m12", "transform_m13", "transform_m14",
        "transform_m21", "transform_m22", "transform_m23", "transform_m24",
        "transform_m31", "transform_m32", "transform_m33", "transform_m34",
        "transform_m41", "transform_m42", "transform_m43", "transform_m44",
        "trackingState", "correspondingDepthFrameID",
    ].joined(separator: ",")

    func csvLine() -> String {
        var fields: [String] = []
        fields.append(String(frameID))
        fields.append(String(format: "%.6f", sessionTimeSeconds))
        fields.append(String(format: "%.6f", systemMonotonicTime))
        fields.append(Self.isoFormatter.string(from: utcTimestamp))
        fields.append(String(format: "%.6f", nativeSensorTimestamp))
        fields.append(String(imageWidth))
        fields.append(String(imageHeight))
        fields.append(orientation)
        fields.append(contentsOf: intrinsics.map { String(format: "%.6f", $0) })
        fields.append(contentsOf: transform.map { String(format: "%.6f", $0) })
        fields.append(trackingState)
        fields.append(correspondingDepthFrameID.map(String.init) ?? "")
        return fields.joined(separator: ",")
    }
}
