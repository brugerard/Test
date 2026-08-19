import SwiftUI

/// Phase 1 root view: live AR camera preview plus a status overlay proving that
/// world tracking and (on LiDAR devices) scene depth are working. No recording
/// controls yet — those arrive in Phase 2 onward.
struct ContentView: View {
    @StateObject private var arCaptureManager = ARCaptureManager()

    var body: some View {
        ZStack(alignment: .top) {
            ARCameraPreviewView(session: arCaptureManager.session)
                .ignoresSafeArea()

            statusPanel
                .padding()
        }
        .onAppear { arCaptureManager.start() }
        .onDisappear { arCaptureManager.stop() }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow(label: "LiDAR / Scene Depth Supported", available: arCaptureManager.isLiDARAvailable)
            statusRow(label: "Scene Depth Active", available: arCaptureManager.isSceneDepthActive)

            Text("Tracking: \(arCaptureManager.trackingSummary.rawValue)")
            Text("AR frames received: \(arCaptureManager.frameCount)")

            Divider().overlay(Color.white.opacity(0.3))

            if let stats = arCaptureManager.latestDepthStats {
                Text("Depth map: \(stats.width) x \(stats.height) px")
                Text("Depth (m) — min \(format(stats.minDepthMeters))  mean \(format(stats.meanDepthMeters))  max \(format(stats.maxDepthMeters))")
                Text("Valid samples: \(stats.validSampleCount) / \(stats.sampledCount)")
                Text(String(format: "Frame t = %.3f s (session-relative)", stats.timestamp))
            } else {
                Text("Depth: no scene depth frame received yet")
            }

            if let error = arCaptureManager.lastError {
                Text("⚠️ \(error)")
                    .foregroundColor(.orange)
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(10)
        .background(Color.black.opacity(0.65))
        .foregroundColor(.white)
        .cornerRadius(10)
    }

    private func statusRow(label: String, available: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(available ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func format(_ value: Float) -> String {
        value.isNaN ? "n/a" : String(format: "%.2f", value)
    }
}

#Preview {
    ContentView()
}
