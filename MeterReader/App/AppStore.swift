import Foundation
import SwiftUI
import Combine
import CoreBluetooth

/// Ties together storage, BLE, location and settings — the iOS equivalent of
/// `MainActivity`'s wiring, exposed to SwiftUI as a single observable store.
final class AppStore: ObservableObject {

    let db = AppDatabase.shared
    let settings: AppSettings
    let ble = BleService()
    let location = LocationService()

    // Lists
    @Published private(set) var meters: [Meter] = []
    @Published private(set) var allReadings: [AllReading] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var pendingList: [String] = []

    // Capture form
    @Published var coefficientInput: String = ""
    @Published var notesInput: String = ""
    @Published var captureMeterId: String = ""

    // Feedback
    @Published var toast: String?
    @Published var lastCaptureSummary: String?
    @Published var showSplash: Bool = true

    /// Set when a coefficient write completes, so the UI can highlight the result.
    @Published var coefficientResult: (success: Bool, message: String)?

    private var cancellables = Set<AnyCancellable>()
    private var toastWorkItem: DispatchWorkItem?

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings

        db.seedIfEmpty()
        captureMeterId = settings.lastMeterId.isEmpty ? "offline-manual" : settings.lastMeterId
        reload()

        ble.onCoefficientVerified = { [weak self] success, written, readBack, message in
            guard let self = self else { return }
            if success {
                self.showToast("校验通过: " + String(format: "%.4f", readBack))
            } else {
                self.showToast("写入失败: \(message)（写入 \(String(format: "%.4f", written))，回读 \(readBack.isNaN ? "无响应" : String(format: "%.4f", readBack))）")
            }
            self.coefficientResult = (success, message)
        }

