import Foundation
import Combine
import CoreLocation

/// Port of `MainActivity.getLocationText()`.
/// Android fell back to a hard-coded Beijing coordinate; we keep the same
/// fallback text so saved readings look consistent across platforms.
final class LocationService: NSObject, ObservableObject {

    static let fallbackText = "默认坐标 39.909,116.397"

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastLocation: CLLocation?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var statusText: String {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未授权"
        default: return "未知"
        }
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Starts one-shot location updates (used right before saving a reading).
    func refresh() {
        guard isAuthorized else { return }
        manager.requestLocation()
    }

    /// `GPS 30.206075,107.260199` or the fallback string.
    func currentLocationText() -> String {
        guard isAuthorized, let loc = lastLocation ?? manager.location else {
            return Self.fallbackText
        }
        return String(format: "GPS %.6f,%.6f", loc.coordinate.latitude, loc.coordinate.longitude)
    }

    /// Parses "GPS lat,lon" back out of a stored metadata string, for the UI.
    static func coordinate(from text: String) -> CLLocationCoordinate2D? {
        let trimmed = text.replacingOccurrences(of: "GPS ", with: "")
        let parts = trimmed.split(separator: ",")
        guard parts.count == 2,
              let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

extension LocationService: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isAuthorized { manager.requestLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last { lastLocation = last }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[MeterReader] location error: %@", error.localizedDescription)
    }
}
