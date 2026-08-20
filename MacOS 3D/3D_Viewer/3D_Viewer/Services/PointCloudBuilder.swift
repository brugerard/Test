import Foundation
import simd

struct PointCloudBuildOptions {
    /// Sample every Nth pixel in both dimensions (1 = full resolution).
    var stride: Int = 2
    var colorMode: ColorMode = .rgb
    /// Depth values (meters) outside this range are dropped as invalid.
    var validDepthRange: ClosedRange<Float> = 0.1...8.0
    /// Points below this confidence are dropped. Measured across real
    /// captures, "low" (0) samples are 13-33% of all in-range depth pixels
    /// and disproportionately land on edges/reflective or distant surfaces
    /// where ARKit's own depth estimate is least trustworthy — including
    /// them by default reads as visual noise rather than real structure.
    var minConfidence: UInt8 = 1 // 0 = low, 1 = medium, 2 = high
    /// Normalization range for the depth-gradient colormap, meters.
    var depthColorRange: ClosedRange<Float> = 0.2...5.0
    /// Normalization range for the height colormap, meters (world Y).
    var heightColorRange: ClosedRange<Float> = -1.5...1.5
    /// Reject a pixel whose depth jumps by more than this from its
    /// immediate right/down neighbor — a "flying pixel" straddling a
    /// foreground/background edge, where the sensor's depth estimate is a
    /// blend of two different surfaces rather than a real point on either
    /// one. Measured on real captures, ~0.5-5% of pixels trip this at
    /// realistic thresholds, so it trims artifacts without gutting density.
    var edgeDiscontinuityThreshold: Float = 0.08
    /// Shade each point by the angle between its estimated local surface
    /// normal and the direction back to the frame's capturing camera (a
    /// "headlight"). Flat-shaded points are very hard to read as a 3-D
    /// surface versus a scattering of confetti; this is the single biggest
    /// lever for making the cloud look like a coherent object.
    var useNormalShading: Bool = true
    /// Skip a frame entirely if `motion.csv` recorded angular velocity above
    /// this (radians/second) within ~0.15s of its capture — a fast pan both
    /// motion-blurs the RGB shutter and degrades ARKit's own pose estimate
    /// for that instant. nil disables the filter (also a no-op for sessions
    /// that predate motion.csv, where every frame's rate is unknown).
    var maxRotationRateAtCapture: Float? = 1.5
    /// When merging multiple frames, re-align each new frame's points
    /// against everything merged so far (a bounded ICP pass) before adding
    /// it, correcting small ARKit pose-drift errors between frames rather
    /// than just filtering per-point noise. Ignored for single-frame builds
    /// (there's nothing yet to align against).
    var useICPRefinement: Bool = true
}

struct PointCloudData {
    var positions: [SIMD3<Float>] = []
    var colors: [SIMD4<Float>] = []
    /// Camera center for each frame contributing to this cloud, in world
    /// coordinates, in frame order — used to draw the trajectory.
    var cameraTrajectory: [SIMD3<Float>] = []
}

enum PointCloudBuilder {
    /// Builds (and appends into `into`) the point cloud for one depth frame.
    ///
    /// Wrapped in `autoreleasepool` because RGB sampling decodes an HEIC
    /// image per call (via Core Graphics/ImageIO, which are Objective-C
    /// under the hood): merging hundreds of frames in one tight loop without
    /// draining the autorelease pool between frames was measured to hold
    /// every frame's decode temporaries alive simultaneously, pushing RSS
    /// into the multi-gigabyte range.
    static func build(frame: DepthFrame, options: PointCloudBuildOptions, into result: inout PointCloudData) {
        autoreleasepool {
            buildUnpooled(frame: frame, options: options, correction: nil, into: &result)
        }
    }

    /// Builds a whole session's merged point cloud, optionally re-aligning
    /// each frame against everything merged so far via `IncrementalICPMap`
    /// and skipping frames captured during fast device rotation. Frame order
    /// matters here (each frame aligns against the frames before it), unlike
    /// the plain per-frame `build`, so this owns its own loop rather than
    /// being called once per frame by `ContentView`.
    static func buildMergedSession(
        frames: [DepthFrame], options: PointCloudBuildOptions
    ) -> (data: PointCloudData, alignedFrameCount: Int, unalignedFrameCount: Int) {
        var result = PointCloudData()
        let icp = options.useICPRefinement ? IncrementalICPMap() : nil

        for frame in frames {
            if let maxRate = options.maxRotationRateAtCapture, let peak = frame.peakRotationRate, peak > maxRate {
                continue
            }
            autoreleasepool {
                let correction = icp.flatMap { map -> (rotation: simd_quatf, translation: SIMD3<Float>)? in
                    let sample = rawWorldSample(frame: frame, options: options, sampleStride: 6)
                    return map.align(sample)
                }
                let before = result.positions.count
                buildUnpooled(frame: frame, options: options, correction: correction, into: &result)
                icp?.insert(Array(result.positions[before...]))
            }
        }
        return (result, icp?.correctedFrameCount ?? 0, icp?.uncorrectedFrameCount ?? 0)
    }

