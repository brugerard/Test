import simd

/// Horn's closed-form method (Horn, 1987, "Closed-form solution of absolute
/// orientation using unit quaternions") for the rigid rotation+translation
/// that best maps a set of source points onto corresponding target points in
/// a least-squares sense. Used to snap each new frame's point cloud into
/// better alignment with everything captured so far (see
/// `IncrementalICPMap`), correcting small ARKit pose-drift errors between
/// frames without needing an external linear-algebra library.
enum RigidAlignment {
    /// Returns nil if there aren't enough correspondences to fit a rigid
    /// transform (need at least 3, non-degenerate).
    static func fit(source: [SIMD3<Float>], target: [SIMD3<Float>]) -> (rotation: simd_quatf, translation: SIMD3<Float>)? {
        guard source.count == target.count, source.count >= 3 else { return nil }
        let n = Float(source.count)

        var centroidSource = SIMD3<Float>(repeating: 0)
        var centroidTarget = SIMD3<Float>(repeating: 0)
        for i in 0..<source.count {
            centroidSource += source[i]
            centroidTarget += target[i]
        }
        centroidSource /= n
        centroidTarget /= n

        // Cross-covariance matrix S = sum(centered_source ⊗ centered_target).
        var sxx: Float = 0, sxy: Float = 0, sxz: Float = 0
        var syx: Float = 0, syy: Float = 0, syz: Float = 0
        var szx: Float = 0, szy: Float = 0, szz: Float = 0
        for i in 0..<source.count {
            let s = source[i] - centroidSource
            let t = target[i] - centroidTarget
            sxx += s.x * t.x; sxy += s.x * t.y; sxz += s.x * t.z
            syx += s.y * t.x; syy += s.y * t.y; syz += s.y * t.z
            szx += s.z * t.x; szy += s.z * t.y; szz += s.z * t.z
        }

        // Horn's 4x4 symmetric "key matrix" N. Its eigenvector for the
        // largest eigenvalue is the optimal rotation as a unit quaternion
        // (w, x, y, z) in that component order.
        var N = simd_float4x4(
            SIMD4<Float>(sxx + syy + szz, syz - szy, szx - sxz, sxy - syx),
            SIMD4<Float>(syz - szy, sxx - syy - szz, sxy + syx, szx + sxz),
            SIMD4<Float>(szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy),
            SIMD4<Float>(sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz)
        )

        // Shift so every eigenvalue becomes non-negative (Gershgorin bound:
        // sum of absolute row entries), which makes plain power iteration
        // converge to the eigenvector of N's largest (not most negative)
        // eigenvalue — avoiding a full eigendecomposition entirely.
        var shift: Float = 0
        for c in 0..<4 {
            let col = N[c]
            shift += abs(col.x) + abs(col.y) + abs(col.z) + abs(col.w)
        }
        N[0][0] += shift; N[1][1] += shift; N[2][2] += shift; N[3][3] += shift

        var v = SIMD4<Float>(1, 1, 1, 1)
        for _ in 0..<60 {
            let next = N * v
            let len = simd_length(next)
            guard len > 1e-12 else { break }
            v = next / len
        }

        let rotation = simd_normalize(simd_quatf(ix: v.y, iy: v.z, iz: v.w, r: v.x))
        let translation = centroidTarget - rotation.act(centroidSource)
        return (rotation, translation)
    }
}
