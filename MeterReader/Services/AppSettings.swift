import Foundation
import Combine

/// Replaces the Android `SharedPreferences("meter_reader")` store.
///
/// On Android the "target device" was a MAC address, which iOS cannot read.
/// We therefore persist the CoreBluetooth peripheral identifier (a per-iOS-install
/// UUID) as well as the advertised name, and match on name when the identifier
/// is unknown.
final class AppSettings: ObservableObject {

    private enum Key {
        static let targetName = "target_name"
        static let targetIdentifier = "target_identifier"
        static let hasLaunched = "has_launched_before"
        static let lastMeterId = "last_meter_id"
    }

    static let defaultDeviceName = "VM6-2120147-KMJ"

    private let defaults = UserDefaults.standard

    @Published var targetName: String {
        didSet { defaults.set(targetName, forKey: Key.targetName) }
    }

    @Published var targetIdentifier: String {
        didSet { defaults.set(targetIdentifier, forKey: Key.targetIdentifier) }
    }

    @Published var lastMeterId: String {
        didSet { defaults.set(lastMeterId, forKey: Key.lastMeterId) }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.hasLaunched) }
        set { defaults.set(newValue, forKey: Key.hasLaunched) }
    }

    init() {
        targetName = defaults.string(forKey: Key.targetName) ?? Self.defaultDeviceName
        targetIdentifier = defaults.string(forKey: Key.targetIdentifier) ?? ""
        lastMeterId = defaults.string(forKey: Key.lastMeterId) ?? ""
    }

    var targetIdentifierUUID: UUID? { UUID(uuidString: targetIdentifier) }

    /// "VM6-2120147-KMJ + 1A2B…" for the dashboard device line.
    var targetDisplay: String {
        let id = targetIdentifier.isEmpty ? "任意设备" : targetIdentifier
        return "\(targetName) + \(id)"
    }
}
