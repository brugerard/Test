import Foundation
import Combine
import ARKit

/// Depth statistics computed from a single ARKit scene-depth frame.
///
/// For Phase 1 this is a coarse, sampled summary used only to verify on-device
/// that LiDAR scene depth is being produced. Recording (Phase 2+) persists the
/// full Float32 depth map instead, via `ARFrameSnapshot` below.
struct DepthFrameStats {
    /// `ARFrame.timestamp`: seconds since device boot — the same monotonic clock
    /// domain as `CACurrentMediaTime()` / `ProcessInfo.processInfo.systemUptime`,
    /// and (per Apple's docs) the same domain Core Motion's sample timestamps use.
    /// It is NOT reset when the ARSession starts/restarts, and it is NOT wall-clock
    /// UTC time. `RecordingSessionManager` maps it onto the recording's own
    /// `sessionTimeSeconds` timeline by subtracting the boot-relative time captured
    /// at "START RECORDING".
    let timestamp: TimeInterval
    let width: Int
    let height: Int
    let minDepthMeters: Float
    let maxDepthMeters: Float
    let meanDepthMeters: Float
    let validSampleCount: Int
    let sampledCount: Int
}

/// Everything `RecordingSessionManager` needs from one `ARFrame`, extracted
/// synchronously in the session delegate callback so the manager never has to
/// retain the `ARFrame` itself (ARFrame instances are comparatively heavy —
/// holding onto them past their callback is a well-known source of memory
/// pressure in ARKit apps).
///
/// `@unchecked Sendable`: `CVPixelBuffer` is a Core Foundation type that is safe
/// to pass across threads for read-only use (which is all recording does with
/// it); the simd matrix types and `ARTrackingSummary` are plain value types.
struct ARFrameSnapshot: @unchecked Sendable {
    let nativeTimestamp: TimeInterval
    let capturedImage: CVPixelBuffer
    let imageWidth: Int
    let imageHeight: Int
    let intrinsics: simd_float3x3
    let cameraTransform: simd_float4x4
    let trackingSummary: ARTrackingSummary
    let depthMap: CVPixelBuffer?
    let confidenceMap: CVPixelBuffer?
    let depthWidth: Int
    let depthHeight: Int
}

/// Human-readable summary of `ARCamera.TrackingState`, safe to publish to SwiftUI.
enum ARTrackingSummary: String {
    case normal = "Normal"
    case notAvailable = "Not Available"
    case limitedInitializing = "Limited (Initializing)"
    case limitedRelocalizing = "Limited (Relocalizing)"
    case limitedExcessiveMotion = "Limited (Excessive Motion)"
    case limitedInsufficientFeatures = "Limited (Low Features)"
    case unknown = "Unknown"
}

/// Owns the `ARSession` and all AR acquisition logic: starting/stopping world
/// tracking with scene depth, reporting live tracking/depth status, and (from
/// Phase 2) handing each frame to whoever wants to record it.
///
/// SwiftUI views only read `@Published` state from this object; they never touch
/// ARKit types directly. ARSession delegate callbacks arrive on ARKit's own
/// background delegate queue, so depth-map sampling and `frameHandler` here
/// happen off the main thread; only the final published values (for the status
/// overlay) are marshalled back to the main thread. This deliberately keeps
/// ARCaptureManager ignorant of *whether* or *how* recording happens — it just
/// reports frames; `RecordingSessionManager` decides what to do with them.
final class ARCaptureManager: NSObject, ObservableObject {

    /// Shared session instance. `ARCameraPreviewView` binds an `ARSCNView` to this
    /// same session purely for rendering; it never calls `run`/`pause` itself.
    let session = ARSession()

    /// Invoked on ARKit's background delegate queue for every frame, regardless
    /// of recording state — `RecordingSessionManager` is responsible for deciding
    /// whether/how often to act on it. Must not block: do cheap work only, or
    /// hand off to something async (e.g. an actor).
    var frameHandler: ((ARFrameSnapshot) -> Void)?

    @Published private(set) var isSessionRunning = false
    @Published private(set) var isLiDARAvailable = false
    @Published private(set) var isSceneDepthActive = false
    @Published private(set) var trackingSummary: ARTrackingSummary = .unknown
    @Published private(set) var latestDepthStats: DepthFrameStats?
    @Published private(set) var lastError: String?
    @Published private(set) var frameCount: Int = 0

