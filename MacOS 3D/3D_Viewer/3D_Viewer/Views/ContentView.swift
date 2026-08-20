import SwiftUI
import UniformTypeIdentifiers
import simd

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
    @State private var icpStats: (corrected: Int, uncorrected: Int)?
    @State private var segments: [MergeSegment] = []
    @State private var highlightSegments = false

    @State private var showFileImporter = false
    @StateObject private var cameraCommander = CameraCommander()
    @State private var cameraFitMode: CameraFitMode = .elevated

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

                    Toggle("Fuse overlapping points", isOn: Binding(
                        get: { options.fusionVoxelSize != nil },
                        set: { options.fusionVoxelSize = $0 ? 0.02 : nil }
                    ))
                    if options.fusionVoxelSize != nil {
                        LabeledContent("Fusion voxel size") {
                            Slider(
                                value: Binding(
                                    get: { options.fusionVoxelSize ?? 0.02 },
                                    set: { options.fusionVoxelSize = $0 }
                                ),
                                in: 0.005...0.06
                            )
                        }
                        Text("Averages points from overlapping frames within each \(String(format: "%.0f", (options.fusionVoxelSize ?? 0.02) * 1000))mm voxel into one — the same object seen from several angles collapses into a single, better-positioned surface instead of showing up in duplicate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Alignment (merged view)") {
                    Toggle("Re-align frames (ICP)", isOn: $options.useICPRefinement)
                    Text("Snaps each new frame against everything merged so far instead of trusting ARKit's pose alone — corrects small drift between frames. Only applies to \"All Frames (merged)\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Skip fast-motion frames", isOn: Binding(
                        get: { options.maxRotationRateAtCapture != nil },
                        set: { options.maxRotationRateAtCapture = $0 ? 1.5 : nil }
                    ))
                    if options.maxRotationRateAtCapture != nil {
                        LabeledContent("Max rotation rate") {
                            Slider(
                                value: Binding(
                                    get: { options.maxRotationRateAtCapture ?? 1.5 },
                                    set: { options.maxRotationRateAtCapture = $0 }
                                ),
                                in: 0.3...4.0
                            )
                        }
                        Text("Drops frames captured while the phone was rotating fast (from motion.csv) — likely motion-blurred. No effect on sessions recorded before motion.csv existed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let icpStats {
                        LabeledContent("Frames aligned", value: "\(icpStats.corrected) of \(icpStats.corrected + icpStats.uncorrected)")
                    }
                }

                if segments.count > 1 {
                    Section("Segments") {
                        Text("\(segments.count) spatially disjoint pieces — no shared surface was found between them, most often because the capture jumped to a new spot without scanning en route. No amount of alignment can truthfully merge pieces that don't observe anything in common.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("Highlight segments by color", isOn: $highlightSegments)
                        ForEach(segments) { segment in
                            HStack {
                                Circle()
                                    .fill(segmentColor(segment.index))
                                    .frame(width: 10, height: 10)
                                Text("Frames \(segment.startFrameID)–\(segment.endFrameID)")
                                Spacer()
                                Text("\(segment.frameCount) frames")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }

                Section("Navigation") {
                    Picker("Initial view", selection: $cameraFitMode) {
                        ForEach(CameraFitMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    Text("Eye-level starts from the average iPhone position during capture, looking level (no tilt) toward the farthest point scanned — the longest sightline in the room.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Zoom")
                        Spacer()
                        NavButton("minus.magnifyingglass") { cameraCommander.zoom(-0.4) }
                        NavButton("plus.magnifyingglass") { cameraCommander.zoom(0.4) }
                    }
                    LabeledContent("Orbit / tilt") {
                        DirectionalPad(
                            up: { cameraCommander.orbit(dx: 0, dy: -12) },
                            down: { cameraCommander.orbit(dx: 0, dy: 12) },
                            left: { cameraCommander.orbit(dx: -12, dy: 0) },
                            right: { cameraCommander.orbit(dx: 12, dy: 0) }
                        )
                    }
                    LabeledContent("Slide") {
                        // The camera itself moves in the pressed direction
                        // (like walking that way), so the scene appears to
                        // shift the opposite way on screen.
                        DirectionalPad(
                            symbols: ("arrow.up", "arrow.down", "arrow.left", "arrow.right"),
                            up: { cameraCommander.pan(dx: 0, dy: 0.15) },
                            down: { cameraCommander.pan(dx: 0, dy: -0.15) },
                            left: { cameraCommander.pan(dx: -0.15, dy: 0) },
                            right: { cameraCommander.pan(dx: 0.15, dy: 0) }
                        )
                    }
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
        .onChange(of: options.fusionVoxelSize) { rebuildPointCloud(refit: false) }
        .onChange(of: options.useICPRefinement) { rebuildPointCloud(refit: false) }
        .onChange(of: options.maxRotationRateAtCapture) { rebuildPointCloud(refit: false) }
        .onChange(of: cameraFitMode) { frameToken += 1 }
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
                    pointCloud: displayedPointCloud,
                    pointSize: pointSize,
                    showTrajectory: showTrajectory,
                    frameToken: frameToken,
                    fitMode: cameraFitMode,
                    commander: cameraCommander
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
        let opts = options
        isBuilding = true

        switch mode {
        case .single:
            let frame = session.depthFrames[safe: selectedFrameIndex]
            Task.detached(priority: .userInitiated) {
                var building = PointCloudData()
                if let frame {
                    PointCloudBuilder.build(frame: frame, options: opts, into: &building)
                }
                let finalResult = building
                await MainActor.run {
                    self.pointCloud = finalResult
                    self.icpStats = nil
                    self.segments = []
                    self.isBuilding = false
                    if refit { self.frameToken += 1 }
                }
            }
        case .merged:
            let frames = session.depthFrames
            Task.detached(priority: .userInitiated) {
                let (finalResult, aligned, unaligned, segments) = PointCloudBuilder.buildMergedSession(frames: frames, options: opts)
                await MainActor.run {
                    self.pointCloud = finalResult
                    self.icpStats = opts.useICPRefinement ? (aligned, unaligned) : nil
                    self.segments = segments
                    self.isBuilding = false
                    if refit { self.frameToken += 1 }
                }
            }
        }
    }

    private func segmentColor(_ index: Int) -> Color {
        let c = Colormap.segmentPalette[index % Colormap.segmentPalette.count]
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    /// The point cloud actually handed to the 3-D view: with segment
    /// highlighting on, each disjoint piece is tinted by its own color
    /// (brightness from the original shading preserved) so the "these don't
    /// actually connect" structure is visible at a glance instead of reading
    /// as one confusing blob.
    private var displayedPointCloud: PointCloudData {
        guard highlightSegments, segments.count > 1 else { return pointCloud }
        var tinted = pointCloud
        for segment in segments {
            let tint = Colormap.segmentPalette[segment.index % Colormap.segmentPalette.count]
            let upper = min(segment.pointRange.upperBound, tinted.colors.count)
            guard segment.pointRange.lowerBound < upper else { continue }
            for i in segment.pointRange.lowerBound..<upper {
                let orig = tinted.colors[i]
                let brightness = min(1, (orig.x + orig.y + orig.z) / 3 * 1.6)
                tinted.colors[i] = SIMD4<Float>(
                    min(1, tint.x * brightness), min(1, tint.y * brightness), min(1, tint.z * brightness), orig.w
                )
            }
        }
        return tinted
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A single small square icon button, sized consistently for `DirectionalPad`.
private struct NavButton: View {
    let systemImage: String
    let action: () -> Void

    init(_ systemImage: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
    }
}

/// Four discrete direction buttons (up/down/left/right) laid out in a plus
/// shape, for stepwise orbit/tilt or pan/slide control without needing a
/// trackpad gesture.
private struct DirectionalPad: View {
    var symbols: (up: String, down: String, left: String, right: String) = ("chevron.up", "chevron.down", "chevron.left", "chevron.right")
    let up: () -> Void
    let down: () -> Void
    let left: () -> Void
    let right: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            NavButton(symbols.up, action: up)
            HStack(spacing: 2) {
                NavButton(symbols.left, action: left)
                NavButton(symbols.right, action: right)
            }
            NavButton(symbols.down, action: down)
        }
    }
}

#Preview {
    ContentView()
}
