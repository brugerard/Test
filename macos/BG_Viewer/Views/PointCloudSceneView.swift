import SwiftUI
import SceneKit

/// Renders a point cloud with free orbit/pan/zoom (SceneKit's built-in
/// `allowsCameraControl`). Rebuilds geometry and reframes the camera on the
/// starting position whenever `points` changes; the user's subsequent manual
/// orbiting isn't reset by unrelated SwiftUI re-renders because SwiftUI only
/// calls `updateNSView` when `points` actually differs.
struct PointCloudSceneView: NSViewRepresentable {
    let points: [PointCloudPoint]

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = SCNScene()
        scnView.allowsCameraControl = true
        scnView.backgroundColor = .black
        scnView.autoenablesDefaultLighting = true
        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        guard let scene = scnView.scene else { return }
        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }

        guard !points.isEmpty else { return }

        let geometry = PointCloudGeometryBuilder.makeGeometry(points: points)
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))

        let (centroid, radius) = PointCloudGeometryBuilder.boundingSphere(points: points)
        let centroidVector = SCNVector3(centroid.x, centroid.y, centroid.z)
        let distance = max(radius * 2.5, 0.5)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = Double(radius) * 20 + 10
        cameraNode.position = SCNVector3(centroid.x, centroid.y, centroid.z + distance)
        cameraNode.look(at: centroidVector)
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
    }
}
