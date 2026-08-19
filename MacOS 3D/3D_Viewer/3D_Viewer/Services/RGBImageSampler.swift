import CoreGraphics
import Foundation
import ImageIO
import simd

/// Decodes a HEIC/JPEG/etc. image into a flat RGBA8 buffer once, so
/// individual pixels can be sampled cheaply while building a point cloud.
struct RGBImageSampler {
    let width: Int
    let height: Int
    private let pixels: [UInt8] // RGBA8, row-major, width*height*4 bytes

    /// - Parameter maxPixelSize: Decodes a downscaled thumbnail no larger
    ///   than this on its longest side, instead of the full-resolution
    ///   image. Point-cloud coloring only ever nearest-samples one color
    ///   per depth pixel, so decoding at (approximately) the depth map's own
    ///   resolution instead of the RGB capture's full resolution (e.g.
    ///   1920x1440) avoids doing 60x more decode work than the result can
    ///   ever use — this matters when merging hundreds of frames, where
    ///   full-resolution HEIC decodes were measured to push RSS into the
    ///   multi-gigabyte range and stall for tens of seconds.
    init?(contentsOf url: URL, maxPixelSize: Int) {
        guard let cgImage = autoreleasepool(invoking: { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }) else { return nil }

        let w = cgImage.width
        let h = cgImage.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drew: Bool = autoreleasepool {
            guard let context = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
                CGContext(
                    data: raw.baseAddress,
                    width: w, height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            }) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }

        self.width = w
        self.height = h
        self.pixels = buffer
    }

    /// Nearest-pixel sample at raw image coordinates (origin top-left, +Y
    /// down — matching the depth/RGB pixel convention in
    /// SCIENTIFIC_DATA_FORMAT.md Section 3), returned as linear 0...1 RGBA.
    func sample(x: Int, y: Int) -> SIMD4<Float>? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let offset = (y * width + x) * 4
        let r = Float(pixels[offset]) / 255
        let g = Float(pixels[offset + 1]) / 255
        let b = Float(pixels[offset + 2]) / 255
        let a = Float(pixels[offset + 3]) / 255
        return SIMD4<Float>(r, g, b, a)
    }
}
