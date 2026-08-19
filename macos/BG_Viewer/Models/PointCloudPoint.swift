/// One reconstructed 3-D point, already in ARKit world-space coordinates
/// (Section 2/3 of `ios/SCIENTIFIC_DATA_FORMAT.md`), with a color sampled
/// from the paired RGB frame.
struct PointCloudPoint {
    let position: SIMD3<Float>
    /// 0...1 per channel.
    let color: SIMD3<Float>
}
