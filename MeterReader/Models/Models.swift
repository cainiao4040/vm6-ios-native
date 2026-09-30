import Foundation

// MARK: - Live metrics

/// Port of `com.kmj.meterreader.LiveMetrics`.
struct LiveMetrics: Equatable {
    var connected = false

    var flowRate: Float = 0
    var pressure: Float = 0
    var temperature: Float = 0
    var total: Float = 0
    var flowCoefficient: Float = 9.99

    var hasFlowRate = false
    var hasPressure = false
    var hasTemperature = false
    var hasTotal = false
    var hasFlowCoefficient = true

    /// Value read back from the device during coefficient verification.
    var readBackCoefficient: Float = .nan
    var coefficientVerifyPending = false

    static let unavailable = "不可用"

    static func format(_ value: Float, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    var flowRateText: String { hasFlowRate ? Self.format(flowRate, 2) : Self.unavailable }
    var pressureText: String { hasPressure ? Self.format(pressure, 2) : Self.unavailable }
    var temperatureText: String { hasTemperature ? Self.format(temperature, 2) : Self.unavailable }
    var totalText: String { hasTotal ? Self.format(total, 2) : Self.unavailable }
    var flowCoefficientText: String { hasFlowCoefficient ? Self.format(flowCoefficient, 4) : Self.unavailable }

    /// One-line Chinese summary written into each saved reading.
    var summary: String {
        var s = "瞬时流量 " + (hasFlowRate ? Self.format(flowRate, 2) + " m³/h" : Self.unavailable)
        s += "，压力 " + (hasPressure ? Self.format(pressure, 2) + " kPa" : Self.unavailable)
        s += "，温度 " + (hasTemperature ? Self.format(temperature, 2) + " ℃" : Self.unavailable)
        s += "，累计流量 " + (hasTotal ? Self.format(total, 2) + " m³" : Self.unavailable)
        s += "，流量系数 " + (hasFlowCoefficient ? Self.format(flowCoefficient, 4) : Self.unavailable)
        return s
    }

    /// "瞬时流量 1.23 — 压力 45.60 — 温度 25.00 — 流量系数 9.9900"
    var paramDescription: String {
        var s = "瞬时流量 " + (hasFlowRate ? Self.format(flowRate, 2) : "—")
        s += " — 压力 " + (hasPressure ? Self.format(pressure, 2) : "—")
        s += " — 温度 " + (hasTemperature ? Self.format(temperature, 2) : "—")
        s += " — 流量系数 " + (hasFlowCoefficient ? Self.format(flowCoefficient, 4) : "—")
        return s
    }
}

// MARK: - Persisted entities

struct Meter: Identifiable, Hashable {
    var id: String
    var serialNumber: String = ""
    var displayName: String = ""
    var location: String = ""
    var type: String = ""
    var model: String = ""
    var status: String = ""
    var metadataJson: String = "{}"
    var lastSeenAt: String?
    var createdAt: String = ""
    var updatedAt: String = ""

    var isConnected: Bool { status == "connected" }

    /// `connectionPhase` / `rssi` pulled out of metadata_json.
    var connectionPhase: String {
        guard let data = metadataJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phase = obj["connectionPhase"] as? String else { return "unknown" }
        return phase
    }

    var rssi: Int? {
        guard let data = metadataJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let n = obj["rssi"] as? NSNumber { return n.intValue }
        return nil
    }
}

struct Reading: Identifiable, Hashable {
    var id: String
    var meterId: String
    var deviceId: String = ""
    var recordedAt: String = ""
    var receivedAt: String = ""
    var value: Double?          // nil == NaN in the original
    var unit: String = ""
    var source: String = ""
    var status: String = ""
    var notes: String = ""
    var rawPayloadJson: String = "null"
    var metadataJson: String = "null"
    var batteryLevel: Double?
    var signalStrength: Double?
    var flowRate: Double?
    var temperature: Double?
    var pressure: Double?
    var syncedAt: String = ""

    var valueText: String {
        guard let v = value, !v.isNaN else { return "—" }
        return String(format: "%.2f %@", v, unit)
    }

    var sourceText: String {
        var s: String
        switch source {
        case "manual": s = "手工"
        case "ble", "bluetooth": s = "蓝牙"
        default: s = source
        }
        if !notes.isEmpty { s += " · " + notes }
        return s
    }
}

struct MetricSnapshot: Identifiable, Hashable {
    var id: String
    var readingId: String
    var meterId: String
    var capturedAt: String = ""
    var metricKey: String = ""
    var valueText: String = ""
    var valueNumber: Double?
    var valueType: String = ""
    var unit: String = ""
    var source: String = ""
    var recordedBy: String = ""
    var description: String = ""
    var metadataJson: String = "null"
    var createdAt: String = ""

    /// Chinese label for known metric keys (mirrors the Flutter app's metric tiles).
    var displayName: String {
        if !description.isEmpty { return description }
        switch metricKey {
        case "flowRate", "flow_rate": return "瞬时流量"
        case "pressure": return "压力"
        case "temperature": return "温度"
        case "total": return "累计流量"
        case "flowCoefficient", "flow_coefficient": return "流量系数"
        case "instantaneousFlow": return "瞬时流量"
        default: return metricKey
        }
    }
}

struct SyncQueueItem: Identifiable, Hashable {
    var id: String
    var readingId: String
    var meterId: String = ""
    var status: String = "pending"
    var action: String = "upload"
    var payloadJson: String = "null"
    var createdAt: String = ""
    var syncedAt: String?
}

/// Flattened row for the "all readings" list (readings LEFT JOIN meters).
struct AllReading: Identifiable, Hashable {
    var id: String { readingId }
    var readingId: String
    var meterId: String
    var meterName: String
    var recordedAt: String
    var value: Double?
    var unit: String
    var source: String
    var notes: String

    var valueText: String {
        guard let v = value, !v.isNaN else { return "—" }
        return String(format: "%.2f %@", v, unit)
    }

    var sourceText: String {
        var s: String
        switch source {
        case "manual": s = "手工"
        case "ble", "bluetooth": s = "蓝牙"
        default: s = source
        }
        if !notes.isEmpty { s += " · " + notes }
        return s
    }
}

// MARK: - BLE scan result

struct DiscoveredDevice: Identifiable, Hashable {
    var id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date = Date()

    var displayName: String { name.isEmpty ? "未知设备" : name }
}

// MARK: - Date helpers

/// The Android app stamps records as `yyyy-MM-dd HH:mm:ss` in local time, and the
/// exported JSON uses `yyyy-MM-dd HH:mm:ss.SSS +0000 UTC`. We accept both.
enum Timestamps {
    static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func now() -> String { display.string(from: Date()) }

    /// Best-effort parse of any timestamp shape found in the app's data.
    static func parse(_ text: String) -> Date? {
        if let d = display.date(from: text) { return d }
        if let d = iso.date(from: text) { return d }
        let cleaned = text.replacingOccurrences(of: " +0000 UTC", with: "Z")
            .replacingOccurrences(of: " ", with: "T")
        if let d = iso.date(from: cleaned) { return d }
        return nil
    }

    /// "2026-04-09 13:51" — compact form used in list rows.
    static func short(_ text: String) -> String {
        guard let d = parse(text) else { return text }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    /// Groups readings by calendar day for the history screen.
    static func dayKey(_ text: String) -> String {
        guard let d = parse(text) else { return text }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
