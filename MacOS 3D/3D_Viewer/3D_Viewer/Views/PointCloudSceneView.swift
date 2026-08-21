import SwiftUI
import SceneKit
import simd

/// How the camera frames the cloud on load / "Fit" / mode switch.
enum CameraFitMode: String, CaseIterable, Identifiable {
    /// Bounding-box center, viewed from a 3/4 elevated angle — reads as
    /// correctly oriented at a glance and shows the whole cloud.
    case elevated = "Elevated"
    /// Eye level at the average iPhone capture position, looking level
    /// (no tilt) toward the farthest captured point — approximates what
    /// standing where you scanned from and looking down the longest sightline
    /// actually looked like.
    case eyeLevel = "Eye-level (capture position)"
    var id: String { rawValue }
}

/// Wraps an `SCNView` and rebuilds its point-cloud + trajectory geometry
/// whenever the data or point size changes. Camera orbit/pan/zoom is
/// SceneKit's own trackpad-driven `allowsCameraControl`.
struct PointCloudSceneView: NSViewRepresentable {
    var pointCloud: PointCloudData
    var pointSize: CGFloat
    var showTrajectory: Bool
    /// Bumped by the caller to force a re-frame of the camera (e.g. "Fit" button).
    var frameToken: Int
    var fitMode: CameraFitMode
    /// When true, points whose surface faces away from the *current* camera
    /// (live, updates as you orbit) render as fully transparent, via a
    /// Metal shader modifier — not baked in at build time, since "facing
    /// away" depends on where you're currently looking from, not just how
    /// the frame was originally captured.
    var hideBackFaces: Bool
    /// Exposes this view's `SCNView` to the sidebar's discrete zoom/orbit/pan
    /// buttons — see `CameraCommander`.
    var commander: CameraCommander

    /// Discards fragments whose supplied per-vertex normal, once transformed
    /// to view space by SceneKit's own surface stage, points away from the
    /// camera. View space has the camera at the origin looking down -Z, so a
    /// normal facing back toward the camera (i.e. toward the viewer) has a
    /// positive Z component; anything at or past grazing (<= 0) is treated
    /// as the back side.
    private static let backFaceCullShader = """
    #pragma body
    if (_surface.normal.z < 0.0) {
        discard_fragment();
    }
    """

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.scene?.background.contents = NSColor(calibratedWhite: 0.06, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        context.coordinator.lastFrameToken = frameToken
        commander.scnView = view
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

        if let node = makePointCloudNode(pointCloud, pointSize: pointSize, hideBackFaces: hideBackFaces) {
            node.name = "pointCloud"
            scene.rootNode.addChildNode(node)
        }

        if showTrajectory, pointCloud.cameraTrajectory.count > 1,
           let trajNode = makeTrajectoryNode(pointCloud.cameraTrajectory) {
            trajNode.name = "trajectory"
            scene.rootNode.addChildNode(trajNode)
        }

        if refit {
            switch fitMode {
            case .elevated:
                fitCameraElevated(view: view, to: pointCloud.positions)
            case .eyeLevel:
                fitCameraEyeLevel(view: view, cloud: pointCloud)
            }
        }
    }

