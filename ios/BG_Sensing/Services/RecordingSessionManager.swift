import Foundation
import os
import UIKit

/// How RecordingSessionManager decides which AR frames to capture to disk.
enum CaptureMode: String, Equatable, Hashable, CaseIterable {
    /// Auto-capture at `rgbCaptureRateHz`, throttled — the original behavior.
    case continuous = "Continuous"
    /// Capture nothing automatically; only `triggerManualCapture()` writes a
    /// frame. Intended for deliberate, stand-still, photogrammetry-style
    /// capture, which avoids the motion blur and heavy frame-to-frame
    /// overlap that continuous capture-while-walking produces.
    case manual = "Manual"
}

/// Mutable recording state shared between the main thread (start/stop/manual
/// trigger, called from SwiftUI button actions) and ARKit's background
/// delegate queue (every captured frame, via `handle(frame:)`). Everything
/// here is only ever touched through `RecordingSessionManager.stateLock`.
private struct RecordingState {
    var isRecording = false
    var sessionID = ""
    var sessionDirectoryURL: URL?
    /// Boot-relative monotonic time (same domain as `ARFrame.timestamp`) captured
    /// the instant recording started — this defines `sessionTimeSeconds == 0`.
    var sessionStartMonotonic: TimeInterval = 0
    var sessionStartUTC = Date()
    var frameIndex = 0
    var lastCaptureSessionTime: TimeInterval = -.greatestFiniteMagnitude
    /// In `.manual` capture mode, the most recent frame ARKit has delivered —
    /// refreshed on every `handle(frame:)` call but never auto-written.
    /// `triggerManualCapture()` writes whatever is cached here at the moment
    /// of the tap. Retaining only the single latest snapshot (not a queue)
    /// keeps this bounded regardless of how long the operator waits between
    /// taps.
    var latestFrameForManualCapture: ARFrameSnapshot?
    /// Independent of `frameIndex` — motion samples are numbered on their own
    /// sequence since they're written at a different (always-continuous) rate.
    var motionSampleIndex = 0
}

/// Owns the lifecycle of one recording session: creating the on-disk directory
/// structure, deciding which AR frames actually get captured (continuously
/// throttled, or one-at-a-time on operator trigger), dispatching writes to
/// `DataWriter`, and tracking live health counters for the UI.
///
/// Deliberately has no dependency on ARKit types beyond what arrives through
/// `ARFrameSnapshot` — it doesn't know or care that frames come from ARKit
/// specifically, only that it receives timestamped image/depth data.
final class RecordingSessionManager: ObservableObject {

    @Published private(set) var isRecordingPublished = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var rgbFramesWritten = 0
    @Published private(set) var depthFramesWritten = 0
    @Published private(set) var motionSamplesWritten = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var diskWriteErrors = 0
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var currentSessionID: String?
    /// Directory of the most recently *completed* session, for the in-app
    /// Share button — a direct route to get recordings off the phone via
    /// AirDrop/Save to Files/Mail that doesn't depend on Finder or the Files
    /// app's "On My iPhone" discovery (which has proven unreliable in testing).
    @Published private(set) var lastCompletedSessionURL: URL?

    /// RGB (and paired depth) capture rate in `.continuous` mode. Not
    /// `@Published` and not lock-protected: it's read from the background
    /// frame-handling path on every frame, so it's only safe to change before
    /// `startRecording()` — not mid-recording. A future settings UI should
    /// write it while stopped.
    var rgbCaptureRateHz: Double = 5.0

    /// Same thread-safety caveat as `rgbCaptureRateHz`: set before
    /// `startRecording()`, not mid-recording.
    var captureMode: CaptureMode = .continuous

    private let stateLock = OSAllocatedUnfairLock(initialState: RecordingState())
    private let dataWriter = DataWriter()
    private var elapsedTimer: Timer?
    private var elapsedTimerStartMonotonic: TimeInterval = 0

    var isRecording: Bool { stateLock.withLock { $0.isRecording } }

    // MARK: - Start / Stop (main thread — SwiftUI button actions)

    /// Returns false (with `lastErrorMessage` set) if recording could not start,
    /// e.g. insufficient disk space or a filesystem error.
    @discardableResult
    func startRecording(lidarAvailable: Bool, motionAvailable: Bool) -> Bool {
        guard !isRecording else { return false }

        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            lastErrorMessage = "Could not resolve app Documents directory."
            return false
        }

