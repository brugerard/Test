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
    /// Independent sequences — location and heading arrive asynchronously
    /// from each other and from everything else.
    var locationSampleIndex = 0
    var headingSampleIndex = 0

    /// Count of writes admitted via `beginWrite()` that haven't yet completed
    /// (including their `@Published` counter update). Gates admission of new
    /// writes (see `maxOutstandingWrites`) and lets `drainPendingWrites()`
    /// know when a session's writes are truly finished.
    var outstandingWrites = 0
    /// Continuations parked by `drainPendingWrites()` while `outstandingWrites`
    /// is still nonzero; resumed by `endWrite()` the moment it reaches zero.
    var drainWaiters: [CheckedContinuation<Void, Never>] = []
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
    @Published private(set) var locationSamplesWritten = 0
    @Published private(set) var headingSamplesWritten = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var diskWriteErrors = 0
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var currentSessionID: String?
    /// Directory of the most recently *completed* session, for the in-app
    /// Share button — a direct route to get recordings off the phone via
    /// AirDrop/Save to Files/Mail that doesn't depend on Finder or the Files
    /// app's "On My iPhone" discovery (which has proven unreliable in testing).
    @Published private(set) var lastCompletedSessionURL: URL?
    /// True from the moment STOP is tapped until every in-flight write for
    /// that session has finished and final `metadata.json` is on disk. While
    /// true, `startRecording()` refuses to start a new session — see its doc
    /// comment for why letting the two overlap would corrupt frame counts.
    @Published private(set) var isFinalizing = false

    /// Backpressure ceiling shared by every write category (an RGB+depth
    /// package, or a single motion/location/heading CSV row). `DataWriter` is
    /// an actor whose write methods have no internal suspension point, so it
    /// always processes exactly one write at a time regardless of category —
    /// this bounds how much *unstarted-or-in-flight* write work is allowed to
    /// queue up waiting for the actor's turn before a new frame is rejected
    /// (and correctly counted as dropped) instead of piling up retained
    /// `CVPixelBuffer`s indefinitely. ~2.4s of backlog at the default 5 fps
    /// continuous RGB+depth rate.
    private let maxOutstandingWrites = 12

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
    func startRecording(lidarAvailable: Bool, motionAvailable: Bool, locationAvailable: Bool, headingAvailable: Bool) -> Bool {
        guard !isRecording else { return false }
        // The previous session's writes may still be draining (see
        // `stopRecording()`/`drainPendingWrites()`). Starting a new session
        // now would share the same `@Published` counters and outstanding-
        // write accounting with the old session's still-in-flight writes,
        // corrupting both this session's frame counts and the old session's
        // final `metadata.json`. Refuse until that's finished.
        guard !isFinalizing else {
            lastErrorMessage = "Still finishing the previous recording — try again in a moment."
            return false
        }

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
        let locationCSVURL = sessionDirectoryURL.appendingPathComponent("sensors/location.csv")
        let headingCSVURL = sessionDirectoryURL.appendingPathComponent("sensors/heading.csv")
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
            try (LocationCSVRow.csvHeader + "\n").write(to: locationCSVURL, atomically: true, encoding: .utf8)
            try (HeadingCSVRow.csvHeader + "\n").write(to: headingCSVURL, atomically: true, encoding: .utf8)
        } catch {
            lastErrorMessage = "Failed to initialize session directories/CSV headers: \(error.localizedDescription)"
            return false
        }

        currentSessionLidarAvailable = lidarAvailable
        currentSessionMotionAvailable = motionAvailable
        currentSessionLocationAvailable = locationAvailable
        currentSessionHeadingAvailable = headingAvailable

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
            state.locationSampleIndex = 0
            state.headingSampleIndex = 0
        }

        isRecordingPublished = true
        currentSessionID = sessionID
        rgbFramesWritten = 0
        depthFramesWritten = 0
        motionSamplesWritten = 0
        locationSamplesWritten = 0
        headingSamplesWritten = 0
        droppedFrames = 0
        diskWriteErrors = 0
        lastErrorMessage = nil
        elapsedSeconds = 0
        elapsedTimerStartMonotonic = startMonotonic
        startElapsedTimer()

        let modeLabel = captureMode == .continuous ? "continuous" : "manual"
        let configuration = RecordingConfiguration(rgbCaptureRateHz: rgbCaptureRateHz, captureMode: modeLabel)
        let availability = SensorAvailability(
            camera: true,
            lidarSceneDepth: lidarAvailable,
            motion: motionAvailable,
            location: locationAvailable,
            heading: headingAvailable
        )
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
            let outcome = await dataWriter.writeJSON(metadata, to: sessionDirectoryURL.appendingPathComponent("metadata.json"))
            if !outcome.succeeded {
                await recordDiskError(outcome.error ?? "Failed to write start-of-session metadata.json")
            }
        }

        return true
    }

    func stopRecording() {
        guard isRecording else { return }

        let (sessionID, dirURL, startUTC) = stateLock.withLock { state -> (String, URL?, Date) in
            let result = (state.sessionID, state.sessionDirectoryURL, state.sessionStartUTC)
            state.isRecording = false
            state.latestFrameForManualCapture = nil
            return result
        }

        isRecordingPublished = false
        stopElapsedTimer()

        guard let dirURL else { return }
        isFinalizing = true
        let endUTC = Date()
        let availabilityAtStart = SensorAvailability(
            camera: true,
            lidarSceneDepth: currentSessionLidarAvailable,
            motion: currentSessionMotionAvailable,
            location: currentSessionLocationAvailable,
            heading: currentSessionHeadingAvailable
        )
        let modeLabel = captureMode == .continuous ? "continuous" : "manual"

        Task {
            // Wait for every write admitted before (or shortly after) STOP
            // was tapped to actually finish — including its counter update —
            // before reading final counts or writing metadata.json. Without
            // this, a frame captured just before STOP could still be
            // encoding when metadata.json is written, producing undercounted
            // frame totals and a "Share" button pointing at a session
            // directory that isn't fully on disk yet.
            await drainPendingWrites()
            let counts = await currentCountersSnapshot()

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
                frameCounts: FrameCounts(
                    rgbFramesWritten: counts.rgb,
                    depthFramesWritten: counts.depth,
                    motionSamplesWritten: counts.motion,
                    locationSamplesWritten: counts.location,
                    headingSamplesWritten: counts.heading
                ),
                droppedFrames: counts.dropped,
                diskWriteErrors: counts.errors,
                notes: "Finalized at STOP RECORDING, after draining all in-flight writes."
            )
            let outcome = await dataWriter.writeJSON(metadata, to: dirURL.appendingPathComponent("metadata.json"))
            if !outcome.succeeded {
                await recordDiskError(outcome.error ?? "Failed to write final metadata.json")
            }

            await MainActor.run {
                // Only now — after every file for this session is confirmed
                // on disk — is it safe to offer it via the Share button or
                // let a new recording start.
                self.lastCompletedSessionURL = dirURL
                self.isFinalizing = false
            }
        }
    }

    // MARK: - Write admission control / drain barrier
    //
    // See `maxOutstandingWrites`'s doc comment for why this — not
    // `DataWriter`'s old internal counter — is the real backpressure
    // mechanism. Every write-Task (RGB+depth package, or a single
    // motion/location/heading row) must bracket its work with
    // `beginWrite()`/`endWrite()`.

    /// Reserves one outstanding-write slot, or returns false if
    /// `maxOutstandingWrites` is already reached (caller should count the
    /// frame/sample as dropped and must not touch the buffer any further).
    private func beginWrite() -> Bool {
        stateLock.withLock { state in
            guard state.outstandingWrites < maxOutstandingWrites else { return false }
            state.outstandingWrites += 1
            return true
        }
    }

    /// Releases a slot reserved by `beginWrite()`. Callers must invoke this
    /// only after every `@Published` counter update for that write has
    /// already landed (i.e. after `await record...Outcome(...)` returns) —
    /// otherwise `drainPendingWrites()` could resume while a counter update
    /// is still in flight, and `stopRecording()` would read stale counts.
    private func endWrite() {
        let waiters: [CheckedContinuation<Void, Never>] = stateLock.withLock { state in
            state.outstandingWrites -= 1
            guard state.outstandingWrites == 0, !state.drainWaiters.isEmpty else { return [] }
            let pending = state.drainWaiters
            state.drainWaiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until every write admitted via `beginWrite()` has completed.
    /// `stopRecording()` awaits this before finalizing `metadata.json` or
    /// exposing the session to the Share button/a new recording.
    private func drainPendingWrites() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = stateLock.withLock { state in
                if state.outstandingWrites == 0 { return true }
                state.drainWaiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    /// Snapshot of LiDAR/motion availability taken at start, so
    /// `stopRecording()` can finalize metadata without needing a live
    /// reference to ARCaptureManager/MotionSensorManager.
    private var currentSessionLidarAvailable = false
    private var currentSessionMotionAvailable = false
    private var currentSessionLocationAvailable = false
    private var currentSessionHeadingAvailable = false

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
        guard beginWrite() else {
            Task { await recordDroppedFrame() }
            return
        }

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
            defer { endWrite() }

            let rgbOutcome = await dataWriter.writeRGBFrame(pixelBuffer: capturedImage, to: rgbURL)
            await recordRGBOutcome(rgbOutcome)

            let csvOutcome = await dataWriter.appendCSVLine(frameRow.csvLine(), to: framesCSVURL)
            if !csvOutcome.succeeded {
                await recordDiskError(csvOutcome.error ?? "Failed to append frames.csv row")
            }

            guard let depthMap else {
                await recordFrameHadNoDepth()
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
            await recordDepthOutcome(binOutcome: depthOutcome, jsonOutcome: jsonOutcome)
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

        guard beginWrite() else {
            Task { await recordDroppedFrame() }
            return
        }
        Task {
            defer { endWrite() }
            let outcome = await dataWriter.appendCSVLine(row.csvLine(), to: motionCSVURL)
            await recordMotionOutcome(outcome)
        }
    }

    // MARK: - Location / heading handling
    //
    // CLLocationManager delivers its delegate callbacks on whichever thread it
    // was started from — in this app, the main thread (LocationManager is
    // created as a SwiftUI @StateObject) — unlike ARKit's and Core Motion's
    // background queues. stateLock is thread-agnostic, so this is safe either
    // way; it's simply why these two methods may be entered from main.

    func handle(location sample: LocationSample) {
        struct LocationCaptureDecision {
            let sampleID: Int
            let sessionTime: TimeInterval
            let dirURL: URL
        }

        let decision: LocationCaptureDecision? = stateLock.withLock { state in
            guard state.isRecording, let dirURL = state.sessionDirectoryURL else { return nil }
            let sessionTime = sample.receivedAtMonotonic - state.sessionStartMonotonic
            state.locationSampleIndex += 1
            return LocationCaptureDecision(sampleID: state.locationSampleIndex, sessionTime: sessionTime, dirURL: dirURL)
        }

        guard let decision else { return }

        let row = LocationCSVRow(
            sampleID: decision.sampleID,
            sessionTimeSeconds: decision.sessionTime,
            systemMonotonicTime: sample.receivedAtMonotonic,
            utcTimestamp: Date(),
            nativeLocationTimestampUTC: sample.nativeTimestampUTC,
            latitude: sample.latitude,
            longitude: sample.longitude,
            altitude: sample.altitude,
            ellipsoidalAltitude: sample.ellipsoidalAltitude,
            horizontalAccuracy: sample.horizontalAccuracy,
            verticalAccuracy: sample.verticalAccuracy,
            speed: sample.speed,
            speedAccuracy: sample.speedAccuracy,
            course: sample.course,
            courseAccuracy: sample.courseAccuracy
        )
        let locationCSVURL = decision.dirURL.appendingPathComponent("sensors/location.csv")

        guard beginWrite() else {
            Task { await recordDroppedFrame() }
            return
        }
        Task {
            defer { endWrite() }
            let outcome = await dataWriter.appendCSVLine(row.csvLine(), to: locationCSVURL)
            await recordLocationOutcome(outcome)
        }
    }

    func handle(heading sample: HeadingSample) {
        struct HeadingCaptureDecision {
            let sampleID: Int
            let sessionTime: TimeInterval
            let dirURL: URL
        }

        let decision: HeadingCaptureDecision? = stateLock.withLock { state in
            guard state.isRecording, let dirURL = state.sessionDirectoryURL else { return nil }
            let sessionTime = sample.receivedAtMonotonic - state.sessionStartMonotonic
            state.headingSampleIndex += 1
            return HeadingCaptureDecision(sampleID: state.headingSampleIndex, sessionTime: sessionTime, dirURL: dirURL)
        }

        guard let decision else { return }

        let row = HeadingCSVRow(
            sampleID: decision.sampleID,
            sessionTimeSeconds: decision.sessionTime,
            systemMonotonicTime: sample.receivedAtMonotonic,
            utcTimestamp: Date(),
            nativeHeadingTimestampUTC: sample.nativeTimestampUTC,
            magneticHeading: sample.magneticHeading,
            trueHeading: sample.trueHeading,
            headingAccuracy: sample.headingAccuracy
        )
        let headingCSVURL = decision.dirURL.appendingPathComponent("sensors/heading.csv")

        guard beginWrite() else {
            Task { await recordDroppedFrame() }
            return
        }
        Task {
            defer { endWrite() }
            let outcome = await dataWriter.appendCSVLine(row.csvLine(), to: headingCSVURL)
            await recordHeadingOutcome(outcome)
        }
    }

    // MARK: - Counter updates
    //
    // All @MainActor: called with `await` from background write-Tasks, which
    // both publishes safely for SwiftUI and — critically — lets those Tasks
    // sequence their `endWrite()` call to run strictly after the counter
    // update actually lands, so `drainPendingWrites()` can never observe
    // "idle" while an update is still in flight. See `endWrite()`'s doc
    // comment.

    @MainActor
    private func recordRGBOutcome(_ outcome: DataWriter.WriteOutcome) {
        if outcome.succeeded {
            rgbFramesWritten += 1
        } else {
            diskWriteErrors += 1
            lastErrorMessage = outcome.error
        }
    }

    @MainActor
    private func recordDepthOutcome(binOutcome: DataWriter.WriteOutcome, jsonOutcome: DataWriter.WriteOutcome) {
        if binOutcome.succeeded && jsonOutcome.succeeded {
            depthFramesWritten += 1
        } else {
            diskWriteErrors += 1
            lastErrorMessage = binOutcome.error ?? jsonOutcome.error
        }
    }

    @MainActor
    private func recordMotionOutcome(_ outcome: DataWriter.WriteOutcome) {
        if outcome.succeeded {
            motionSamplesWritten += 1
        } else {
            diskWriteErrors += 1
            lastErrorMessage = outcome.error
        }
    }

    @MainActor
    private func recordLocationOutcome(_ outcome: DataWriter.WriteOutcome) {
        if outcome.succeeded {
            locationSamplesWritten += 1
        } else {
            diskWriteErrors += 1
            lastErrorMessage = outcome.error
        }
    }

    @MainActor
    private func recordHeadingOutcome(_ outcome: DataWriter.WriteOutcome) {
        if outcome.succeeded {
            headingSamplesWritten += 1
        } else {
            diskWriteErrors += 1
            lastErrorMessage = outcome.error
        }
    }

    @MainActor
    private func recordFrameHadNoDepth() {
        // Not an error — e.g. scene depth briefly unavailable for one frame.
        // depthFramesWritten simply doesn't increment for this frame.
    }

    /// A frame/sample rejected by `beginWrite()` because
    /// `maxOutstandingWrites` was already reached — disk I/O can't keep up
    /// with the capture rate. Distinct from `diskWriteErrors`: nothing failed,
    /// the sensor stream just outran the writer, and it's reported (never
    /// silently discarded) so the UI and `metadata.json` both show it.
    @MainActor
    private func recordDroppedFrame() {
        droppedFrames += 1
    }

    @MainActor
    private func recordDiskError(_ message: String) {
        diskWriteErrors += 1
        lastErrorMessage = message
    }

    /// Reads every frame/sample counter in one hop to the main actor, for
    /// `stopRecording()` to snapshot only after `drainPendingWrites()`
    /// confirms no writer Task can still be about to update one of them.
    @MainActor
    private func currentCountersSnapshot() -> (rgb: Int, depth: Int, motion: Int, location: Int, heading: Int, dropped: Int, errors: Int) {
        (rgbFramesWritten, depthFramesWritten, motionSamplesWritten, locationSamplesWritten, headingSamplesWritten, droppedFrames, diskWriteErrors)
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
