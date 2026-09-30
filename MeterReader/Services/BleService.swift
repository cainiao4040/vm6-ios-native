import Foundation
import Combine
import CoreBluetooth

/// Port of `com.kmj.meterreader.BleService` onto CoreBluetooth.
///
/// Behavioural contract kept identical to the Android original:
///  * same service/characteristic UUIDs,
///  * same 3 s poll loop (0x47 realtime, then 0x03 coefficient readback),
///  * same 900 ms per-operation timeout that advances the poll slot,
///  * same write-then-readback coefficient verification with the
///    `max(1e-4, |value| * 0.001)` tolerance.
final class BleService: NSObject, ObservableObject {

    // MARK: - UUIDs

    static let writeCharUUID = CBUUID(string: "0000FFE9-0000-1000-8000-00805F9B34FB")
    static let notifyCharUUIDs: [CBUUID] = [
        CBUUID(string: "0000FFE4-0000-1000-8000-00805F9B34FB"),
        CBUUID(string: "0000FFA1-0000-1000-8000-00805F9B34FB"),
    ]
    static let cccdUUID = CBUUID(string: "00002902-0000-1000-8000-00805F9B34FB")

    // MARK: - Constants

    static let pollInterval: TimeInterval = 3.0
    static let opTimeout: TimeInterval = 0.9
    static let defaultCoefficient: Float = 9.99

    // MARK: - Published state

    @Published private(set) var metrics = LiveMetrics()
    @Published private(set) var isScanning = false
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var connectedName: String = ""
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    @Published private(set) var log: [String] = []

    /// Called on the main queue after a coefficient write + verification attempt.
    var onCoefficientVerified: ((_ success: Bool, _ written: Float, _ readBack: Float, _ message: String) -> Void)?

    // MARK: - Private

    private enum OpMode { case idle, poll, coeffWrite, coeffVerify }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristics: [CBCharacteristic] = []

    private var opMode: OpMode = .idle
    private var pollSlot = 0
    private var pendingCoefficient: Float = .nan
    private var responseBuffer: [UInt8] = []

    private var pollTimer: Timer?
    private var opTimeoutTimer: Timer?

    private static let pollCommands: [[UInt8]] = [
        A5Protocol.readRealtime(),
        A5Protocol.readHolding(A5Protocol.regCoeff, 2),
    ]

    private var pendingScan = false
    private var pendingConnect: (identifier: UUID, name: String)?

    /// The peripheral we most recently connected to, so settings can reconnect.
    private(set) var lastConnectedIdentifier: UUID?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Derived state

    var isSupported: Bool { bluetoothState == .poweredOn }

    var bluetoothStateText: String {
        switch bluetoothState {
        case .poweredOn: return "已开启"
        case .poweredOff: return "未开启"
        case .unauthorized: return "无权限"
        case .unsupported: return "不支持"
        case .resetting: return "重置中"
        default: return "未知"
        }
    }

    var statusText: String {
        isConnected ? "蓝牙:connected · \(connectedName)" : "蓝牙:disconnected"
    }

