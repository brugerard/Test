import Foundation
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// All disk I/O for recorded sensor data goes through this actor, so writes from
/// many concurrent frame-processing tasks are serialized safely without manual
/// locking. Callers on the ARKit delegate queue never block on this — they kick
/// off a `Task` and continue; the actor's own executor does the (potentially
/// slow) encode/write work off both the main thread and ARKit's callback thread.
///
/// V2 note: this actor used to also try to enforce a backpressure ceiling
/// internally (a `pendingWrites` counter capped at 6), but that mechanism was
/// dead code — none of the write methods below have an internal `await`, so
/// each call runs start-to-finish atomically once the actor's executor picks
/// it up, meaning `pendingWrites` could never exceed 1 before returning to 0.
/// Real admission control (rejecting a frame *before* any write is attempted,
/// so a slow disk can't cause unbounded `Task`/`CVPixelBuffer` accumulation)
/// now lives in `RecordingSessionManager`, which is the layer that actually
/// knows how many writes are outstanding across every call site.
actor DataWriter {

    struct WriteOutcome {
        let succeeded: Bool
        let error: String?

        static func ok() -> WriteOutcome { WriteOutcome(succeeded: true, error: nil) }
        static func failed(_ message: String) -> WriteOutcome { WriteOutcome(succeeded: false, error: message) }
    }

    private enum RawWriteError: Error, LocalizedError {
        case pixelBufferLockFailed
        case imageEncodeFailed
        case destinationCreateFailed

        var errorDescription: String? {
            switch self {
            case .pixelBufferLockFailed: return "Failed to lock pixel buffer for reading"
            case .imageEncodeFailed: return "Failed to create CGImage from captured frame"
            case .destinationCreateFailed: return "Failed to create image destination"
            }
        }
    }

    private let ciContext = CIContext()

    func writeRGBFrame(pixelBuffer: CVPixelBuffer, to url: URL, heicQuality: CGFloat = 0.9) -> WriteOutcome {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return .failed(RawWriteError.imageEncodeFailed.localizedDescription)
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            return .failed(RawWriteError.destinationCreateFailed.localizedDescription)
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: heicQuality]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return .failed("Failed to finalize HEIC write at \(url.lastPathComponent)")
        }
        return .ok()
    }

    func writeDepthFrame(depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer?, binURL: URL, confidenceURL: URL?) -> WriteOutcome {
        do {
            let depthData = try Self.packedRasterData(from: depthMap, bytesPerElement: 4)
            try depthData.write(to: binURL, options: .atomic)
            if let confidenceMap, let confidenceURL {
                let confidenceData = try Self.packedRasterData(from: confidenceMap, bytesPerElement: 1)
                try confidenceData.write(to: confidenceURL, options: .atomic)
            }
            return .ok()
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func writeJSON<T: Encodable>(_ value: T, to url: URL) -> WriteOutcome {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            return .ok()
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func appendCSVLine(_ line: String, to url: URL) -> WriteOutcome {
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = (line + "\n").data(using: .utf8) {
                handle.write(data)
            }
            return .ok()
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Copies a `CVPixelBuffer`'s single-plane data into a tightly packed,
    /// row-major `Data` buffer of exactly `width * height * bytesPerElement`
    /// bytes — i.e. with any row padding (`bytesPerRow > width * bytesPerElement`,
    /// common for GPU-backed buffers) stripped out. Without this, dumping the
    /// buffer's raw memory would interleave real pixel data with meaningless
    /// padding bytes, corrupting the raster for any external reader.
    private static func packedRasterData(from pixelBuffer: CVPixelBuffer, bytesPerElement: Int) throws -> Data {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            throw RawWriteError.pixelBufferLockFailed
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw RawWriteError.pixelBufferLockFailed
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowByteCount = width * bytesPerElement

        var data = Data(capacity: rowByteCount * height)
        for y in 0..<height {
            let rowStart = base.advanced(by: y * bytesPerRow)
            data.append(rowStart.assumingMemoryBound(to: UInt8.self), count: rowByteCount)
        }
        return data
    }
}
