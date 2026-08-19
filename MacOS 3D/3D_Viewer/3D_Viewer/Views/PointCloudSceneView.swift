import SwiftUI
import SceneKit
import simd

/// Wraps an `SCNView` and rebuilds its point-cloud + trajectory geometry
/// whenever the data or point size changes. Camera orbit/pan/zoom is
/// SceneKit's own trackpad-driven `allowsCameraControl`.
struct PointCloudSceneView: NSViewRepresentable {
    var pointCloud: PointCloudData
    var pointSize: CGFloat
    var showTrajectory: Bool
    /// Bumped by the caller to force a re-frame of the camera (e.g. "Fit" button).
    var frameToken: Int

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.scene?.background.contents = NSColor(calibratedWhite: 0.06, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        context.coordinator.lastFrameToken = frameToken
        rebuild(view: view, context: context, refit: true)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let refit = context.coordinator.lastFrameToken != frameToken
        context.coordinator.lastFrameToken = frameToken
        rebuild(view: view, context: context, refit: refit)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastFrameToken = -1
    }

    private func rebuild(view: SCNView, context: Context, refit: Bool) {
        guard let scene = view.scene else { return }
        scene.rootNode.childNode(withName: "pointCloud", recursively: false)?.removeFromParentNode()
        scene.rootNode.childNode(withName: "trajectory", recursively: false)?.removeFromParentNode()

        guard !pointCloud.positions.isEmpty else { return }

        if let node = makePointCloudNode(pointCloud, pointSize: pointSize) {
            node.name = "pointCloud"
            scene.rootNode.addChildNode(node)
        }

        if showTrajectory, pointCloud.cameraTrajectory.count > 1,
           let trajNode = makeTrajectoryNode(pointCloud.cameraTrajectory) {
            trajNode.name = "trajectory"
            scene.rootNode.addChildNode(trajNode)
        }

        if refit {
            fitCamera(view: view, to: pointCloud.positions)
        }
    }

    private func makePointCloudNode(_ cloud: PointCloudData, pointSize: CGFloat) -> SCNNode? {
        let positions = cloud.positions
        guard !positions.isEmpty else { return nil }

        let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: positions.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        let colors = cloud.colors
        let colorSource: SCNGeometrySource? = colors.count == positions.count
            ? {
                let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
                return SCNGeometrySource(
                    data: colorData,
                    semantic: .color,
                    vectorCount: colors.count,
                    usesFloatComponents: true,
                    componentsPerVector: 4,
                    bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0,
                    dataStride: MemoryLayout<SIMD4<Float>>.stride
                )
            }()
            : nil

        var indices = [UInt32](repeating: 0, count: positions.count)
        for i in 0..<positions.count { indices[i] = UInt32(i) }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .point,
            primitiveCount: positions.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = max(1, pointSize)
        element.maximumPointScreenSpaceRadius = max(4, pointSize * 3)

        var sources = [vertexSource]
        if let colorSource { sources.append(colorSource) }
        let geometry = SCNGeometry(sources: sources, elements: [element])

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]

        return SCNNode(geometry: geometry)
    }

    private func makeTrajectoryNode(_ points: [SIMD3<Float>]) -> SCNNode? {
        guard points.count > 1 else { return nil }
        let vertexData = points.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: points.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        // SceneKit has no line-strip primitive; connect consecutive points as
        // independent segments instead: [0,1, 1,2, 2,3, ...].
        var indices = [UInt32]()
        indices.reserveCapacity((points.count - 1) * 2)
        for i in 0..<(points.count - 1) {
            indices.append(UInt32(i))
            indices.append(UInt32(i + 1))
        }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .line,
            primitiveCount: points.count - 1,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.systemOrange
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private func fitCamera(view: SCNView, to positions: [SIMD3<Float>]) {
        guard !positions.isEmpty else { return }
        var minP = positions[0]
        var maxP = positions[0]
        for p in positions {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let center = (minP + maxP) * 0.5
        let radius = max(simd_distance(minP, maxP) * 0.5, 0.5)

        let cameraNode: SCNNode
        if let existing = view.scene?.rootNode.childNode(withName: "mainCamera", recursively: false) {
            cameraNode = existing
        } else {
            let camera = SCNCamera()
            camera.zFar = Double(radius) * 20 + 50
            camera.zNear = 0.01
            cameraNode = SCNNode()
            cameraNode.name = "mainCamera"
            cameraNode.camera = camera
            view.scene?.rootNode.addChildNode(cameraNode)
        }
        let distance = radius * 2.5
        cameraNode.position = SCNVector3(center.x, center.y, center.z + distance)
        cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
        view.pointOfView = cameraNode
    }
}
