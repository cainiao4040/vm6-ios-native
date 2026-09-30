import SwiftUI

/// `DeviceScanActivity` + `BleService.startScan()` — pick the meter to bind to.
struct DeviceScanView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    /// 长按设备 → 写备注
    @State private var noteDevice: DiscoveredDevice?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScanHeader(ble: store.ble)

                if store.ble.devices.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView().tint(Theme.accent)
                        Text(store.ble.isScanning ? "正在扫描附近蓝牙表具…" : "未发现设备，请靠近表具后点刷新")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(sortedDevices) { device in
                                DeviceRow(device: device, isTarget: isTarget(device))
                                    .onTapGesture { select(device) }
                                    .contextMenu {
                                        Button { noteDevice = device } label: {
                                            Label("写备注", systemImage: "square.and.pencil")
                                        }
                                    }
                            }
                        }
                        .padding(14)
                    }
                }

                Text("点击设备即连接 · 长按设备可写备注 · 目标设备已标 ⭐")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .padding(.bottom, 14)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("选择设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("‹ 返回") {
                        store.ble.stopScan()
                        dismiss()
                    }
                    .foregroundColor(Theme.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("刷新") { store.ble.startScan() }
                        .foregroundColor(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { store.ble.startScan() }
        .sheet(item: $noteDevice) { device in
            DeviceNoteSheet(device: device)
                .environmentObject(store)
        }
        .onDisappear { store.ble.stopScan() }
    }

    private var sortedDevices: [DiscoveredDevice] {
        store.ble.devices.sorted { a, b in
            let at = isTarget(a), bt = isTarget(b)
            if at != bt { return at }
            return a.rssi > b.rssi
        }
    }

    /// Mirrors the Android "⭐目标" rule: same identifier, or a name match.
    private func isTarget(_ device: DiscoveredDevice) -> Bool {
        if device.id.uuidString.caseInsensitiveCompare(store.settings.targetIdentifier) == .orderedSame {
            return true
        }
        let target = store.settings.targetName
        return !target.isEmpty && device.name.contains(target)
    }

    private func select(_ device: DiscoveredDevice) {
        store.connect(to: device)
        dismiss()
    }
}

private struct ScanHeader: View {
    @ObservedObject var ble: BleService

    var body: some View {
        Card {
            HStack {
                StatusDot(connected: ble.isScanning)
                Text(ble.isScanning ? "正在扫描附近蓝牙表具…" : "扫描已停止")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text("\(ble.devices.count) 台")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accent)
            }
        }
        .padding([.horizontal, .top], 14)
    }
}

private struct DeviceRow: View {
    let device: DiscoveredDevice
    let isTarget: Bool

    var body: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 16))
                    .foregroundColor(isTarget ? Theme.accent : Theme.textMuted)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(device.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        if isTarget {
                            Text("⭐目标")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Theme.accent)
                        }
                    }
                    Text(device.id.uuidString)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(device.rssi)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(rssiColor)
                    Text("dBm")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                }
            }
        }
    }

    private var rssiColor: Color {
        if device.rssi >= -65 { return Theme.syncGreen }
        if device.rssi >= -80 { return Theme.accent }
        return Theme.danger
    }
}