    /// A fast, sparse pass producing only world-space positions (no color,
    /// no shading, no RGB decode) for ICP correspondence-finding — the same
    /// depth/confidence/edge filters as the full build, just without the
    /// expensive per-point extras that finding a rigid alignment doesn't need.
    private static func rawWorldSample(frame: DepthFrame, options: PointCloudBuildOptions, sampleStride: Int) -> [SIMD3<Float>] {
        let info = frame.info
        guard let depthData = try? Data(contentsOf: frame.binURL) else { return [] }
        let width = info.width
        let height = info.height
        let expectedCount = width * height
        guard depthData.count >= expectedCount * MemoryLayout<Float32>.size else { return [] }
        let depths: [Float32] = depthData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float32.self).prefix(expectedCount))
        }
        var confidences: [UInt8]?
        if let confURL = frame.confidenceURL, let confData = try? Data(contentsOf: confURL),
           confData.count >= expectedCount {
            confidences = confData.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: UInt8.self).prefix(expectedCount))
            }
        }
        let k = GeometryMath.intrinsics(info.intrinsics)
        let worldFromCamera = GeometryMath.worldFromCameraTransform(info.transform)
        let stride = max(1, sampleStride)

        var points: [SIMD3<Float>] = []
        for v in Swift.stride(from: 0, to: height, by: stride) {
            for u in Swift.stride(from: 0, to: width, by: stride) {
                let idx = v * width + u
                let d = depths[idx]
                guard d.isFinite, options.validDepthRange.contains(d) else { continue }
                if let c = confidences?[idx], c < options.minConfidence { continue }
                points.append(GeometryMath.worldPoint(u: u, v: v, depth: d, intrinsics: k, worldFromCamera: worldFromCamera))
            }
        }
        return points
    }

    private static func buildUnpooled(
        frame: DepthFrame,
        options: PointCloudBuildOptions,
        correction: (rotation: simd_quatf, translation: SIMD3<Float>)?,
        into result: inout PointCloudData
    ) {
        let info = frame.info
        guard let depthData = try? Data(contentsOf: frame.binURL) else { return }
        let width = info.width
        let height = info.height
        let expectedCount = width * height
        guard depthData.count >= expectedCount * MemoryLayout<Float32>.size else { return }

        let depths: [Float32] = depthData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float32.self).prefix(expectedCount))
        }

        var confidences: [UInt8]?
        if let confURL = frame.confidenceURL, let confData = try? Data(contentsOf: confURL),
           confData.count >= expectedCount {
            confidences = confData.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: UInt8.self).prefix(expectedCount))
            }
        }

        var rgbSampler: RGBImageSampler?
        var rgbScale: (x: Float, y: Float) = (1, 1)
        if options.colorMode == .rgb, let rgbURL = frame.rgbURL {
            // Nearest-sampling one color per depth pixel never needs more
            // resolution than the depth map itself, so decode a thumbnail
            // instead of the full RGB capture (see RGBImageSampler's doc).
            rgbSampler = RGBImageSampler(contentsOf: rgbURL, maxPixelSize: max(width, height))
            if let sampler = rgbSampler {
                rgbScale = (Float(sampler.width) / Float(width), Float(sampler.height) / Float(height))
            }
        }

        let k = GeometryMath.intrinsics(info.intrinsics)
        let worldFromCamera = GeometryMath.worldFromCameraTransform(info.transform)
        let cameraPos = GeometryMath.cameraPosition(info.transform)

        // Shading math below (surface normal vs. view direction) is computed
        // entirely in the frame's own raw/uncorrected space and stays valid
        // after `correction` is applied at the very end: correction is a
        // rigid transform (rotation + translation, no scale/shear), and the
        // angle between two vectors is unchanged when both are rotated
        // together. Only the final output position (and camera center, for
        // the trajectory) need the correction applied.
        @inline(__always) func corrected(_ p: SIMD3<Float>) -> SIMD3<Float> {
            guard let correction else { return p }
            return correction.rotation.act(p) + correction.translation
        }

        result.cameraTrajectory.append(corrected(cameraPos))

        @inline(__always) func depthAt(_ uu: Int, _ vv: Int) -> Float? {
            guard uu >= 0, uu < width, vv >= 0, vv < height else { return nil }
            let dd = depths[vv * width + uu]
            guard dd.isFinite, options.validDepthRange.contains(dd) else { return nil }
            return dd
        }

        @inline(__always) func worldAt(_ uu: Int, _ vv: Int, _ dd: Float) -> SIMD3<Float> {
            GeometryMath.worldPoint(u: uu, v: vv, depth: dd, intrinsics: k, worldFromCamera: worldFromCamera)
        }

        // Deliberately no reserveCapacity here: this function is called once
        // per frame while merging a session, and reserving only *this*
        // frame's increment on every call pins the array's capacity right at
        // its current size each time — defeating Swift's normal geometric
        // over-allocation and forcing a full reallocation+copy of the
        // (possibly many-million-element) accumulated array on almost every
        // subsequent frame, i.e. O(n^2) total copying across a merge. Plain
        // `append` already grows capacity geometrically and is amortized
        // O(1) per element across the whole merge.
        let stride = max(1, options.stride)

        for v in Swift.stride(from: 0, to: height, by: stride) {
            for u in Swift.stride(from: 0, to: width, by: stride) {
                let idx = v * width + u
                let d = depths[idx]
                guard d.isFinite, options.validDepthRange.contains(d) else { continue }

                let confidence = confidences?[idx]
                if let c = confidence, c < options.minConfidence { continue }

                // Flying-pixel rejection: a real neighbor (native resolution,
                // independent of `stride`) whose depth jumps too far means
                // this pixel sits on a foreground/background edge.
                let dRight = depthAt(u + 1, v)
                let dDown = depthAt(u, v + 1)
                if let dr = dRight, abs(dr - d) > options.edgeDiscontinuityThreshold { continue }
                if let dn = dDown, abs(dn - d) > options.edgeDiscontinuityThreshold { continue }

                let worldPoint = worldAt(u, v, d)

                var shadeFactor: Float = 1
                if options.useNormalShading {
                    var tangentX: SIMD3<Float>?
                    if let dr = dRight {
                        tangentX = worldAt(u + 1, v, dr) - worldPoint
                    } else if let dl = depthAt(u - 1, v), abs(dl - d) <= options.edgeDiscontinuityThreshold {
                        tangentX = worldPoint - worldAt(u - 1, v, dl)
                    }
                    var tangentY: SIMD3<Float>?
                    if let dn = dDown {
                        tangentY = worldAt(u, v + 1, dn) - worldPoint
                    } else if let du = depthAt(u, v - 1), abs(du - d) <= options.edgeDiscontinuityThreshold {
                        tangentY = worldPoint - worldAt(u, v - 1, du)
                    }
                    if let tx = tangentX, let ty = tangentY {
                        let n = simd_cross(tx, ty)
                        let nLenSq = simd_length_squared(n)
                        if nLenSq > 1e-12 {
                            let normal = n / nLenSq.squareRoot()
                            let viewDir = simd_normalize(cameraPos - worldPoint)
                            let nDotV = abs(simd_dot(normal, viewDir))
                            let ambient: Float = 0.35
                            shadeFactor = ambient + (1 - ambient) * nDotV
                        }
                    }
                }

                let outputPoint = corrected(worldPoint)

                var color: SIMD4<Float>
                switch options.colorMode {
                case .rgb:
                    if let sampler = rgbSampler {
                        let rx = Int((Float(u) + 0.5) * rgbScale.x)
                        let ry = Int((Float(v) + 0.5) * rgbScale.y)
                        color = sampler.sample(x: rx, y: ry) ?? Colormap.heat(
                            normalized(d, in: options.depthColorRange)
                        )
                    } else {
                        color = Colormap.heat(normalized(d, in: options.depthColorRange))
                    }
                case .depth:
                    color = Colormap.heat(normalized(d, in: options.depthColorRange))
                case .height:
                    color = Colormap.heat(normalized(outputPoint.y, in: options.heightColorRange))
                case .confidence:
                    color = Colormap.confidence(confidence ?? 2)
                }
                color = SIMD4<Float>(color.x * shadeFactor, color.y * shadeFactor, color.z * shadeFactor, color.w)

                result.positions.append(outputPoint)
                result.colors.append(color)
            }
        }
    }

    private static func normalized(_ value: Float, in range: ClosedRange<Float>) -> Float {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}
