import simd

/// Matrix-flattening and intrinsics-scaling helpers shared by anything that
/// writes camera geometry to disk. Kept free of ARKit types so it's testable
/// and reusable independent of how the matrices were obtained.
enum GeometryUtilities {

    /// Flattens a 4x4 transform into row-major order: `[m11,m12,m13,m14, m21,m22,m23,m24, ...]`.
    /// `simd_float4x4` stores matrices column-major (`.columns.0` is column 0),
    /// so row `i`, column `j` of the mathematical matrix is `columns[j][i]`.
    static func rowMajor(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x,
            m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y,
            m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z,
            m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w,
        ]
    }

    /// Flattens a 3x3 intrinsics matrix into row-major order: `[fx, 0, cx, 0, fy, cy, 0, 0, 1]`.
    static func rowMajor(_ m: simd_float3x3) -> [Float] {
        [
            m.columns.0.x, m.columns.1.x, m.columns.2.x,
            m.columns.0.y, m.columns.1.y, m.columns.2.y,
            m.columns.0.z, m.columns.1.z, m.columns.2.z,
        ]
    }

    /// Scales a row-major 3x3 camera intrinsics matrix `[fx 0 cx; 0 fy cy; 0 0 1]`
    /// from the resolution it was calibrated for to a different resolution —
    /// specifically, ARKit's `camera.intrinsics` are calibrated for the RGB
    /// image resolution, but the LiDAR depth map is a different (lower)
    /// resolution, so its intrinsics must be scaled before use. Using the
    /// RGB frame's intrinsics directly on depth-map pixel coordinates gives
    /// wrong 3-D back-projections.
    static func scaledIntrinsics(_ rowMajor3x3: [Float], scaleX: Float, scaleY: Float) -> [Float] {
        precondition(rowMajor3x3.count == 9, "Expected a flattened 3x3 matrix (9 values)")
        var m = rowMajor3x3
        m[0] *= scaleX   // fx
        m[2] *= scaleX   // cx
        m[4] *= scaleY   // fy
        m[5] *= scaleY   // cy
        return m
    }
}
