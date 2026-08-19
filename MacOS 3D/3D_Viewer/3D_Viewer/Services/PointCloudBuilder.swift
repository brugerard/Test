import Foundation
import simd

struct PointCloudBuildOptions {
    /// Sample every Nth pixel in both dimensions (1 = full resolution).
    var stride: Int = 2
    var colorMode: ColorMode = .rgb
    /// Depth values (meters) outside this range are dropped as invalid.
    var validDepthRange: ClosedRange<Float> = 0.1...8.0
    /// Only used when `colorMode == .confidence` is unavailable, or as a
    /// hard filter when the caller sets it below `.low`.
    var minConfidence: UInt8 = 0 // 0 = low, 1 = medium, 2 = high
    /// Normalization range for the depth-gradient colormap, meters.
    var depthColorRange: ClosedRange<Float> = 0.2...5.0
    /// Normalization range for the height colormap, meters (world Y).
    var heightColorRange: ClosedRange<Float> = -1.5...1.5
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
            buildUnpooled(frame: frame, options: options, into: &result)
        }
    }

    private static func buildUnpooled(frame: DepthFrame, options: PointCloudBuildOptions, into result: inout PointCloudData) {
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

        result.cameraTrajectory.append(GeometryMath.cameraPosition(info.transform))

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

                let worldPoint = GeometryMath.worldPoint(
                    u: u, v: v, depth: d, intrinsics: k, worldFromCamera: worldFromCamera
                )

                let color: SIMD4<Float>
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
                    color = Colormap.heat(normalized(worldPoint.y, in: options.heightColorRange))
                case .confidence:
                    color = Colormap.confidence(confidence ?? 2)
                }

                result.positions.append(worldPoint)
                result.colors.append(color)
            }
        }
    }

    private static func normalized(_ value: Float, in range: ClosedRange<Float>) -> Float {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}