    /// Pixel stride used when sampling the depth map for live statistics.
    /// A full-resolution scan is unnecessary for a status readout and would
    /// cost CPU time on every AR frame; recorded depth (Phase 2) will not be
    /// subsampled like this.
    private let depthSampleStride = 16

    override init() {
        super.init()
        session.delegate = self
        isLiDARAvailable = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            lastError = "ARWorldTrackingConfiguration is not supported on this device."
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity

        let sceneDepthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        isLiDARAvailable = sceneDepthSupported
        if sceneDepthSupported {
            configuration.frameSemantics.insert(.sceneDepth)
            isSceneDepthActive = true
            lastError = nil
        } else {
            isSceneDepthActive = false
            lastError = "Scene depth (LiDAR) is not supported on this device. RGB-only acquisition will proceed."
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
    }

    func stop() {
        session.pause()
        isSessionRunning = false
    }
}

extension ARCaptureManager: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let stats = Self.computeDepthStats(from: frame, stride: depthSampleStride)
        let tracking = Self.summarize(frame.camera.trackingState)

        if let frameHandler {
            let depthMap = frame.sceneDepth?.depthMap
            let confidenceMap = frame.sceneDepth?.confidenceMap
            frameHandler(
                ARFrameSnapshot(
                    nativeTimestamp: frame.timestamp,
                    capturedImage: frame.capturedImage,
                    imageWidth: CVPixelBufferGetWidth(frame.capturedImage),
                    imageHeight: CVPixelBufferGetHeight(frame.capturedImage),
                    intrinsics: frame.camera.intrinsics,
                    cameraTransform: frame.camera.transform,
                    trackingSummary: tracking,
                    depthMap: depthMap,
                    confidenceMap: confidenceMap,
                    depthWidth: depthMap.map(CVPixelBufferGetWidth) ?? 0,
                    depthHeight: depthMap.map(CVPixelBufferGetHeight) ?? 0
                )
            )
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameCount += 1
            self.trackingSummary = tracking
            if let stats {
                self.latestDepthStats = stats
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = error.localizedDescription
            self?.isSessionRunning = false
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = "AR session was interrupted."
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = nil
        }
    }

    private static func summarize(_ state: ARCamera.TrackingState) -> ARTrackingSummary {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: return .limitedInitializing
            case .relocalizing: return .limitedRelocalizing
            case .excessiveMotion: return .limitedExcessiveMotion
            case .insufficientFeatures: return .limitedInsufficientFeatures
            @unknown default: return .unknown
            }
        }
    }

    /// Samples `frame.sceneDepth` (the raw, non-smoothed depth map, in meters) on a
    /// coarse grid and returns min/max/mean over valid (finite, positive) samples.
    /// Returns `nil` when no scene depth is available for this frame.
    private static func computeDepthStats(from frame: ARFrame, stride: Int) -> DepthFrameStats? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let pixelBuffer = sceneDepth.depthMap

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var minValue = Float.greatestFiniteMagnitude
        var maxValue = -Float.greatestFiniteMagnitude
        var sum: Double = 0
        var validCount = 0
        var sampledCount = 0

        var y = 0
        while y < height {
            let rowPointer = baseAddress
                .advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: Float32.self)
            var x = 0
            while x < width {
                let value = rowPointer[x]
                sampledCount += 1
                if value.isFinite && value > 0 {
                    minValue = Swift.min(minValue, value)
                    maxValue = Swift.max(maxValue, value)
                    sum += Double(value)
                    validCount += 1
                }
                x += stride
            }
            y += stride
        }

        guard validCount > 0 else {
            return DepthFrameStats(
                timestamp: frame.timestamp,
                width: width,
                height: height,
                minDepthMeters: .nan,
                maxDepthMeters: .nan,
                meanDepthMeters: .nan,
                validSampleCount: 0,
                sampledCount: sampledCount
            )
        }

        return DepthFrameStats(
            timestamp: frame.timestamp,
            width: width,
            height: height,
            minDepthMeters: minValue,
            maxDepthMeters: maxValue,
            meanDepthMeters: Float(sum / Double(validCount)),
            validSampleCount: validCount,
            sampledCount: sampledCount
        )
    }
}
