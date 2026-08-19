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
    var motion: Bool
}

struct FrameCounts: Codable {
    var rgbFramesWritten: Int
    var depthFramesWritten: Int
    var motionSamplesWritten: Int
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
            "deviceMotion": "Apple's standard Core Motion device frame: with the device held in portrait, screen facing the user, +X points right, +Y points toward the top of the device, +Z points out of the screen toward the user. Independent of ARKit's camera/world frames — do not mix without an explicit transform.",
        ]
    }

    static func unitDescriptions() -> [String: String] {
        [
            "distance": "meters",
            "angle": "radians",
            "pressure": "kilopascals",
            "time": "seconds",
            "acceleration": "g (9.80665 m/s^2 per g) — Core Motion's native unit, NOT raw m/s^2",
            "rotationRate": "radians/second",
            "magneticField": "microtesla (uT)",
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

// MARK: - sensors/motion.csv

struct MotionCSVRow {
    let sampleID: Int
    let sessionTimeSeconds: TimeInterval
    let systemMonotonicTime: TimeInterval
    let utcTimestamp: Date
    let nativeSensorTimestamp: TimeInterval
    /// "xMagneticNorthZVertical" or "xArbitraryZVertical" — see
    /// `MotionSensorManager` and `SCIENTIFIC_DATA_FORMAT.md` §12 for what
    /// this does and doesn't mean for `yaw`.
    let attitudeReferenceFrame: String
    /// Radians.
    let roll: Double
    let pitch: Double
    let yaw: Double
    let quaternionX: Double
    let quaternionY: Double
    let quaternionZ: Double
    let quaternionW: Double
    /// Row-major 3x3, dimensionless.
    let rotationMatrix: [Double]
    /// Gravity-removed acceleration, in g. Never confuse with `gravity*` below.
    let userAccelerationX: Double
    let userAccelerationY: Double
    let userAccelerationZ: Double
    /// Direction/magnitude of gravity in the device frame, in g (magnitude ≈ 1.0).
    let gravityX: Double
    let gravityY: Double
    let gravityZ: Double
    /// Radians/second.
    let rotationRateX: Double
    let rotationRateY: Double
    let rotationRateZ: Double
    /// Microtesla.
    let magneticFieldX: Double
    let magneticFieldY: Double
    let magneticFieldZ: Double
    /// "uncalibrated" / "low" / "medium" / "high" — Core Motion's own compass
    /// calibration confidence, useful for filtering low-confidence samples.
    let magneticFieldCalibrationAccuracy: String

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let csvHeader = [
        "sampleID", "sessionTimeSeconds", "systemMonotonicTime", "utcTimestamp", "nativeSensorTimestamp",
        "attitudeReferenceFrame",
        "roll", "pitch", "yaw",
        "quaternionX", "quaternionY", "quaternionZ", "quaternionW",
        "rotationMatrix_m11", "rotationMatrix_m12", "rotationMatrix_m13",
        "rotationMatrix_m21", "rotationMatrix_m22", "rotationMatrix_m23",
        "rotationMatrix_m31", "rotationMatrix_m32", "rotationMatrix_m33",
        "userAccelerationX", "userAccelerationY", "userAccelerationZ",
        "gravityX", "gravityY", "gravityZ",
        "rotationRateX", "rotationRateY", "rotationRateZ",
        "magneticFieldX", "magneticFieldY", "magneticFieldZ", "magneticFieldCalibrationAccuracy",
    ].joined(separator: ",")

    func csvLine() -> String {
        var fields: [String] = []
        fields.append(String(sampleID))
        fields.append(String(format: "%.6f", sessionTimeSeconds))
        fields.append(String(format: "%.6f", systemMonotonicTime))
        fields.append(Self.isoFormatter.string(from: utcTimestamp))
        fields.append(String(format: "%.6f", nativeSensorTimestamp))
        fields.append(attitudeReferenceFrame)
        fields.append(String(format: "%.6f", roll))
        fields.append(String(format: "%.6f", pitch))
        fields.append(String(format: "%.6f", yaw))
        fields.append(String(format: "%.6f", quaternionX))
        fields.append(String(format: "%.6f", quaternionY))
        fields.append(String(format: "%.6f", quaternionZ))
        fields.append(String(format: "%.6f", quaternionW))
        fields.append(contentsOf: rotationMatrix.map { String(format: "%.6f", $0) })
        fields.append(String(format: "%.6f", userAccelerationX))
        fields.append(String(format: "%.6f", userAccelerationY))
        fields.append(String(format: "%.6f", userAccelerationZ))
        fields.append(String(format: "%.6f", gravityX))
        fields.append(String(format: "%.6f", gravityY))
        fields.append(String(format: "%.6f", gravityZ))
        fields.append(String(format: "%.6f", rotationRateX))
        fields.append(String(format: "%.6f", rotationRateY))
        fields.append(String(format: "%.6f", rotationRateZ))
        fields.append(String(format: "%.6f", magneticFieldX))
        fields.append(String(format: "%.6f", magneticFieldY))
        fields.append(String(format: "%.6f", magneticFieldZ))
        fields.append(magneticFieldCalibrationAccuracy)
        return fields.joined(separator: ",")
    }
}
