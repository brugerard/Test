import SwiftUI

/// Root view: live AR camera preview, a status overlay for sensor/tracking
/// health, and (from Phase 2) Start/Stop Recording controls plus a recording
/// health panel. All acquisition/recording logic lives in ARCaptureManager and
/// RecordingSessionManager — this view only reads their published state and
/// forwards button taps.
struct ContentView: View {
    @StateObject private var arCaptureManager = ARCaptureManager()
    @StateObject private var recordingSessionManager = RecordingSessionManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            ARCameraPreviewView(session: arCaptureManager.session)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                statusPanel
                if recordingSessionManager.isRecordingPublished {
                    recordingHealthPanel
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 10) {
                shareLastSessionButton
                recordButton
            }
            .padding(.bottom, 32)
        }
        .onAppear {
            arCaptureManager.frameHandler = { [recordingSessionManager] snapshot in
                recordingSessionManager.handle(frame: snapshot)
            }
            arCaptureManager.start()
        }
        .onDisappear {
            if recordingSessionManager.isRecordingPublished {
                recordingSessionManager.stopRecording()
            }
            arCaptureManager.stop()
        }
        // ARKit forbids camera/GPU work while backgrounded — without this, a
        // backgrounded recording keeps trying (and failing) to encode frames
        // via Metal instead of stopping cleanly. `.inactive` is left alone: it
        // covers transient interruptions (Control Center, a system alert, an
        // incoming call) that ARKit's own sessionWasInterrupted/
        // sessionInterruptionEnded delegate callbacks already handle without
        // us tearing anything down.
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                if !arCaptureManager.isSessionRunning {
                    arCaptureManager.start()
                }
            case .background:
                if recordingSessionManager.isRecordingPublished {
                    recordingSessionManager.stopRecording()
                }
                arCaptureManager.stop()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    // MARK: - Status overlay (sensor/tracking health)

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
                Text(String(format: "Frame t = %.3f s (device uptime, not session-relative)", stats.timestamp))
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

    // MARK: - Recording health panel (visible only while recording)

    private var recordingHealthPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("● RECORDING").foregroundColor(.red).bold()
            if let sessionID = recordingSessionManager.currentSessionID {
                Text(sessionID)
            }
            Text(String(format: "Elapsed: %.1f s", recordingSessionManager.elapsedSeconds))
            Text("RGB frames written: \(recordingSessionManager.rgbFramesWritten)")
            Text("Depth frames written: \(recordingSessionManager.depthFramesWritten)")
            Text("Dropped frames: \(recordingSessionManager.droppedFrames)")
                .foregroundColor(recordingSessionManager.droppedFrames > 0 ? .orange : .white)
            Text("Disk write errors: \(recordingSessionManager.diskWriteErrors)")
                .foregroundColor(recordingSessionManager.diskWriteErrors > 0 ? .red : .white)
            if let error = recordingSessionManager.lastErrorMessage {
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

    // MARK: - Record button

    private var recordButton: some View {
        Button {
            if recordingSessionManager.isRecordingPublished {
                recordingSessionManager.stopRecording()
            } else {
                recordingSessionManager.startRecording(lidarAvailable: arCaptureManager.isSceneDepthActive)
            }
        } label: {
            Text(recordingSessionManager.isRecordingPublished ? "STOP RECORDING" : "START RECORDING")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(recordingSessionManager.isRecordingPublished ? Color.red : Color.green)
                .cornerRadius(14)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Share last session
    //
    // A direct route to get a recorded session off the phone (AirDrop, Save
    // to Files, Mail, ...) via the system share sheet. Added because Finder's
    // device-file-sharing view and the Files app's "On My iPhone" listing
    // both proved unreliable in testing despite correct Info.plist
    // configuration — the share sheet doesn't depend on either.

    @ViewBuilder
    private var shareLastSessionButton: some View {
        if !recordingSessionManager.isRecordingPublished, let sessionURL = recordingSessionManager.lastCompletedSessionURL {
            ShareLink(item: sessionURL) {
                Label("Share Last Session", systemImage: "square.and.arrow.up")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue.opacity(0.85))
                    .cornerRadius(12)
            }
            .padding(.horizontal, 24)
        }
    }

    private func format(_ value: Float) -> String {
        value.isNaN ? "n/a" : String(format: "%.2f", value)
    }
}

#Preview {
    ContentView()
}
