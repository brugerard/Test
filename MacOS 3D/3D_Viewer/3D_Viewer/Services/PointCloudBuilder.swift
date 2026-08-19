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
    static func build(frame: DepthFrame, options: PointCloudBuildOptions, into result: inout PointCloudData) {
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
            rgbSampler = RGBImageSampler(contentsOf: rgbURL)
            if let sampler = rgbSampler {
                rgbScale = (Float(sampler.width) / Float(width), Float(sampler.height) / Float(height))
            }
        }

        let k = GeometryMath.intrinsics(info.intrinsics)
        let worldFromCamera = GeometryMath.worldFromCameraTransform(info.transform)

        result.cameraTrajectory.append(GeometryMath.cameraPosition(info.transform))

        let stride = max(1, options.stride)
        result.positions.reserveCapacity(result.positions.count + (width / stride) * (height / stride))
        result.colors.reserveCapacity(result.colors.count + (width / stride) * (height / stride))

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