    private func makePointCloudNode(_ cloud: PointCloudData, pointSize: CGFloat, hideBackFaces: Bool) -> SCNNode? {
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

        let normals = cloud.normals
        let normalSource: SCNGeometrySource? = normals.count == positions.count
            ? {
                let normalData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
                return SCNGeometrySource(
                    data: normalData,
                    semantic: .normal,
                    vectorCount: normals.count,
                    usesFloatComponents: true,
                    componentsPerVector: 3,
                    bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0,
                    dataStride: MemoryLayout<SIMD3<Float>>.stride
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
        if let normalSource { sources.append(normalSource) }
        let geometry = SCNGeometry(sources: sources, elements: [element])

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        if hideBackFaces, normalSource != nil {
            material.shaderModifiers = [.fragment: Self.backFaceCullShader]
        }
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

    /// Finds (or creates) the persistent main-camera node, sized so `zFar`
    /// comfortably covers a cloud of the given radius.
    private func cameraNode(in view: SCNView, forRadius radius: Float) -> SCNNode {
        if let existing = view.scene?.rootNode.childNode(withName: "mainCamera", recursively: false) {
            return existing
        }
        let camera = SCNCamera()
        camera.zFar = Double(radius) * 20 + 50
        camera.zNear = 0.01
        let node = SCNNode()
        node.name = "mainCamera"
        node.camera = camera
        view.scene?.rootNode.addChildNode(node)
        return node
    }

    /// Places `node` at `eye` looking at `target`, using an explicit up
    /// vector. The explicit up/localFront overload avoids `look(at:)`'s
    /// ambiguous default-up resolution, which was producing an upside-down
    /// initial view for some sessions — world +Y (ARKit's own
    /// gravity-aligned "up", per SCIENTIFIC_DATA_FORMAT.md) is always what
    /// should read as up on screen.
    private func point(_ node: SCNNode, from eye: SIMD3<Float>, at target: SIMD3<Float>) {
        node.position = SCNVector3(eye.x, eye.y, eye.z)
        node.look(at: SCNVector3(target.x, target.y, target.z), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
    }

    private func fitCameraElevated(view: SCNView, to positions: [SIMD3<Float>]) {
        guard !positions.isEmpty else { return }
        var minP = positions[0]
        var maxP = positions[0]
        for p in positions {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let center = (minP + maxP) * 0.5
        let radius = max(simd_distance(minP, maxP) * 0.5, 0.5)

        let node = cameraNode(in: view, forRadius: radius)
        // A 3/4 elevated default angle (rather than dead-on from the front)
        // reads as "up the right way" far more reliably than a horizontal
        // eye line, and shows the floor/ceiling relationship immediately.
        let distance = radius * 2.5
        let eyeDirection = simd_normalize(SIMD3<Float>(0.35, 0.55, 0.85))
        point(node, from: center + eyeDirection * distance, at: center)
        view.pointOfView = node
    }

    /// Places the camera at the average recorded iPhone position (roughly
    /// where you stood while capturing) and levels it off to look straight
    /// at whichever captured point is farthest away — the longest sightline
    /// actually available in the scan, viewed the way a person standing
    /// there and looking straight ahead would have seen it.
    private func fitCameraEyeLevel(view: SCNView, cloud: PointCloudData) {
        let positions = cloud.positions
        guard !positions.isEmpty else { return }
        let trajectory = cloud.cameraTrajectory.isEmpty ? positions : cloud.cameraTrajectory

        var eye = SIMD3<Float>(repeating: 0)
        for p in trajectory { eye += p }
        eye /= Float(trajectory.count)

        var farthest = positions[0]
        var farthestDistSq: Float = 0
        for p in positions {
            let d = simd_distance_squared(p, eye)
            if d > farthestDistSq { farthestDistSq = d; farthest = p }
        }

        // Level the sightline: drop any up/down tilt so the view looks
        // straight ahead, the way eyes at a fixed height naturally would.
        var direction = farthest - eye
        direction.y = 0
        if simd_length_squared(direction) < 1e-6 {
            direction = SIMD3<Float>(0, 0, -1)
        }
        direction = simd_normalize(direction)

        let node = cameraNode(in: view, forRadius: max(sqrt(farthestDistSq), 0.5))
        point(node, from: eye, at: eye + direction)
        view.pointOfView = node
    }
}

/// Lets SwiftUI buttons drive the same `SCNCameraController` that trackpad
/// gestures use (via `SCNView.allowsCameraControl`), instead of fighting its
/// internal orbit state by nudging the camera node's transform directly.
final class CameraCommander: ObservableObject {
    fileprivate weak var scnView: SCNView?

    func zoom(_ delta: Float) {
        guard let scnView else { return }
        let viewport = scnView.bounds.size
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        scnView.defaultCameraController.dolly(by: delta, onScreenPoint: center, viewport: viewport)
    }

    /// Orbits (and, via `dy`, tilts) around the current target.
    func orbit(dx: Float, dy: Float) {
        scnView?.defaultCameraController.rotateBy(x: dx, y: dy)
    }

    /// Slides the camera and its target together, in camera-local space.
    func pan(dx: Float, dy: Float) {
        scnView?.defaultCameraController.translateInCameraSpaceBy(x: dx, y: dy, z: 0)
    }
}
