import SceneKit

enum PointCloudGeometryBuilder {

    /// Centroid and bounding radius, used to position the initial camera so
    /// the whole cloud is in view regardless of where in world space it sits.
    static func boundingSphere(points: [PointCloudPoint]) -> (centroid: SIMD3<Float>, radius: Float) {
        guard !points.isEmpty else { return (SIMD3<Float>(repeating: 0), 1) }

        var sum = SIMD3<Float>(repeating: 0)
        for point in points { sum += point.position }
        let centroid = sum / Float(points.count)

        var maxDistanceSquared: Float = 0
        for point in points {
            let delta = point.position - centroid
            let distanceSquared = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
            maxDistanceSquared = max(maxDistanceSquared, distanceSquared)
        }
        return (centroid, max(maxDistanceSquared.squareRoot(), 0.1))
    }

    static func makeGeometry(points: [PointCloudPoint]) -> SCNGeometry {
        let vertices = points.map { SCNVector3($0.position.x, $0.position.y, $0.position.z) }
        let vertexSource = SCNGeometrySource(vertices: vertices)

        var colorData = Data()
        colorData.reserveCapacity(points.count * 16)
        for point in points {
            var r = point.color.x
            var g = point.color.y
            var b = point.color.z
            var a: Float = 1
            withUnsafeBytes(of: &r) { colorData.append(contentsOf: $0) }
            withUnsafeBytes(of: &g) { colorData.append(contentsOf: $0) }
            withUnsafeBytes(of: &b) { colorData.append(contentsOf: $0) }
            withUnsafeBytes(of: &a) { colorData.append(contentsOf: $0) }
        }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: points.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 4
        )

        var indices: [Int32] = Array(0..<Int32(points.count))
        let indexData = Data(bytes: &indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .point,
            primitiveCount: points.count,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        element.pointSize = 3
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 6

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}
