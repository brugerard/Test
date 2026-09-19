import simd

enum ColorMode: String, CaseIterable, Identifiable {
    case rgb = "RGB"
    case depth = "Depth"
    case height = "Height"
    case confidence = "Confidence"

    var id: String { rawValue }
}

enum Colormap {
    /// A simple blue -> cyan -> green -> yellow -> red gradient for `t` in 0...1.
    static func heat(_ t: Float) -> SIMD4<Float> {
        let c = max(0, min(1, t))
        let stops: [(Float, SIMD3<Float>)] = [
            (0.00, SIMD3<Float>(0.10, 0.10, 0.80)),
            (0.25, SIMD3<Float>(0.00, 0.80, 0.90)),
            (0.50, SIMD3<Float>(0.10, 0.85, 0.10)),
            (0.75, SIMD3<Float>(0.95, 0.85, 0.00)),
            (1.00, SIMD3<Float>(0.90, 0.10, 0.10)),
        ]
        for i in 1..<stops.count {
            let (t1, c1) = stops[i]
            if c <= t1 {
                let (t0, c0) = stops[i - 1]
                let f = t1 > t0 ? (c - t0) / (t1 - t0) : 0
                let mixed = simd_mix(c0, c1, SIMD3<Float>(repeating: f))
                return SIMD4<Float>(mixed, 1)
            }
        }
        return SIMD4<Float>(stops.last!.1, 1)
    }

    /// Distinct, well-separated hues for tagging disjoint capture segments
    /// (see `MergeSegment`) — cycles if there are more segments than colors.
    static let segmentPalette: [SIMD4<Float>] = [
        SIMD4<Float>(0.95, 0.30, 0.30, 1), // red
        SIMD4<Float>(0.20, 0.55, 0.95, 1), // blue
        SIMD4<Float>(0.25, 0.80, 0.35, 1), // green
        SIMD4<Float>(0.95, 0.75, 0.15, 1), // yellow
        SIMD4<Float>(0.75, 0.30, 0.90, 1), // purple
        SIMD4<Float>(0.95, 0.50, 0.15, 1), // orange
        SIMD4<Float>(0.20, 0.80, 0.80, 1), // teal
        SIMD4<Float>(0.90, 0.35, 0.65, 1), // pink
    ]

    static func confidence(_ level: UInt8) -> SIMD4<Float> {
        switch level {
        case 2: return SIMD4<Float>(0.15, 0.85, 0.15, 1) // high
        case 1: return SIMD4<Float>(0.90, 0.75, 0.10, 1) // medium
        default: return SIMD4<Float>(0.85, 0.15, 0.15, 1) // low
        }
    }
}
