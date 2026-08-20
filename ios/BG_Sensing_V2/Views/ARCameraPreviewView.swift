import SwiftUI
import ARKit

/// Thin SwiftUI wrapper around `ARSCNView` used only to render the camera feed.
///
/// This view does not own the `ARSession` and never calls `run`/`pause` — session
/// lifecycle and all acquisition logic live in `ARCaptureManager`. Keeping this view
/// this dumb is deliberate: it must stay swappable (e.g. for a RealityKit `ARView`)
/// without touching acquisition code.
struct ARCameraPreviewView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Session is externally managed by ARCaptureManager; nothing to sync here.
    }
}