    private func note(_ message: String) {
        NSLog("[MeterReader] %@", message)
        log.append(message)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    private func fail(_ message: String) {
        note("ERROR: \(message)")
        lastError = message
    }

    // MARK: - Scanning

    func startScan() {
        guard bluetoothState == .poweredOn else {
            pendingScan = true
            fail("蓝牙未就绪（\(bluetoothStateText)），请先开启蓝牙")
            return
        }
        stopScan()
        devices.removeAll()
        isScanning = true
        note("开始扫描附近蓝牙表具…")
        // Nil service filter: the meter does not advertise its service UUID.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        if central.isScanning { central.stopScan() }
        if isScanning {
            isScanning = false
            note("停止扫描")
        }
    }

    // MARK: - Connection

    func connect(to device: DiscoveredDevice) {
        connect(identifier: device.id, name: device.displayName)
    }

    func connect(identifier: UUID, name: String) {
        guard bluetoothState == .poweredOn else {
            pendingConnect = (identifier, name)
            fail("蓝牙未就绪（\(bluetoothStateText)），请先开启蓝牙")
            return
        }
        stopScan()
        teardown()

        let targets = central.retrievePeripherals(withIdentifiers: [identifier])
        guard let target = targets.first else {
            fail("未找到设备（iOS 标识 \(identifier.uuidString)）。请重新扫描后再连接。")
            return
        }
        connectedName = name.isEmpty ? "未知设备" : name
        note("正在连接 \(connectedName) …")
        peripheral = target
        target.delegate = self
        central.connect(target, options: nil)
    }

    /// Reconnects to a previously used peripheral without rescanning.
    func reconnectLast() {
        guard let id = lastConnectedIdentifier else {
            fail("没有可重连的历史设备，请先扫描并连接一次")
            return
        }
        connect(identifier: id, name: connectedName)
    }

    func disconnect() {
        teardown()
        markDisconnected("已断开")
    }

    /// Stops polling/scanning and drops the GATT link — `BleService.teardown`.
    func teardown() {
        stopPolling()
        stopScan()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristics.removeAll()
        isConnected = false
        metrics.connected = false
        responseBuffer.removeAll()
    }

    private func markDisconnected(_ reason: String) {
        metrics.connected = false
        isConnected = false
        connectedName = ""
        note("连接断开: \(reason)")
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.isConnectedStrict, self.opMode == .idle else { return }
            self.pollSlot = 0
            self.sendWrite(Self.pollCommands[0])
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        note("已连接，开始 3 秒轮询实时值")
    }

    private func stopPolling() {
        pollTimer?.invalidate(); pollTimer = nil
        opTimeoutTimer?.invalidate(); opTimeoutTimer = nil
        opMode = .idle
        pollSlot = 0
    }

    private var isConnectedStrict: Bool {
        peripheral != nil && metrics.connected && writeCharacteristic != nil
    }

    /// Manual "刷新实时值" — behaves like the Android refresh button.
    func refreshNow() {
        guard isConnectedStrict else {
            fail("未连接，无法刷新")
            return
        }
        guard opMode == .idle else {
            note("当前有读写任务进行中，请稍候")
            return
        }
        pollSlot = 0
        sendWrite(Self.pollCommands[0])
    }

    // MARK: - Writing

    private func sendWrite(_ bytes: [UInt8]) {
        guard let p = peripheral, let ch = writeCharacteristic else { return }
        responseBuffer.removeAll()
        p.writeValue(Data(bytes), for: ch, type: .withResponse)
        note("TX \(A5Protocol.hex(bytes))")
        armOpTimeout()
    }

    private func armOpTimeout() {
        opTimeoutTimer?.invalidate()
        let t = Timer(timeInterval: Self.opTimeout, repeats: false) { [weak self] _ in
            self?.handleOpTimeout()
        }
        RunLoop.main.add(t, forMode: .common)
        opTimeoutTimer = t
    }

    /// `BleService.opTimeout` — advances to the next poll command, or fails the
    /// coefficient operation.
    private func handleOpTimeout() {
        switch opMode {
        case .poll:
            pollSlot += 1
            if pollSlot < Self.pollCommands.count {
                sendWrite(Self.pollCommands[pollSlot])
            } else {
                opMode = .idle
            }
        case .coeffWrite, .coeffVerify:
            let written = pendingCoefficient
            opMode = .idle
            notifyCoefficient(success: false, written: written, readBack: .nan,
                              message: "写入/校验超时，请重试")
        case .idle:
            break
        }
    }

    // MARK: - Coefficient

    /// Write the flow coefficient and read it back to verify.
    func pushFlowCoefficient(_ value: Float) {
        guard isConnectedStrict else {
            fail("未连接设备，无法写入")
            return
        }
        guard opMode == .idle else {
            fail("当前有读写任务进行中，请稍候")
            return
        }
        pendingCoefficient = value
        opMode = .coeffWrite
        sendWrite(A5Protocol.writeCoeff(value))
        note("正在写入流量系数 \(value) 并回读校验…")
    }

    private func notifyCoefficient(success: Bool, written: Float, readBack: Float, message: String) {
        note("系数校验\(success ? "通过" : "失败"): \(message)")
        onCoefficientVerified?(success, written, readBack, message)
    }

    // MARK: - Notification handling

    /// `BleService.handleNotify` plus a reassembly buffer, because CoreBluetooth
    /// can deliver a 24-byte A5 frame split across notifications (the meter's
    /// MTU is 20 bytes on some phones).
    private func handleNotify(_ bytes: [UInt8]) {
        note("RX \(A5Protocol.hex(bytes))")
        responseBuffer.append(contentsOf: bytes)
        if responseBuffer.count > 512 { responseBuffer.removeFirst(responseBuffer.count - 512) }

        switch opMode {
        case .idle:
            // Unsolicited notification — clear stale bytes so they cannot be
            // mistaken for the next response.
            responseBuffer.removeAll()

        case .poll:
            if pollSlot == 0 {
                guard let frame = A5Protocol.extractFrame(responseBuffer, A5Protocol.funcReadRealtime),
                      let values = A5Protocol.parseRealtime(frame) else { return }
                responseBuffer.removeAll()
                applyRealtime(values)
                pollSlot += 1
                if pollSlot < Self.pollCommands.count {
                    sendWrite(Self.pollCommands[pollSlot])
                } else {
                    opMode = .idle
                    opTimeoutTimer?.invalidate()
                }
            } else {
                guard let frame = A5Protocol.extractFrame(responseBuffer, A5Protocol.funcReadHolding),
                      let coeff = A5Protocol.parseHoldingFloat(frame) else { return }
                responseBuffer.removeAll()
                metrics.flowCoefficient = coeff
                metrics.readBackCoefficient = coeff
                metrics.hasFlowCoefficient = true
                opMode = .idle
                opTimeoutTimer?.invalidate()
            }

        case .coeffWrite:
            guard A5Protocol.extractFrame(responseBuffer, A5Protocol.funcWriteMulti) != nil else { return }
            responseBuffer.removeAll()
            opMode = .coeffVerify
            sendWrite(A5Protocol.readHolding(A5Protocol.regCoeff, 2))

        case .coeffVerify:
            guard let frame = A5Protocol.extractFrame(responseBuffer, A5Protocol.funcReadHolding),
                  let readBack = A5Protocol.parseHoldingFloat(frame) else { return }
            responseBuffer.removeAll()
            let tolerance = max(1.0e-4, abs(pendingCoefficient) * 0.001)
            if abs(readBack - pendingCoefficient) <= tolerance {
                metrics.flowCoefficient = readBack
                metrics.readBackCoefficient = readBack
                metrics.hasFlowCoefficient = true
                let written = pendingCoefficient
                opMode = .idle
                opTimeoutTimer?.invalidate()
                notifyCoefficient(success: true, written: written, readBack: readBack, message: "校验通过")
            } else {
                let written = pendingCoefficient
                opMode = .idle
                opTimeoutTimer?.invalidate()
                notifyCoefficient(success: false, written: written, readBack: readBack,
                                  message: "校验不一致(设备返回 " + String(format: "%.4f", readBack) + ")")
            }
        }
    }

    /// `BleService.applyRealtime` — value order is defined by the firmware.
    private func applyRealtime(_ v: [Float]) {
        if v.count >= 1 { metrics.flowRate = v[0]; metrics.hasFlowRate = true }
        if v.count >= 2 { metrics.pressure = v[1]; metrics.hasPressure = true }
        if v.count >= 3 { metrics.temperature = v[2]; metrics.hasTemperature = true }
        if v.count >= 4 { metrics.total = v[3]; metrics.hasTotal = true }
        if v.count >= 5 { metrics.flowCoefficient = v[4]; metrics.hasFlowCoefficient = true }
    }

    // MARK: - Discovery helpers

    private func locateCharacteristics() {
        guard let p = peripheral else { return }
        writeCharacteristic = nil
        notifyCharacteristics.removeAll()

        for service in p.services ?? [] {
            for ch in service.characteristics ?? [] {
                if ch.uuid == Self.writeCharUUID { writeCharacteristic = ch }
                if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                    notifyCharacteristics.append(ch)
                }
            }
        }

        // Fallback: any writable characteristic, matching the Android behaviour.
        if writeCharacteristic == nil {
            for service in p.services ?? [] {
                for ch in service.characteristics ?? [] {
                    if ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                        writeCharacteristic = ch
                        break
                    }
                }
                if writeCharacteristic != nil { break }
            }
        }

