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

    /// Point-to-plane ICP step: minimizes, over a small rotation+translation
    /// [omega; t] (omega as an axis-angle vector, R ~ I + [omega]x), the
    /// squared distance from each source point to the *plane* through its
    /// target correspondence (not to the target point itself). This is the
    /// standard fix for point-to-point Horn alignment being under-constrained
    /// on flat surfaces: a point can slide freely along a wall and still look
    /// like a perfect point-to-point match, so that ambiguity never gets
    /// resolved. Point-to-plane only penalizes the normal-direction
    /// component of the residual, which is exactly the "how far off the
    /// surface" error that actually matters for drift correction.
    ///
    /// Solves the 6x6 linearized normal-equations system (Low, 2004,
    /// "Linear Least-Squares Optimization for Point-to-Plane ICP Surface
    /// Registration") via Gauss-Jordan elimination — no external
    /// linear-algebra dependency needed for a system this small.
    static func fitPointToPlane(
        source: [SIMD3<Float>], target: [SIMD3<Float>], targetNormals: [SIMD3<Float>]
    ) -> (rotation: simd_quatf, translation: SIMD3<Float>)? {
        guard source.count == target.count, target.count == targetNormals.count, source.count >= 6 else { return nil }

        var ata = [Float](repeating: 0, count: 36) // 6x6, row-major
        var atb = [Float](repeating: 0, count: 6)

        for i in 0..<source.count {
            let p = source[i]
            let n = targetNormals[i]
            let c = simd_cross(p, n)
            let a: [Float] = [c.x, c.y, c.z, n.x, n.y, n.z]
            let b = simd_dot(n, target[i] - p)
            for r in 0..<6 {
                atb[r] += a[r] * b
                let ar = a[r]
                guard ar != 0 else { continue }
                for col in 0..<6 { ata[r * 6 + col] += ar * a[col] }
            }
        }

        guard let x = solveSymmetric6x6(ata, atb) else { return nil }

        let omega = SIMD3<Float>(x[0], x[1], x[2])
        let translation = SIMD3<Float>(x[3], x[4], x[5])
        let angle = simd_length(omega)
        let rotation = angle < 1e-8
            ? simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            : simd_quatf(angle: angle, axis: omega / angle)
        return (rotation, translation)
    }

    /// Gauss-Jordan elimination with partial pivoting for a 6x6 system.
    /// Returns nil if the system is (near-)singular — e.g. correspondences
    /// too few or too coplanar/collinear to constrain all 6 degrees of freedom.
    private static func solveSymmetric6x6(_ a: [Float], _ b: [Float]) -> [Float]? {
        let n = 6
        var m = a
        var rhs = b
        for col in 0..<n {
            var pivotRow = col
            var maxVal = abs(m[col * n + col])
            for r in (col + 1)..<n {
                let v = abs(m[r * n + col])
                if v > maxVal { maxVal = v; pivotRow = r }
            }
            guard maxVal > 1e-9 else { return nil }
            if pivotRow != col {
                for c in 0..<n { m.swapAt(col * n + c, pivotRow * n + c) }
                rhs.swapAt(col, pivotRow)
            }
            let pivot = m[col * n + col]
            for r in 0..<n where r != col {
                let factor = m[r * n + col] / pivot
                if factor == 0 { continue }
                for c in 0..<n { m[r * n + c] -= factor * m[col * n + c] }
                rhs[r] -= factor * rhs[col]
            }
        }
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = rhs[i] / m[i * n + i] }
        return x
    }
}
