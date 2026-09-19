import Foundation

/// One row of `sensors/motion.csv` (Core Motion device-motion stream), when
/// present — older sessions predate this file and simply won't have one.
struct MotionSample {
    let sessionTimeSeconds: Double
    let rotationRateX: Float
    let rotationRateY: Float
    let rotationRateZ: Float

    /// Magnitude of angular velocity, radians/second — a proxy for motion
    /// blur / tracking-quality risk at the moment of capture (a fast pan
    /// smears both the RGB shutter and ARKit's own pose estimate).
    var rotationRateMagnitude: Float {
        (rotationRateX * rotationRateX + rotationRateY * rotationRateY + rotationRateZ * rotationRateZ).squareRoot()
    }
}