        for ch in notifyCharacteristics {
            p.setNotifyValue(true, for: ch)
        }
        note("发现可写特征 \(writeCharacteristic?.uuid.uuidString ?? "无")，订阅 \(notifyCharacteristics.count) 个通知特征")
    }
}

// MARK: - CBCentralManagerDelegate

extension BleService: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        note("蓝牙状态: \(bluetoothStateText)")

        switch central.state {
        case .poweredOn:
            if pendingScan {
                pendingScan = false
                startScan()
            }
            if let pc = pendingConnect {
                pendingConnect = nil
                connect(identifier: pc.identifier, name: pc.name)
            }
        case .unauthorized:
            fail("未授权使用蓝牙，请在 设置 → 隐私与安全性 → 蓝牙 中允许")
        case .poweredOff:
            fail("蓝牙未开启")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let name = advertised ?? peripheral.name ?? ""
        let device = DiscoveredDevice(id: peripheral.identifier,
                                      name: name,
                                      rssi: RSSI.intValue,
                                      lastSeen: Date())
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            devices[idx] = device
        } else {
            devices.append(device)
            note("发现设备 \(device.displayName) · \(device.id.uuidString) · RSSI \(device.rssi)dBm")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        note("连接成功，正在发现服务…")
        lastConnectedIdentifier = peripheral.identifier
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        fail("连接失败: \(error?.localizedDescription ?? "未知错误")")
        markDisconnected("连接失败")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        markDisconnected(error?.localizedDescription ?? "连接已断开")
        stopPolling()
        writeCharacteristic = nil
    }
}

// MARK: - CBPeripheralDelegate

extension BleService: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            fail("服务发现失败: \(error.localizedDescription)")
            return
        }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            fail("特征发现失败: \(error.localizedDescription)")
            return
        }
        locateCharacteristics()
        if !metrics.connected {
            metrics.connected = true
            isConnected = true
            if writeCharacteristic == nil {
                note("未找到可写特征，仅能订阅")
            }
            startPolling()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            note("订阅 \(characteristic.uuid.uuidString) 失败: \(error.localizedDescription)")
        } else {
            note("通知\(characteristic.isNotifying ? "开启" : "关闭") [\(characteristic.uuid.uuidString)]")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            note("读取失败: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        handleNotify([UInt8](data))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            note("写入失败: \(error.localizedDescription)")
            opMode = .idle
            opTimeoutTimer?.invalidate()
        }
    }
}
