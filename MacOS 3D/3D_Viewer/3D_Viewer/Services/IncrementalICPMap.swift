import Foundation
import simd

/// A coarse voxel-downsampled point map, used as the ICP reference/"model"
/// that each new frame is aligned against. One representative (running
/// average) point per occupied voxel keeps its size bounded by scanned
/// volume rather than by point count, so lookups stay fast even after
/// merging hundreds of frames.
private struct VoxelMap {
    let voxelSize: Float
    private var points: [UInt64: SIMD3<Float>] = [:]
    private var counts: [UInt64: Int32] = [:]

    /// Keeps voxel indices non-negative before packing, comfortably covering
    /// room/building-scale extents (±31,000 voxels per axis at this offset).
    private static let axisOffset: Int32 = 1 << 15

    init(voxelSize: Float) {
        self.voxelSize = voxelSize
    }

    var isEmpty: Bool { points.isEmpty }

    private func packedKey(_ p: SIMD3<Float>) -> (UInt64, Int32, Int32, Int32) {
        let ix = Int32((p.x / voxelSize).rounded(.down))
        let iy = Int32((p.y / voxelSize).rounded(.down))
        let iz = Int32((p.z / voxelSize).rounded(.down))
        return (Self.pack(ix, iy, iz), ix, iy, iz)
    }

    private static func pack(_ ix: Int32, _ iy: Int32, _ iz: Int32) -> UInt64 {
        let ux = UInt64(ix + axisOffset)
        let uy = UInt64(iy + axisOffset)
        let uz = UInt64(iz + axisOffset)
        return ux | (uy << 21) | (uz << 42)
    }

    mutating func insert(_ p: SIMD3<Float>) {
        let (key, _, _, _) = packedKey(p)
        if let c = counts[key] {
            let n = Float(c)
            points[key] = (points[key]! * n + p) / (n + 1)
            counts[key] = c + 1
        } else {
            points[key] = p
            counts[key] = 1
        }
    }

    /// Nearest map point within `maxDist` of `p`, searching the 3x3x3 block
    /// of voxels centered on `p`'s own voxel.
    func nearest(to p: SIMD3<Float>, maxDist: Float) -> SIMD3<Float>? {
        let (_, ix, iy, iz) = packedKey(p)
        var best: SIMD3<Float>?
        var bestDistSq = maxDist * maxDist
        for dx in Int32(-1)...Int32(1) {
            for dy in Int32(-1)...Int32(1) {
                for dz in Int32(-1)...Int32(1) {
                    guard let candidate = points[Self.pack(ix + dx, iy + dy, iz + dz)] else { continue }
                    let d = simd_distance_squared(candidate, p)
                    if d < bestDistSq {
                        bestDistSq = d
                        best = candidate
                    }
                }
            }
        }
        return best
    }
}

/// Incrementally aligns each new frame's points against everything inserted
/// so far, using a bounded number of ICP (Iterative Closest Point)
/// iterations. This is what actually corrects small ARKit pose-drift errors
/// between frames — filtering bad points (confidence/edge) removes noise,
/// but only re-aligning frames against the accumulated model corrects
/// *where* a frame's geometry was placed in the first place.
final class IncrementalICPMap {
    private var map: VoxelMap
    private let maxIterations: Int
    private let correspondenceThreshold: Float
    private let minCorrespondenceCount: Int
    private let minCorrespondenceFraction: Float
    private let maxTranslationCorrection: Float
    private let maxRotationCorrectionRadians: Float
    private let sourceSampleTarget = 2000
    private let insertSampleTarget = 5000

    /// Number of frames that found enough overlap to be corrected, vs. that
    /// were left uncorrected (first frame, or genuinely new/unvisited area).
    private(set) var correctedFrameCount = 0
    private(set) var uncorrectedFrameCount = 0

    init(
        voxelSize: Float = 0.03,
        maxIterations: Int = 8,
        correspondenceThreshold: Float = 0.12,
        minCorrespondenceCount: Int = 40,
        minCorrespondenceFraction: Float = 0.15,
        maxTranslationCorrection: Float = 0.6,
        maxRotationCorrectionDegrees: Float = 20
    ) {
        self.map = VoxelMap(voxelSize: voxelSize)
        self.maxIterations = maxIterations
        self.correspondenceThreshold = correspondenceThreshold
        self.minCorrespondenceCount = minCorrespondenceCount
        self.minCorrespondenceFraction = minCorrespondenceFraction
        self.maxTranslationCorrection = maxTranslationCorrection
        self.maxRotationCorrectionRadians = maxRotationCorrectionDegrees * .pi / 180
    }

    /// Finds the rigid correction that best aligns `points` (already in
    /// world space via the frame's own ARKit transform) with the
    /// accumulated map, or nil if there isn't enough trustworthy overlap —
    /// callers should fall back to the frame's original, uncorrected pose
    /// rather than apply a implausible/underdetermined correction.
    func align(_ points: [SIMD3<Float>]) -> (rotation: simd_quatf, translation: SIMD3<Float>)? {
        guard !map.isEmpty, !points.isEmpty else {
            uncorrectedFrameCount += 1
            return nil
        }

        let sample = Self.subsample(points, target: sourceSampleTarget)
        var current = sample
        var totalRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        var totalTranslation = SIMD3<Float>(repeating: 0)
        var lastCorrespondenceCount = 0

        for _ in 0..<maxIterations {
            var src: [SIMD3<Float>] = []
            var tgt: [SIMD3<Float>] = []
            src.reserveCapacity(current.count)
            tgt.reserveCapacity(current.count)
            for p in current {
                if let n = map.nearest(to: p, maxDist: correspondenceThreshold) {
                    src.append(p)
                    tgt.append(n)
                }
            }
            lastCorrespondenceCount = src.count
            guard src.count >= minCorrespondenceCount,
                  Float(src.count) / Float(sample.count) >= minCorrespondenceFraction,
                  let fit = RigidAlignment.fit(source: src, target: tgt)
            else { break }

            current = current.map { fit.rotation.act($0) + fit.translation }
            totalRotation = simd_normalize(fit.rotation * totalRotation)
            totalTranslation = fit.rotation.act(totalTranslation) + fit.translation
        }

        guard lastCorrespondenceCount >= minCorrespondenceCount else {
            uncorrectedFrameCount += 1
            return nil
        }
        let angle = 2 * acos(min(1, max(-1, abs(totalRotation.real))))
        guard simd_length(totalTranslation) <= maxTranslationCorrection, angle <= maxRotationCorrectionRadians else {
            // A correction this large almost certainly means we matched
            // against the wrong part of the map (e.g. a symmetric-looking
            // surface) rather than genuinely reconciling drift — trust the
            // original ARKit pose instead of a spurious "fix".
            uncorrectedFrameCount += 1
            return nil
        }
        correctedFrameCount += 1
        return (totalRotation, totalTranslation)
    }

    func insert(_ points: [SIMD3<Float>]) {
        for p in Self.subsample(points, target: insertSampleTarget) {
            map.insert(p)
        }
    }

    private static func subsample(_ points: [SIMD3<Float>], target: Int) -> [SIMD3<Float>] {
        guard points.count > target else { return points }
        let step = max(1, points.count / target)
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(target)
        var i = 0
        while i < points.count {
            out.append(points[i])
            i += step
        }
        return out
    }
}
