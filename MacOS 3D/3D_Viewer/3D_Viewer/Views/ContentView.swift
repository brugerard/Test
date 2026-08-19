import SwiftUI
import UniformTypeIdentifiers

enum FrameSelectionMode: String, CaseIterable, Identifiable {
    case single = "Single Frame"
    case merged = "All Frames (merged)"
    var id: String { rawValue }
}

struct ContentView: View {
    @State private var session: Session?
    @State private var accessedURL: URL?
    @State private var loadError: String?

    @State private var mode: FrameSelectionMode = .single
    @State private var selectedFrameIndex = 0
    @State private var options = PointCloudBuildOptions()
    @State private var pointSize: CGFloat = 4
    @State private var showTrajectory = true

    @State private var pointCloud = PointCloudData()
    @State private var isBuilding = false
    @State private var frameToken = 0

    @State private var showFileImporter = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .navigationTitle(session?.displayName ?? "3D_Viewer")
    }

    // MARK: Sidebar

    private var sidebar: some View {
        Form {
            Section("Session") {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Open Session Folder…", systemImage: "folder.badge.plus")
                }
                if let session {
                    LabeledContent("Frames", value: "\(session.depthFrames.count)")
                    if let device = session.metadata?.deviceHardwareIdentifier {
                        LabeledContent("Device", value: device)
                    }
                }
                if let loadError {
                    Text(loadError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            if session != nil {
                Section("Frames") {
                    Picker("Show", selection: $mode) {
                        ForEach(FrameSelectionMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .single, let session {
                        Stepper(
                            "Frame \(session.depthFrames[safe: selectedFrameIndex]?.info.depthFrameID ?? 0) of \(session.depthFrames.count)",
                            value: $selectedFrameIndex,
                            in: 0...max(0, session.depthFrames.count - 1)
                        )
                        Slider(
                            value: Binding(
                                get: { Double(selectedFrameIndex) },
                                set: { selectedFrameIndex = Int($0) }
                            ),
                            in: 0...Double(max(0, session.depthFrames.count - 1)),
                            step: 1
                        )
                    }
                }

                Section("Appearance") {
                    Picker("Color by", selection: $options.colorMode) {
                        ForEach(ColorMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    LabeledContent("Point size") {
                        Slider(value: $pointSize, in: 1...12)
                    }
                    Toggle("Show camera trajectory", isOn: $showTrajectory)
                }

                Section("Sampling") {
                    Stepper("Pixel stride: \(options.stride)", value: $options.stride, in: 1...16)
                    Text("Lower stride = denser cloud, slower to build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Quality") {
                    Toggle("Shade by surface angle", isOn: $options.useNormalShading)
                    Picker("Minimum confidence", selection: $options.minConfidence) {
                        Text("Low (all points)").tag(UInt8(0))
                        Text("Medium").tag(UInt8(1))
                        Text("High only").tag(UInt8(2))
                    }
                    LabeledContent("Edge-artifact filter") {
                        Slider(value: $options.edgeDiscontinuityThreshold, in: 0.02...0.30)
                    }
                    Text("Drops \"flying pixel\" points that straddle a foreground/background edge, and low-confidence LiDAR samples — both are common sources of stray points and streaky noise.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Fit Camera to Cloud") { frameToken += 1 }
                }

                if isBuilding {
                    ProgressView("Building point cloud…")
                } else {
                    LabeledContent("Points", value: "\(pointCloud.positions.count)")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 300, idealWidth: 320)
        .onChange(of: mode) { rebuildPointCloud(refit: true) }
        .onChange(of: selectedFrameIndex) { rebuildPointCloud(refit: false) }
        .onChange(of: options.colorMode) { rebuildPointCloud(refit: false) }
        .onChange(of: options.stride) { rebuildPointCloud(refit: false) }
        .onChange(of: options.useNormalShading) { rebuildPointCloud(refit: false) }
        .onChange(of: options.minConfidence) { rebuildPointCloud(refit: false) }
        .onChange(of: options.edgeDiscontinuityThreshold) { rebuildPointCloud(refit: false) }
    }

    // MARK: Detail

    private var detail: some View {
        ZStack {
            if session == nil {
                ContentUnavailableView(
                    "No Session Loaded",
                    systemImage: "cube.transparent",
                    description: Text("Open a BG_Sensing Session_* folder to view its LiDAR point cloud.")
                )
            } else {
                PointCloudSceneView(
                    pointCloud: pointCloud,
                    pointSize: pointSize,
                    showTrajectory: showTrajectory,
                    frameToken: frameToken
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: Actions

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            loadError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            loadSession(at: url)
        }
    }

    private func loadSession(at url: URL) {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil

        guard url.startAccessingSecurityScopedResource() else {
            loadError = "Couldn't get permission to read \(url.path)."
            return
        }
        accessedURL = url

        do {
            let loaded = try SessionLoader.load(directoryURL: url)
            session = loaded
            loadError = nil
            selectedFrameIndex = 0
            mode = .single
            frameToken += 1
            rebuildPointCloud(refit: true)
        } catch {
            loadError = error.localizedDescription
            session = nil
        }
    }

    private func rebuildPointCloud(refit: Bool) {
        guard let session else {
            pointCloud = PointCloudData()
            return
        }
        let framesToProcess: [DepthFrame]
        switch mode {
        case .single:
            if let frame = session.depthFrames[safe: selectedFrameIndex] {
                framesToProcess = [frame]
            } else {
                framesToProcess = []
            }
        case .merged:
            framesToProcess = session.depthFrames
        }

        let opts = options
        isBuilding = true
        Task.detached(priority: .userInitiated) {
            var building = PointCloudData()
            for frame in framesToProcess {
                PointCloudBuilder.build(frame: frame, options: opts, into: &building)
            }
            let finalResult = building
            await MainActor.run {
                self.pointCloud = finalResult
                self.isBuilding = false
                if refit { self.frameToken += 1 }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    ContentView()
}
