import Foundation
import CoreMotion
import Combine

/// Which attitude reference frame Core Motion is using for `yaw`. Chosen
/// once at `start()` based on device support.
enum MotionAttitudeReferenceFrame: String {
    /// `yaw` is relative to magnetic north, uncalibrated for declination.
    /// This is NOT the same as `CLHeading`'s magnetic/true heading (Phase 4)
    /// — it's a coarser, location-independent proxy. No location permission
    /// is required for this reference frame (unlike `.xTrueNorthZVertical`,
    /// which needs location services and isn't used here).
    case magneticNorth = "xMagneticNorthZVertical"
    /// `yaw` is relative to wherever the device was pointed when motion
    /// updates started — not tied to any compass direction at all. Used only
    /// as a fallback if the device can't provide a magnetic-north frame.
    case arbitrary = "xArbitraryZVertical"
}

/// One Core Motion device-motion sample, extracted synchronously in the
/// update handler so `RecordingSessionManager` never touches `CMDeviceMotion`
/// directly.
struct MotionSample {
    /// Boot-relative — same clock domain as `ARFrame.timestamp`.
    let nativeTimestamp: TimeInterval
    let referenceFrame: MotionAttitudeReferenceFrame
    let roll: Double
    let pitch: Double
    let yaw: Double
    let quaternionX: Double
    let quaternionY: Double
    let quaternionZ: Double
    let quaternionW: Double
    /// Row-major 3x3.
    let rotationMatrix: [Double]
    let userAccelerationX: Double
    let userAccelerationY: Double
    let userAccelerationZ: Double
    let gravityX: Double
    let gravityY: Double
    let gravityZ: Double
    let rotationRateX: Double
    let rotationRateY: Double
    let rotationRateZ: Double
    let magneticFieldX: Double
    let magneticFieldY: Double
    let magneticFieldZ: Double
    let magneticFieldCalibrationAccuracy: String
}

/// Owns `CMMotionManager` and reports live device-motion status. Mirrors
/// `ARCaptureManager`'s shape: runs continuously once started (so the status
/// panel can show live tilt/orientation even when not recording), and emits
/// every sample via `sampleHandler` regardless of recording state —
/// `RecordingSessionManager` decides whether to persist it.
final class MotionSensorManager: ObservableObject {

    /// Invoked on the motion update queue (background) for every sample.
    /// Must not block.
    var sampleHandler: ((MotionSample) -> Void)?

    @Published private(set) var isMotionAvailable = false
    @Published private(set) var isUpdating = false
    @Published private(set) var referenceFrame: MotionAttitudeReferenceFrame = .arbitrary
    @Published private(set) var latestSample: MotionSample?
    @Published private(set) var lastError: String?

    private let motionManager = CMMotionManager()
    private let updateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.brugerard.bgsensing.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init() {
        isMotionAvailable = motionManager.isDeviceMotionAvailable
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            lastError = "Device motion is not available on this device."
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }

        let availableFrames = CMMotionManager.availableAttitudeReferenceFrames()
        let cmFrame: CMAttitudeReferenceFrame
        if availableFrames.contains(.xMagneticNorthZVertical) {
            cmFrame = .xMagneticNorthZVertical
            referenceFrame = .magneticNorth
        } else {
            cmFrame = .xArbitraryZVertical
            referenceFrame = .arbitrary
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
        lastError = nil

        motionManager.startDeviceMotionUpdates(using: cmFrame, to: updateQueue) { [weak self] motion, error in
            guard let self else { return }

            if let error {
                DispatchQueue.main.async { self.lastError = error.localizedDescription }
                return
            }
            guard let motion else { return }

            let sample = Self.makeSample(from: motion, referenceFrame: self.referenceFrame)
            self.sampleHandler?(sample)

            DispatchQueue.main.async {
                self.latestSample = sample
            }
        }

        isUpdating = true
    }

    func stop() {
        guard motionManager.isDeviceMotionActive else { return }
        motionManager.stopDeviceMotionUpdates()
        isUpdating = false
    }

    private static func makeSample(from motion: CMDeviceMotion, referenceFrame: MotionAttitudeReferenceFrame) -> MotionSample {
        let attitude = motion.attitude
        let quaternion = attitude.quaternion
        let rotationMatrix = attitude.rotationMatrix
        let userAcceleration = motion.userAcceleration
        let gravity = motion.gravity
        let rotationRate = motion.rotationRate
        let magneticField = motion.magneticField

        return MotionSample(
            nativeTimestamp: motion.timestamp,
            referenceFrame: referenceFrame,
            roll: attitude.roll,
            pitch: attitude.pitch,
            yaw: attitude.yaw,
            quaternionX: quaternion.x,
            quaternionY: quaternion.y,
            quaternionZ: quaternion.z,
            quaternionW: quaternion.w,
            rotationMatrix: [
                rotationMatrix.m11, rotationMatrix.m12, rotationMatrix.m13,
                rotationMatrix.m21, rotationMatrix.m22, rotationMatrix.m23,
                rotationMatrix.m31, rotationMatrix.m32, rotationMatrix.m33,
            ],
            userAccelerationX: userAcceleration.x,
            userAccelerationY: userAcceleration.y,
            userAccelerationZ: userAcceleration.z,
            gravityX: gravity.x,
            gravityY: gravity.y,
            gravityZ: gravity.z,
            rotationRateX: rotationRate.x,
            rotationRateY: rotationRate.y,
            rotationRateZ: rotationRate.z,
            magneticFieldX: magneticField.field.x,
            magneticFieldY: magneticField.field.y,
            magneticFieldZ: magneticField.field.z,
            magneticFieldCalibrationAccuracy: Self.accuracyLabel(magneticField.accuracy)
        )
    }

    private static func accuracyLabel(_ accuracy: CMMagneticFieldCalibrationAccuracy) -> String {
        switch accuracy {
        case .uncalibrated: return "uncalibrated"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        @unknown default: return "unknown"
        }
    }
}
