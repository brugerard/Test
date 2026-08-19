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

    init?(contentsOf url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let w = cgImage.width
        let h = cgImage.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(
                data: raw.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
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
