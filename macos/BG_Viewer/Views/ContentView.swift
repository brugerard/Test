import SwiftUI
import AppKit

/// Root view: point cloud viewport plus a control strip below it (open a
/// session, see status, adjust the density strides). All reconstruction
/// logic lives in PointCloudBuilder — this view just drives it and displays
/// the result.
struct ContentView: View {
    @State private var points: [PointCloudPoint] = []
    @State private var statusMessage = "Open a BG_Sensing session folder to view its point cloud."
    @State private var isLoading = false
    @State private var pixelStride: Double = 2
    @State private var frameStride: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            PointCloudSceneView(points: points)
                .frame(minWidth: 640, minHeight: 480)

            controls
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Open Session…") {
                    openSession()
                }
                .disabled(isLoading)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 16) {
                HStack {
                    Text("Pixel stride: \(Int(pixelStride))")
                    Slider(value: $pixelStride, in: 1...8, step: 1)
                }
                HStack {
                    Text("Frame stride: \(Int(frameStride))")
                    Slider(value: $frameStride, in: 1...10, step: 1)
                }
            }
            .font(.caption)
        }
        .padding()
    }

    private func openSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a Session_... folder exported from BG_Sensing."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isLoading = true
        statusMessage = "Loading \(url.lastPathComponent)…"

        let stride = max(Int(pixelStride), 1)
        let fStride = max(Int(frameStride), 1)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loaded = try PointCloudBuilder.loadSession(at: url, pixelStride: stride, frameStride: fStride)
                DispatchQueue.main.async {
                    points = loaded
                    statusMessage = "\(url.lastPathComponent): \(loaded.count) points"
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    statusMessage = "Failed to load: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
