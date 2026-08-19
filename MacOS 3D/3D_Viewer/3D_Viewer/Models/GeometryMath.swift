import simd

/// Math matching SCIENTIFIC_DATA_FORMAT.md Section 3.1 (depth -> 3-D point)
/// and Section 5 (camera transform convention).
enum GeometryMath {
    /// Builds the camera->world matrix from a row-major, flattened 4x4
    /// array `[m11,m12,m13,m14, m21,..., m41,m42,m43,m44]` such that
    /// `world = M * [x_cam, y_cam, z_cam, 1]` (column vector on the right).
    static func worldFromCameraTransform(_ a: [Float]) -> simd_float4x4 {
        precondition(a.count == 16, "transform must have 16 elements")
        let col0 = SIMD4<Float>(a[0], a[4], a[8], a[12])
        let col1 = SIMD4<Float>(a[1], a[5], a[9], a[13])
        let col2 = SIMD4<Float>(a[2], a[6], a[10], a[14])
        let col3 = SIMD4<Float>(a[3], a[7], a[11], a[15])
        return simd_float4x4(col0, col1, col2, col3)
    }

    /// Camera position (translation component) of a camera->world transform.
    static func cameraPosition(_ a: [Float]) -> SIMD3<Float> {
        SIMD3<Float>(a[3], a[7], a[11])
    }

    struct Intrinsics {
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
    }

    /// Reads `fx, cx, fy, cy` out of a row-major, flattened 3x3
    /// `[fx,0,cx, 0,fy,cy, 0,0,1]` array.
    static func intrinsics(_ a: [Float]) -> Intrinsics {
        precondition(a.count == 9, "intrinsics must have 9 elements")
        return Intrinsics(fx: a[0], fy: a[4], cx: a[2], cy: a[5])
    }

    /// Back-projects a depth-map pixel `(u, v)` with depth `d` (meters) into
    /// ARKit world coordinates, using that depth frame's own scaled
    /// intrinsics and its paired camera transform.
    static func worldPoint(
        u: Int, v: Int, depth: Float,
        intrinsics k: Intrinsics,
        worldFromCamera: simd_float4x4
    ) -> SIMD3<Float> {
        let xCam = (Float(u) - k.cx) * depth / k.fx
        let yCam = (Float(v) - k.cy) * depth / k.fy
        let zCam = depth
        let camPoint = SIMD4<Float>(xCam, yCam, zCam, 1)
        let worldPoint = worldFromCamera * camPoint
        return SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
    }
}