        if let freeBytes = try? documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, freeBytes < 200_000_000 {
            lastErrorMessage = "Low disk space (< 200 MB free). Free up space before recording."
            return false
        }

        let startUTC = Date()
        let uuidShort = String(UUID().uuidString.prefix(8))
        let folderFormatter = DateFormatter()
        folderFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        folderFormatter.timeZone = TimeZone.current
        let sessionID = "Session_\(folderFormatter.string(from: startUTC))_\(uuidShort)"
        let sessionDirectoryURL = documentsURL
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)

        let framesCSVURL = sessionDirectoryURL.appendingPathComponent("sensors/frames.csv")
        let motionCSVURL = sessionDirectoryURL.appendingPathComponent("sensors/motion.csv")
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: sessionDirectoryURL.appendingPathComponent("rgb"), withIntermediateDirectories: true)
            try fm.createDirectory(at: sessionDirectoryURL.appendingPathComponent("depth"), withIntermediateDirectories: true)
            try fm.createDirectory(at: sessionDirectoryURL.appendingPathComponent("sensors"), withIntermediateDirectories: true)
            // Written synchronously (not via the DataWriter actor) and BEFORE
            // `state.isRecording` flips true below, so the header is guaranteed
            // on disk before any frame-handling Task could possibly append a data
            // row — otherwise the two async writes could race and a data row
            // could land ahead of the header, corrupting the CSV.
            try (FrameCSVRow.csvHeader + "\n").write(to: framesCSVURL, atomically: true, encoding: .utf8)
            try (MotionCSVRow.csvHeader + "\n").write(to: motionCSVURL, atomically: true, encoding: .utf8)
        } catch {
            lastErrorMessage = "Failed to initialize session directories/CSV headers: \(error.localizedDescription)"
            return false
        }

        currentSessionLidarAvailable = lidarAvailable
        currentSessionMotionAvailable = motionAvailable

        let startMonotonic = ProcessInfo.processInfo.systemUptime
        stateLock.withLock { state in
            state.isRecording = true
            state.sessionID = sessionID
            state.sessionDirectoryURL = sessionDirectoryURL
            state.sessionStartMonotonic = startMonotonic
            state.sessionStartUTC = startUTC
            state.frameIndex = 0
            state.lastCaptureSessionTime = -.greatestFiniteMagnitude
            state.latestFrameForManualCapture = nil
            state.motionSampleIndex = 0
        }

        isRecordingPublished = true
        currentSessionID = sessionID
        rgbFramesWritten = 0
        depthFramesWritten = 0
        motionSamplesWritten = 0
        droppedFrames = 0
        diskWriteErrors = 0
        lastErrorMessage = nil
        elapsedSeconds = 0
        elapsedTimerStartMonotonic = startMonotonic
        startElapsedTimer()

        let modeLabel = captureMode == .continuous ? "continuous" : "manual"
        let configuration = RecordingConfiguration(rgbCaptureRateHz: rgbCaptureRateHz, captureMode: modeLabel)
        let availability = SensorAvailability(camera: true, lidarSceneDepth: lidarAvailable, motion: motionAvailable)
        Task {
            let metadata = SessionMetadata(
                appVersion: Self.appVersionString(),
                sessionID: sessionID,
                sessionStartUTC: ISO8601DateFormatter().string(from: startUTC),
                sessionEndUTC: nil,
                deviceHardwareIdentifier: DeviceInfo.hardwareIdentifier,
                systemVersion: UIDevice.current.systemVersion,
                recordingConfiguration: configuration,
                coordinateSystems: SessionMetadata.coordinateSystemDescriptions(),
                units: SessionMetadata.unitDescriptions(),
                sensorAvailability: availability,
                frameCounts: nil,
                droppedFrames: nil,
                diskWriteErrors: nil,
                notes: "Written at session start; overwritten with final counts when the session stops. If the app terminates mid-recording, this start-of-session copy — plus whatever frames were already written — still survives."
            )
            await dataWriter.writeJSON(metadata, to: sessionDirectoryURL.appendingPathComponent("metadata.json"))
        }

        return true
    }

    func stopRecording() {
        guard isRecording else { return }

        // Called from a SwiftUI button action (main thread), so reading the
        // @Published counters directly here is safe — no cross-thread race.
        let finalRGBCount = rgbFramesWritten
        let finalDepthCount = depthFramesWritten
        let finalMotionCount = motionSamplesWritten
        let finalDropped = droppedFrames
        let finalErrors = diskWriteErrors

        let (sessionID, dirURL, startUTC) = stateLock.withLock { state -> (String, URL?, Date) in
            let result = (state.sessionID, state.sessionDirectoryURL, state.sessionStartUTC)
            state.isRecording = false
            state.latestFrameForManualCapture = nil
            return result
        }

        isRecordingPublished = false
        stopElapsedTimer()

        guard let dirURL else { return }
        lastCompletedSessionURL = dirURL
        let endUTC = Date()
        let availabilityAtStart = SensorAvailability(
            camera: true,
            lidarSceneDepth: currentSessionLidarAvailable,
            motion: currentSessionMotionAvailable
        )
        let modeLabel = captureMode == .continuous ? "continuous" : "manual"

        Task {
            let metadata = SessionMetadata(
                appVersion: Self.appVersionString(),
                sessionID: sessionID,
                sessionStartUTC: ISO8601DateFormatter().string(from: startUTC),
                sessionEndUTC: ISO8601DateFormatter().string(from: endUTC),
                deviceHardwareIdentifier: DeviceInfo.hardwareIdentifier,
                systemVersion: UIDevice.current.systemVersion,
                recordingConfiguration: RecordingConfiguration(rgbCaptureRateHz: rgbCaptureRateHz, captureMode: modeLabel),
                coordinateSystems: SessionMetadata.coordinateSystemDescriptions(),
                units: SessionMetadata.unitDescriptions(),
                sensorAvailability: availabilityAtStart,
                frameCounts: FrameCounts(rgbFramesWritten: finalRGBCount, depthFramesWritten: finalDepthCount, motionSamplesWritten: finalMotionCount),
                droppedFrames: finalDropped,
                diskWriteErrors: finalErrors,
                notes: "Finalized at STOP RECORDING."
            )
            await dataWriter.writeJSON(metadata, to: dirURL.appendingPathComponent("metadata.json"))
        }
    }

    /// Snapshot of LiDAR/motion availability taken at start, so
    /// `stopRecording()` can finalize metadata without needing a live
    /// reference to ARCaptureManager/MotionSensorManager.
    private var currentSessionLidarAvailable = false
    private var currentSessionMotionAvailable = false

    // MARK: - Frame handling (ARKit background delegate queue)

    /// What was decided (by either the continuous throttle or a manual
    /// trigger) needs to actually get written — this is that decision,
    /// carrying the exact frame it applies to.
    private struct CaptureDecision {
        let frameIndex: Int
        let sessionTime: TimeInterval
        let dirURL: URL
        let frame: ARFrameSnapshot
    }

    func handle(frame: ARFrameSnapshot) {
        let decision: CaptureDecision? = stateLock.withLock { state in
            guard state.isRecording, let dirURL = state.sessionDirectoryURL else { return nil }

            switch captureMode {
            case .manual:
                // Cache only — triggerManualCapture() decides when to write.
                state.latestFrameForManualCapture = frame
                return nil
            case .continuous:
                let sessionTime = frame.nativeTimestamp - state.sessionStartMonotonic
                guard sessionTime - state.lastCaptureSessionTime >= (1.0 / rgbCaptureRateHz) else { return nil }
                state.frameIndex += 1
                state.lastCaptureSessionTime = sessionTime
                return CaptureDecision(frameIndex: state.frameIndex, sessionTime: sessionTime, dirURL: dirURL, frame: frame)
            }
        }

        guard let decision else { return }
        performCapture(decision)
    }

    /// Called from the "Capture" button (main thread) in `.manual` mode.
    /// Writes whatever frame ARKit most recently delivered. A no-op if not
    /// currently recording in manual mode, or if no frame has arrived yet
    /// (e.g. tapped in the first instant after Start).
    func triggerManualCapture() {
        let decision: CaptureDecision? = stateLock.withLock { state in
            guard
                state.isRecording,
                captureMode == .manual,
                let dirURL = state.sessionDirectoryURL,
                let frame = state.latestFrameForManualCapture
            else { return nil }

            let sessionTime = frame.nativeTimestamp - state.sessionStartMonotonic
            state.frameIndex += 1
            state.lastCaptureSessionTime = sessionTime
            return CaptureDecision(frameIndex: state.frameIndex, sessionTime: sessionTime, dirURL: dirURL, frame: frame)
        }

        guard let decision else { return }
        performCapture(decision)
    }

    private func performCapture(_ decision: CaptureDecision) {
        let frame = decision.frame
        let frameIDString = String(format: "%06d", decision.frameIndex)
        let utcTimestamp = Date()
        let dirURL = decision.dirURL

        let rgbURL = dirURL.appendingPathComponent("rgb/frame_\(frameIDString).heic")
        let depthBinURL = dirURL.appendingPathComponent("depth/depth_\(frameIDString).bin")
        let depthJSONURL = dirURL.appendingPathComponent("depth/depth_\(frameIDString).json")
        let confidenceBinURL = dirURL.appendingPathComponent("depth/confidence_\(frameIDString).bin")
        let framesCSVURL = dirURL.appendingPathComponent("sensors/frames.csv")

        let transformRowMajor = GeometryUtilities.rowMajor(frame.cameraTransform)
        let intrinsicsRowMajor = GeometryUtilities.rowMajor(frame.intrinsics)
        let hasDepth = frame.depthMap != nil

        let frameRow = FrameCSVRow(
            frameID: decision.frameIndex,
            sessionTimeSeconds: decision.sessionTime,
            systemMonotonicTime: frame.nativeTimestamp,
            utcTimestamp: utcTimestamp,
            nativeSensorTimestamp: frame.nativeTimestamp,
            imageWidth: frame.imageWidth,
            imageHeight: frame.imageHeight,
            // ARKit delivers capturedImage in the camera's native (landscape) sensor
            // orientation and does NOT rotate it for the app's UI orientation, even
            // though this app's UI is portrait-locked. Consumers must rotate ~90°
            // for portrait display; see SCIENTIFIC_DATA_FORMAT.md.
            orientation: "landscapeRight_rawSensor_unrotated",
            intrinsics: intrinsicsRowMajor,
            transform: transformRowMajor,
            trackingState: frame.trackingSummary.rawValue,
            correspondingDepthFrameID: hasDepth ? decision.frameIndex : nil
        )

        let capturedImage = frame.capturedImage
        let depthMap = frame.depthMap
        let confidenceMap = frame.confidenceMap
        let depthWidth = frame.depthWidth
        let depthHeight = frame.depthHeight
        let imageWidth = frame.imageWidth
        let imageHeight = frame.imageHeight

        Task {
            let rgbOutcome = await dataWriter.writeRGBFrame(pixelBuffer: capturedImage, to: rgbURL)
            recordRGBOutcome(rgbOutcome)

            let csvOutcome = await dataWriter.appendCSVLine(frameRow.csvLine(), to: framesCSVURL)
            if !csvOutcome.succeeded {
                recordDiskError(csvOutcome.error ?? "Failed to append frames.csv row")
            }

            guard let depthMap else {
                recordFrameHadNoDepth()
                return
            }

            let scaleX = imageWidth > 0 ? Float(depthWidth) / Float(imageWidth) : 1
            let scaleY = imageHeight > 0 ? Float(depthHeight) / Float(imageHeight) : 1
            let depthIntrinsics = GeometryUtilities.scaledIntrinsics(intrinsicsRowMajor, scaleX: scaleX, scaleY: scaleY)

            let depthMeta = DepthFrameMetadata(
                depthFrameID: decision.frameIndex,
                sessionTimeSeconds: decision.sessionTime,
                systemMonotonicTime: frame.nativeTimestamp,
                utcTimestamp: ISO8601DateFormatter().string(from: utcTimestamp),
                nativeSensorTimestamp: frame.nativeTimestamp,
                width: depthWidth,
                height: depthHeight,
                dataType: "Float32",
                byteOrder: "littleEndian",
                units: "meters",
                depthType: "raw_sceneDepth",
                hasConfidence: confidenceMap != nil,
                intrinsics: depthIntrinsics,
                intrinsicsNote: "Scaled from the RGB frame's intrinsics (scaleX=\(scaleX), scaleY=\(scaleY)) to this depth map's resolution. Do not use the RGB frame's own intrinsics on this depth map.",
                transform: transformRowMajor,
                correspondingRGBFrameID: decision.frameIndex
            )

            let depthOutcome = await dataWriter.writeDepthFrame(
                depthMap: depthMap,
                confidenceMap: confidenceMap,
                binURL: depthBinURL,
                confidenceURL: confidenceMap != nil ? confidenceBinURL : nil
            )
            let jsonOutcome = await dataWriter.writeJSON(depthMeta, to: depthJSONURL)
            recordDepthOutcome(binOutcome: depthOutcome, jsonOutcome: jsonOutcome)
        }
    }

    // MARK: - Motion handling (Core Motion update queue)

    /// Motion always records at whatever rate `MotionSensorManager` delivers
    /// (~50 Hz) regardless of `captureMode` — unlike RGB/depth, motion
    /// samples are cheap and the whole point is dense, continuous tracking.
    func handle(motion sample: MotionSample) {
        struct MotionCaptureDecision {
            let sampleID: Int
            let sessionTime: TimeInterval
            let dirURL: URL
        }

        let decision: MotionCaptureDecision? = stateLock.withLock { state in
            guard state.isRecording, let dirURL = state.sessionDirectoryURL else { return nil }
            let sessionTime = sample.nativeTimestamp - state.sessionStartMonotonic
            state.motionSampleIndex += 1
            return MotionCaptureDecision(sampleID: state.motionSampleIndex, sessionTime: sessionTime, dirURL: dirURL)
        }

        guard let decision else { return }

        let row = MotionCSVRow(
            sampleID: decision.sampleID,
            sessionTimeSeconds: decision.sessionTime,
            systemMonotonicTime: sample.nativeTimestamp,
            utcTimestamp: Date(),
            nativeSensorTimestamp: sample.nativeTimestamp,
            attitudeReferenceFrame: sample.referenceFrame.rawValue,
            roll: sample.roll,
            pitch: sample.pitch,
            yaw: sample.yaw,
            quaternionX: sample.quaternionX,
            quaternionY: sample.quaternionY,
            quaternionZ: sample.quaternionZ,
            quaternionW: sample.quaternionW,
            rotationMatrix: sample.rotationMatrix,
            userAccelerationX: sample.userAccelerationX,
            userAccelerationY: sample.userAccelerationY,
            userAccelerationZ: sample.userAccelerationZ,
            gravityX: sample.gravityX,
            gravityY: sample.gravityY,
            gravityZ: sample.gravityZ,
            rotationRateX: sample.rotationRateX,
            rotationRateY: sample.rotationRateY,
            rotationRateZ: sample.rotationRateZ,
            magneticFieldX: sample.magneticFieldX,
            magneticFieldY: sample.magneticFieldY,
            magneticFieldZ: sample.magneticFieldZ,
            magneticFieldCalibrationAccuracy: sample.magneticFieldCalibrationAccuracy
        )
        let motionCSVURL = decision.dirURL.appendingPathComponent("sensors/motion.csv")

        Task {
            let outcome = await dataWriter.appendCSVLine(row.csvLine(), to: motionCSVURL)
            recordMotionOutcome(outcome)
        }
    }

    // MARK: - Counter updates (always hopped to main thread)

    private func recordRGBOutcome(_ outcome: DataWriter.WriteOutcome) {
        DispatchQueue.main.async {
            if outcome.succeeded {
                self.rgbFramesWritten += 1
            } else if outcome.dropped {
                self.droppedFrames += 1
            } else {
                self.diskWriteErrors += 1
                self.lastErrorMessage = outcome.error
            }
        }
    }

    private func recordDepthOutcome(binOutcome: DataWriter.WriteOutcome, jsonOutcome: DataWriter.WriteOutcome) {
        DispatchQueue.main.async {
            if binOutcome.succeeded && jsonOutcome.succeeded {
                self.depthFramesWritten += 1
            } else if binOutcome.dropped || jsonOutcome.dropped {
                self.droppedFrames += 1
            } else {
                self.diskWriteErrors += 1
                self.lastErrorMessage = binOutcome.error ?? jsonOutcome.error
            }
        }
    }

    private func recordMotionOutcome(_ outcome: DataWriter.WriteOutcome) {
        DispatchQueue.main.async {
            if outcome.succeeded {
                self.motionSamplesWritten += 1
            } else if outcome.dropped {
                self.droppedFrames += 1
            } else {
                self.diskWriteErrors += 1
                self.lastErrorMessage = outcome.error
            }
        }
    }

    private func recordFrameHadNoDepth() {
        // Not an error — e.g. scene depth briefly unavailable for one frame.
        // depthFramesWritten simply doesn't increment for this frame.
    }

    private func recordDiskError(_ message: String) {
        DispatchQueue.main.async {
            self.diskWriteErrors += 1
            self.lastErrorMessage = message
        }
    }

    // MARK: - Elapsed time (main thread UI timer)

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsedSeconds = ProcessInfo.processInfo.systemUptime - self.elapsedTimerStartMonotonic
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private static func appVersionString() -> String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(shortVersion) (\(build))"
    }
}
