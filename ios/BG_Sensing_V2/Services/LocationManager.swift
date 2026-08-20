import Foundation
import CoreLocation
import Combine

/// One GPS fix, extracted synchronously in the delegate callback so
/// `RecordingSessionManager` never touches `CLLocation` directly.
///
/// `receivedAtMonotonic` is captured (via `ProcessInfo.processInfo.systemUptime`)
/// the instant this app's delegate callback fires — it approximates but is
/// not identical to when the fix was actually computed. `nativeTimestampUTC`
/// is `CLLocation`'s own timestamp: the fix's actual wall-clock time, which
/// can meaningfully lag `receivedAtMonotonic`-derived wall-clock time by the
/// GPS computation/delivery latency. Both are preserved — see
/// `SCIENTIFIC_DATA_FORMAT.md` §13 for why Core Location's timestamps need
/// this different treatment from ARKit/Core Motion's boot-relative ones.
struct LocationSample {
    let receivedAtMonotonic: TimeInterval
    let nativeTimestampUTC: Date
    let latitude: Double
    let longitude: Double
    /// Meters, referenced to mean sea level (CLLocation's traditional `altitude`).
    let altitude: Double
    /// Meters, referenced to the WGS84 ellipsoid — distinct from `altitude`
    /// above. `nil` if unavailable.
    let ellipsoidalAltitude: Double?
    /// Meters. Per Apple's convention, a negative value means invalid —
    /// preserved as-is, never discarded or clamped (spec: don't throw away
    /// poor-accuracy observations, record the accuracy instead).
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    /// Meters/second. Negative = invalid.
    let speed: Double
    let speedAccuracy: Double
    /// Degrees, relative to true north, 0..<360. Negative = invalid.
    let course: Double
    let courseAccuracy: Double
}

/// One compass heading update. Same timestamp-handling rationale as
/// `LocationSample`.
struct HeadingSample {
    let receivedAtMonotonic: TimeInterval
    let nativeTimestampUTC: Date
    /// Degrees, 0..<360. Negative = invalid.
    let magneticHeading: Double
    /// Degrees, 0..<360, corrected for magnetic declination — requires a
    /// valid location fix to compute. Negative = invalid (commonly the case
    /// right after starting, before the first location fix arrives).
    let trueHeading: Double
    let headingAccuracy: Double
}

enum LocationAuthorizationSummary: String {
    case notDetermined = "Not Determined"
    case denied = "Denied"
    case restricted = "Restricted"
    case authorized = "Authorized"
    case unknown = "Unknown"
}

/// Owns `CLLocationManager` and reports live GPS/heading status. Mirrors
/// `ARCaptureManager`/`MotionSensorManager`'s shape: runs continuously once
/// started (for the live status panel), and emits every update via
/// `locationHandler`/`headingHandler` regardless of recording state —
/// `RecordingSessionManager` decides whether to persist it.
final class LocationManager: NSObject, ObservableObject {

    var locationHandler: ((LocationSample) -> Void)?
    var headingHandler: ((HeadingSample) -> Void)?

    @Published private(set) var isLocationServicesEnabled = false
    @Published private(set) var isHeadingAvailable = false
    @Published private(set) var authorizationSummary: LocationAuthorizationSummary = .unknown
    @Published private(set) var isUpdating = false
    @Published private(set) var latestLocation: LocationSample?
    @Published private(set) var latestHeading: HeadingSample?
    @Published private(set) var lastError: String?

    private let manager = CLLocationManager()
    private var wantsToStart = false

    override init() {
        super.init()
        manager.delegate = self
        isHeadingAvailable = CLLocationManager.headingAvailable()
        authorizationSummary = Self.summarize(manager.authorizationStatus)

        // locationServicesEnabled() can touch disk; do it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let enabled = CLLocationManager.locationServicesEnabled()
            DispatchQueue.main.async {
                self?.isLocationServicesEnabled = enabled
            }
        }
    }

    func start() {
        wantsToStart = true

        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = kCLHeadingFilterNone
        manager.activityType = .other

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdating()
        case .denied, .restricted:
            lastError = "Location access denied or restricted. GPS/heading will not be recorded until it's allowed in Settings."
        @unknown default:
            break
        }
    }

    func stop() {
        wantsToStart = false
        manager.stopUpdatingLocation()
        if isHeadingAvailable {
            manager.stopUpdatingHeading()
        }
        isUpdating = false
    }

    private func beginUpdating() {
        manager.startUpdatingLocation()
        if isHeadingAvailable {
            manager.startUpdatingHeading()
        }
        isUpdating = true
        lastError = nil
    }

    private static func summarize(_ status: CLAuthorizationStatus) -> LocationAuthorizationSummary {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorizedWhenInUse, .authorizedAlways: return .authorized
        @unknown default: return .unknown
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async {
            self.authorizationSummary = Self.summarize(status)
        }

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            if wantsToStart {
                beginUpdating()
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.lastError = "Location access denied or restricted. GPS/heading will not be recorded until it's allowed in Settings."
                self.isUpdating = false
            }
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let receivedAt = ProcessInfo.processInfo.systemUptime
        guard let location = locations.last else { return }

        let sample = LocationSample(
            receivedAtMonotonic: receivedAt,
            nativeTimestampUTC: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            ellipsoidalAltitude: location.ellipsoidalAltitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            speedAccuracy: location.speedAccuracy,
            course: location.course,
            courseAccuracy: location.courseAccuracy
        )

        locationHandler?(sample)
        DispatchQueue.main.async {
            self.latestLocation = sample
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let receivedAt = ProcessInfo.processInfo.systemUptime

        let sample = HeadingSample(
            receivedAtMonotonic: receivedAt,
            nativeTimestampUTC: newHeading.timestamp,
            magneticHeading: newHeading.magneticHeading,
            trueHeading: newHeading.trueHeading,
            headingAccuracy: newHeading.headingAccuracy
        )

        headingHandler?(sample)
        DispatchQueue.main.async {
            self.latestHeading = sample
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.lastError = error.localizedDescription
        }
    }
}
