import Foundation

enum SessionLoaderError: LocalizedError {
    case noDepthFrames
    case unreadableDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .noDepthFrames:
            return "No depth/*.json frames were found in this session folder."
        case .unreadableDirectory(let url):
            return "Couldn't read the contents of \(url.path)."
        }
    }
}

/// Loads a BG_Sensing exported session directory
/// (`Session_<datetime>_<uuid8>/`, SCIENTIFIC_DATA_FORMAT.md Section 2).
enum SessionLoader {
    static func load(directoryURL: URL) throws -> Session {
        let fm = FileManager.default

        let metadata = try? loadMetadata(directoryURL.appendingPathComponent("metadata.json"))
        let frameRecords = (try? loadFramesCSV(directoryURL.appendingPathComponent("sensors/frames.csv"))) ?? [:]
        // motion.csv is a newer addition (Phase 3) — absent in older sessions,
        // which just get no motion-based filtering rather than a load error.
        let motionSamples = (try? loadMotionCSV(directoryURL.appendingPathComponent("sensors/motion.csv"))) ?? []

        let depthDir = directoryURL.appendingPathComponent("depth")
        guard let entries = try? fm.contentsOfDirectory(
            at: depthDir, includingPropertiesForKeys: nil
        ) else {
            throw SessionLoaderError.unreadableDirectory(depthDir)
        }

        let decoder = JSONDecoder()
        var depthFrames: [DepthFrame] = []
        for jsonURL in entries where jsonURL.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: jsonURL),
                  let info = try? decoder.decode(DepthFrameInfo.self, from: data)
            else { continue }

            let stem = jsonURL.deletingPathExtension().lastPathComponent // "depth_000042"
            let binURL = depthDir.appendingPathComponent(stem + ".bin")
            guard fm.fileExists(atPath: binURL.path) else { continue }

            let confStem = stem.replacingOccurrences(of: "depth_", with: "confidence_")
            let confURL = depthDir.appendingPathComponent(confStem + ".bin")
            let confidenceURL = info.hasConfidence && fm.fileExists(atPath: confURL.path) ? confURL : nil

            var rgbURL: URL?
            var rgbSize: (Int, Int)?
            if let rgbID = info.correspondingRGBFrameID {
                let rgbStem = String(format: "frame_%06d", rgbID)
                let candidate = directoryURL.appendingPathComponent("rgb/\(rgbStem).heic")
                if fm.fileExists(atPath: candidate.path) {
                    rgbURL = candidate
                    if let record = frameRecords[rgbID] {
                        rgbSize = (record.imageWidth, record.imageHeight)
                    }
                }
            }

            depthFrames.append(DepthFrame(
                info: info,
                binURL: binURL,
                confidenceURL: confidenceURL,
                rgbURL: rgbURL,
                rgbImageSize: rgbSize,
                peakRotationRate: peakRotationRate(around: info.sessionTimeSeconds, in: motionSamples)
            ))
        }

        guard !depthFrames.isEmpty else { throw SessionLoaderError.noDepthFrames }
        depthFrames.sort { $0.info.depthFrameID < $1.info.depthFrameID }

        return Session(directoryURL: directoryURL, metadata: metadata, depthFrames: depthFrames)
    }

    private static func loadMetadata(_ url: URL) throws -> SessionMetadata {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionMetadata.self, from: data)
    }

    /// Parses `sensors/frames.csv` into a `[frameID: FrameRecord]` map,
    /// looking up columns by header name (Section 6) rather than assuming a
    /// fixed order.
    private static func loadFramesCSV(_ url: URL) throws -> [Int: FrameRecord] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return [:] }
        let header = lines.removeFirst().split(separator: ",").map(String.init)
        var index: [String: Int] = [:]
        for (i, name) in header.enumerated() { index[name] = i }

        func col(_ name: String, _ fields: [String]) -> String? {
            guard let i = index[name], i < fields.count else { return nil }
            let v = fields[i]
            return v.isEmpty ? nil : v
        }

        var result: [Int: FrameRecord] = [:]
        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let frameIDStr = col("frameID", fields), let frameID = Int(frameIDStr) else { continue }

            var intrinsics = [Float](repeating: 0, count: 9)
            for r in 1...3 {
                for c in 1...3 {
                    let key = "intrinsics_m\(r)\(c)"
                    intrinsics[(r - 1) * 3 + (c - 1)] = col(key, fields).flatMap(Float.init) ?? 0
                }
            }
            var transform = [Float](repeating: 0, count: 16)
            for r in 1...4 {
                for c in 1...4 {
                    let key = "transform_m\(r)\(c)"
                    transform[(r - 1) * 4 + (c - 1)] = col(key, fields).flatMap(Float.init) ?? 0
                }
            }

            let record = FrameRecord(
                frameID: frameID,
                sessionTimeSeconds: col("sessionTimeSeconds", fields).flatMap(Double.init) ?? 0,
                imageWidth: col("imageWidth", fields).flatMap(Int.init) ?? 0,
                imageHeight: col("imageHeight", fields).flatMap(Int.init) ?? 0,
                orientation: col("orientation", fields) ?? "",
                intrinsics: intrinsics,
                transform: transform,
                trackingState: col("trackingState", fields) ?? "",
                correspondingDepthFrameID: col("correspondingDepthFrameID", fields).flatMap(Int.init)
            )
            result[frameID] = record
        }
        return result
    }

    /// Parses `sensors/motion.csv` (Core Motion device-motion stream),
    /// sorted by `sessionTimeSeconds` so `peakRotationRate` can binary-search it.
    private static func loadMotionCSV(_ url: URL) throws -> [MotionSample] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().split(separator: ",").map(String.init)
        var index: [String: Int] = [:]
        for (i, name) in header.enumerated() { index[name] = i }

        func col(_ name: String, _ fields: [String]) -> String? {
            guard let i = index[name], i < fields.count else { return nil }
            let v = fields[i]
            return v.isEmpty ? nil : v
        }

        var samples: [MotionSample] = []
        samples.reserveCapacity(lines.count)
        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let t = col("sessionTimeSeconds", fields).flatMap(Double.init) else { continue }
            samples.append(MotionSample(
                sessionTimeSeconds: t,
                rotationRateX: col("rotationRateX", fields).flatMap(Float.init) ?? 0,
                rotationRateY: col("rotationRateY", fields).flatMap(Float.init) ?? 0,
                rotationRateZ: col("rotationRateZ", fields).flatMap(Float.init) ?? 0
            ))
        }
        samples.sort { $0.sessionTimeSeconds < $1.sessionTimeSeconds }
        return samples
    }

    /// Peak angular-velocity magnitude within ±`window` seconds of `time`,
    /// or nil if `samples` is empty or none fall in range.
    private static func peakRotationRate(around time: Double, in samples: [MotionSample], window: Double = 0.15) -> Float? {
        guard !samples.isEmpty else { return nil }
        var lo = 0
        var hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].sessionTimeSeconds < time - window {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var peak: Float?
        var i = lo
        while i < samples.count, samples[i].sessionTimeSeconds <= time + window {
            peak = max(peak ?? 0, samples[i].rotationRateMagnitude)
            i += 1
        }
        return peak
    }
}
