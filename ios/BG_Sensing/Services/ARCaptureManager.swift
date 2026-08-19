import Foundation
import Combine
import ARKit

/// Depth statistics computed from a single ARKit scene-depth frame.
///
/// For Phase 1 this is a coarse, sampled summary used only to verify on-device
/// that LiDAR scene depth is being produced. Later phases persist the full
/// Float32 depth map instead of these statistics.
struct DepthFrameStats {
    /// ARKit's frame timestamp: seconds since the ARSession started (`CACurrentMediaTime`
    /// domain). This is monotonic but is NOT wall-clock/UTC time. Phase 6 maps this onto
    /// the shared recording-session timeline defined at "START RECORDING".
    let timestamp: TimeInterval
    let width: Int
    let height: Int
    let minDepthMeters: Float
    let maxDepthMeters: Float
    let meanDepthMeters: Float
    let validSampleCount: Int
    let sampledCount: Int
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

/// Owns the `ARSession` and all AR acquisition logic for Phase 1: starting/stopping
/// world tracking with scene depth, and reporting live tracking/depth status.
///
/// SwiftUI views only read `@Published` state from this object; they never touch
/// ARKit types directly. ARSession delegate callbacks arrive on ARKit's own
/// background delegate queue, so depth-map sampling here happens off the main
/// thread; only the final published values are marshalled back to the main
/// thread for UI consumption.
final class ARCaptureManager: NSObject, ObservableObject {

    /// Shared session instance. `ARCameraPreviewView` binds an `ARSCNView` to this
    /// same session purely for rendering; it never calls `run`/`pause` itself.
    let session = ARSession()

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