        // Surface BLE errors as toasts, like the Android Toast calls.
        ble.$lastError
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.showToast(message) }
            .store(in: &cancellables)

        // Persist connection state onto the selected meter row.
        ble.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self = self else { return }
                self.updateMeterConnectionState(connected: connected)
            }
            .store(in: &cancellables)
    }

    // MARK: - Loading

    func reload() {
        meters = db.listMeters()
        allReadings = db.listAllReadings()
        refreshSyncInfo()
        if captureMeterId.isEmpty {
            captureMeterId = meters.first?.id ?? "offline-manual"
        }
    }

    func refreshSyncInfo() {
        pendingCount = db.countPendingSync()
        pendingList = db.listPendingSync()
    }

    var syncDescription: String {
        pendingCount > 0
            ? "当前有 \(pendingCount) 条任务等待同步到后台。"
            : "当前没有待同步数据。"
    }

    func meter(withId id: String) -> Meter? { meters.first { $0.id == id } }

    func meterDisplayName(_ id: String) -> String {
        meter(withId: id)?.displayName ?? id
    }

    /// "离线手工抄表" for the synthetic meter, otherwise "MAC <id>".
    func meterDescription(_ id: String) -> String {
        if id.contains("offline-manual") { return "离线手工抄表" }
        return "MAC " + id
    }

    // MARK: - Toast

    func showToast(_ message: String) {
        toast = message
        toastWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation { self?.toast = nil }
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: work)
    }

    // MARK: - Connection

    private func updateMeterConnectionState(connected: Bool) {
        let id = captureMeterId
        guard !id.isEmpty, var meter = db.meter(withId: id) else { return }
        var meta: [String: Any] = [:]
        if let data = meter.metadataJson.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            meta = obj
        }
        meta["connectionPhase"] = connected ? "connected" : "disconnected"
        if connected, let device = ble.devices.first(where: { $0.id == ble.lastConnectedIdentifier }) {
            meta["rssi"] = device.rssi
        }
        meter.status = connected ? "connected" : "offline"
        meter.metadataJson = (try? JSONSerialization.data(withJSONObject: meta))
            .flatMap { String(data: $0, encoding: .utf8) } ?? meter.metadataJson
        meter.lastSeenAt = Timestamps.now()
        db.upsertMeter(meter)
        reload()
    }

    /// "选择设备" → scan picker.
    func beginScan() {
        ble.startScan()
    }

    func connect(to device: DiscoveredDevice) {
        settings.targetIdentifier = device.id.uuidString
        if !device.name.isEmpty { settings.targetName = device.name }
        captureMeterId = db.ensureMeter(id: meterIdForDevice(device),
                                        displayName: device.displayName).id
        settings.lastMeterId = captureMeterId
        ble.connect(to: device)
        showToast("正在连接 \(device.displayName) …")
        reload()
    }

    /// Prefer a meter row keyed by an explicit MAC/identifier the user configured,
    /// so readings keep landing on the same meter as the Android build.
    private func meterIdForDevice(_ device: DiscoveredDevice) -> String {
        let configured = settings.targetIdentifier
        if !configured.isEmpty, configured.contains(":"), db.meter(withId: configured) != nil {
            return configured
        }
        return device.id.uuidString
    }

    /// "刷新实时值"
    func refreshLiveValues() {
        guard ble.isConnected else {
            showToast("未连接，尝试直连目标设备")
            if let id = settings.targetIdentifierUUID {
                ble.connect(identifier: id, name: settings.targetName)
            } else {
                beginScan()
            }
            return
        }
        ble.refreshNow()
    }

    // MARK: - Coefficient

    func writeCoefficient() {
        let trimmed = coefficientInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast("请输入流量系数")
            return
        }
        guard let value = Float(trimmed) else {
            showToast("系数格式非法")
            return
        }
        ble.pushFlowCoefficient(value)
    }

    // MARK: - Capture

    /// `MainActivity.saveReading()`.
    func saveReading() {
        let metrics = ble.metrics
        guard ble.isConnected || metrics.hasFlowRate || metrics.hasTotal else {
            showToast("尚未获取到实时值，请先连接设备")
            return
        }

        let recordedAt = Timestamps.now()
        let locationText = location.currentLocationText()
        let notes = notesInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let meterId = captureMeterId.isEmpty ? "offline-manual" : captureMeterId

        db.ensureMeter(id: meterId,
                       displayName: meterDisplayName(meterId),
                       extra: ["connectionPhase": ble.isConnected ? "connected" : "disconnected"])

        let deviceId = ble.lastConnectedIdentifier?.uuidString ?? settings.targetIdentifier
        db.addBluetoothReading(meterId: meterId,
                               deviceId: deviceId.isEmpty ? meterId : deviceId,
                               recordedAt: recordedAt,
                               metrics: metrics,
                               notes: notes,
                               location: locationText)

        settings.lastMeterId = meterId
        lastCaptureSummary = metrics.summary
        notesInput = ""
        refreshSyncInfo()
        reload()
        showToast("已抄表并进入同步队列\n" + metrics.summary)
    }

    /// Offline manual reading used by the meter detail screen.
    func addManualReading(meterId: String, valueText: String, notes: String) -> Bool {
        let trimmed = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed) else {
            showToast("请输入有效数值")
            return false
        }
        db.ensureMeter(id: meterId, displayName: meterDisplayName(meterId))
        db.addManualReading(meterId: meterId, recordedAt: Timestamps.now(), value: value, notes: notes)
        reload()
        showToast("已保存离线抄表记录")
        return true
    }

    func deleteReading(_ reading: Reading) {
        db.deleteReading(id: reading.id)
        reload()
        showToast("已删除该条读数")
    }

    func markAllSynced() {
        db.markAllSynced()
        reload()
        showToast("已将待同步任务标记为完成")
    }

    // MARK: - Export / import

    func exportData() -> URL? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeterReaderExport", isDirectory: true)
        db.exportAll(to: dir)
        return dir
    }

    func importData(from directory: URL) {
        for table in ["meters", "readings", "metric_snapshots"] {
            let url = directory.appendingPathComponent("\(table).json")
            guard let data = try? Data(contentsOf: url),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            db.importRows(rows, into: table)
        }
        reload()
        showToast("导入完成")
    }
}
