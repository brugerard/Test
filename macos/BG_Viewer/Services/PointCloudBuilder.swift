import Foundation
import CoreGraphics
import ImageIO

enum PointCloudLoadError: Error, LocalizedError {
    case noDepthFiles
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .noDepthFiles:
            return "No depth_*.json files found in this folder's depth/ subfolder. Select a BG_Sensing Session_... folder."
        case .unreadableFile(let name):
            return "Could not read or parse \(name)."
        }
    }
}

/// Reconstructs a combined, world-space point cloud from a BG_Sensing
/// recording session: every depth frame is back-projected to 3-D, placed in
/// ARKit world space using that frame's own camera transform (so frames line
/// up with each other — see `ios/SCIENTIFIC_DATA_FORMAT.md` §3.1), and
/// colored by sampling the paired RGB image.
enum PointCloudBuilder {

    /// - Parameters:
    ///   - pixelStride: keep 1-in-N depth pixels per frame in each dimension.
    ///   - frameStride: keep 1-in-N depth frames. Both exist purely to keep
    ///     this MVP viewer responsive on long/dense sessions — set to 1 for
    ///     full density.
    static func loadSession(at sessionURL: URL, pixelStride: Int = 2, frameStride: Int = 1) throws -> [PointCloudPoint] {
        let depthDirectoryURL = sessionURL.appendingPathComponent("depth", isDirectory: true)
        let rgbDirectoryURL = sessionURL.appendingPathComponent("rgb", isDirectory: true)

        guard let allDepthFiles = try? FileManager.default.contentsOfDirectory(at: depthDirectoryURL, includingPropertiesForKeys: nil) else {
            throw PointCloudLoadError.noDepthFiles
        }

        let jsonURLs = allDepthFiles
            .filter { $0.lastPathComponent.hasPrefix("depth_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !jsonURLs.isEmpty else {
            throw PointCloudLoadError.noDepthFiles
        }

        let effectivePixelStride = max(pixelStride, 1)
        let effectiveFrameStride = max(frameStride, 1)

        var points: [PointCloudPoint] = []

        for (frameOffset, jsonURL) in jsonURLs.enumerated() {
            guard frameOffset % effectiveFrameStride == 0 else { continue }

            guard
                let jsonData = try? Data(contentsOf: jsonURL),
                let meta = try? JSONDecoder().decode(DepthFrameMirror.self, from: jsonData)
            else { continue }

            let binURL = depthDirectoryURL.appendingPathComponent(jsonURL.deletingPathExtension().lastPathComponent + ".bin")
            guard let depthValues = try? loadDepthValues(binURL: binURL, width: meta.width, height: meta.height) else {
                continue
            }

            let rgbFrameIDString = String(format: "%06d", meta.correspondingRGBFrameID)
            let rgbURL = rgbDirectoryURL.appendingPathComponent("frame_\(rgbFrameIDString).heic")
            let rgbPixels = try? loadRGBPixels(url: rgbURL)

            appendPoints(
                from: depthValues,
                meta: meta,
                rgbPixels: rgbPixels,
                pixelStride: effectivePixelStride,
                into: &points
            )
        }

        return points
    }

    private static func appendPoints(
        from depthValues: [Float],
        meta: DepthFrameMirror,
        rgbPixels: (data: [UInt8], width: Int, height: Int)?,
        pixelStride: Int,
        into points: inout [PointCloudPoint]
    ) {
        guard meta.intrinsics.count == 9, meta.transform.count == 16 else { return }

        let fx = meta.intrinsics[0], cx = meta.intrinsics[2]
        let fy = meta.intrinsics[4], cy = meta.intrinsics[5]
        let t = meta.transform

        var v = 0
        while v < meta.height {
            var u = 0
            while u < meta.width {
                defer { u += pixelStride }

                let depth = depthValues[v * meta.width + u]
                guard depth.isFinite, depth > 0 else { continue }

                // Back-project in the image/CV convention (Y down, Z forward
                // into the scene), then flip Y and Z into ARKit's own
                // camera-space convention (Y up, camera looks down -Z — the
                // same convention SceneKit's cameras use). See
                // ios/SCIENTIFIC_DATA_FORMAT.md §3.1 for the derivation.
                let xCam = (Float(u) - cx) * depth / fx
                let yCam = -(Float(v) - cy) * depth / fy
                let zCam = -depth

                let worldX = t[0] * xCam + t[1] * yCam + t[2] * zCam + t[3]
                let worldY = t[4] * xCam + t[5] * yCam + t[6] * zCam + t[7]
                let worldZ = t[8] * xCam + t[9] * yCam + t[10] * zCam + t[11]

                let color: SIMD3<Float>
                if let rgbPixels {
                    let su = min(Int(Float(u) * (Float(rgbPixels.width) / Float(meta.width))), rgbPixels.width - 1)
                    let sv = min(Int(Float(v) * (Float(rgbPixels.height) / Float(meta.height))), rgbPixels.height - 1)
                    let idx = (sv * rgbPixels.width + su) * 4
                    color = SIMD3<Float>(
                        Float(rgbPixels.data[idx]) / 255,
                        Float(rgbPixels.data[idx + 1]) / 255,
                        Float(rgbPixels.data[idx + 2]) / 255
                    )
                } else {
                    // No RGB available — fall back to a depth-based gray ramp
                    // so the cloud is still visible/inspectable.
                    let gray = min(max(depth / 5.0, 0), 1)
                    color = SIMD3<Float>(gray, gray, gray)
                }

                points.append(PointCloudPoint(position: SIMD3<Float>(worldX, worldY, worldZ), color: color))
            }
            v += pixelStride
        }
    }

    private static func loadDepthValues(binURL: URL, width: Int, height: Int) throws -> [Float] {
        let data = try Data(contentsOf: binURL)
        let expectedCount = width * height
        guard data.count >= expectedCount * MemoryLayout<Float32>.size else {
            throw PointCloudLoadError.unreadableFile(binURL.lastPathComponent)
        }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float32.self).prefix(expectedCount))
        }
    }

    /// Decodes an RGB image (HEIC) into a top-left-origin RGBA8 pixel buffer.
    private static func loadRGBPixels(url: URL) throws -> (data: [UInt8], width: Int, height: Int) {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw PointCloudLoadError.unreadableFile(url.lastPathComponent)
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let byteCount = height * bytesPerRow

        // CGContext writes into this buffer across the draw() call below, not
        // just during its own initializer — so it needs a pointer that stays
        // valid for that whole span. `&someArray` bridging only guarantees
        // validity for a single call, which draw() would violate; a manually
        // allocated buffer (freed via `defer` once we're done with it) is the
        // correct way to give CGContext a stable backing store.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<UInt8>.alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        guard let context = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PointCloudLoadError.unreadableFile(url.lastPathComponent)
        }

        // CGContext's default bitmap coordinate space has origin bottom-left;
        // our pixel-coordinate convention (matching the depth map's) is
        // origin top-left. Without this flip, sampled colors would come from
        // the vertically mirrored row.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let typedBuffer = buffer.bindMemory(to: UInt8.self, capacity: byteCount)
        let pixels = Array(UnsafeBufferPointer(start: typedBuffer, count: byteCount))

        return (pixels, width, height)
    }
}
