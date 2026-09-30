import SwiftUI
import UIKit
import CoreBluetooth

/// 设置 — port of `page_settings.xml` + `MainActivity.initSettings()`.
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var deviceName = ""
    @State private var deviceIdentifier = ""
    @State private var showLog = false
    @State private var loaded = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionEyebrow(text: "目标表具")

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("目标表具设备名")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textSecondary)
                            DarkTextField(placeholder: AppSettings.defaultDeviceName, text: $deviceName)

                            Text("目标表具标识")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textSecondary)
                            DarkTextField(placeholder: "CoreBluetooth 标识", text: $deviceIdentifier)

                            Text("iOS 无法读取蓝牙 MAC 地址，这里保存 CoreBluetooth 标识。若要继续沿用安卓版的抄表历史，可把原 MAC（如 B4:52:A9:D0:10:FB）填在这里。")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)

                            AccentButton(title: "保存设置", systemImage: "checkmark.circle") {
                                save()
                            }

                            SecondaryButton(title: "重连上次连接的设备", systemImage: "arrow.clockwise.heart") {
                                store.ble.reconnectLast()
                            }
                        }
                    }

                    SectionEyebrow(text: "权限")
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            PermissionLine(label: "蓝牙",
                                           value: store.ble.bluetoothStateText,
                                           ok: store.ble.bluetoothState == .poweredOn)
                            CardDivider()
                            PermissionLine(label: "定位",
                                           value: store.location.statusText,
                                           ok: store.location.isAuthorized)
                            CardDivider()
                            PermissionLine(label: "当前坐标",
                                           value: store.location.currentLocationText(),
                                           ok: store.location.isAuthorized)

                            SecondaryButton(title: "申请蓝牙/定位权限", systemImage: "hand.raised") {
                                store.location.requestPermission()
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            Text("蓝牙权限由系统在首次扫描时自动询问；若被拒绝，请到系统设置中开启。")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textMuted)
                        }
                    }

                    SectionEyebrow(text: "数据")
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("本地共 \(store.db.totalReadingCount) 条读数 · \(store.meters.count) 个表具")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textSecondary)

                            SecondaryButton(title: "导出数据到「文件」App", systemImage: "square.and.arrow.up") {
                                if let url = store.exportData() {
                                    store.showToast("已导出到 文件 → 我的 iPhone → MeterReader → MeterReaderExport\n\(url.lastPathComponent)")
                                } else {
                                    store.showToast("导出失败")
                                }
                            }

                            SecondaryButton(title: "查看 BLE 通讯日志", systemImage: "doc.text.magnifyingglass") {
                                showLog = true
                            }
                        }
                    }

                    SectionEyebrow(text: "关于")
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("流量计抄表 v1.0.1")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                            Text("VM6 蓝牙抄表 · A5/Modbus 协议")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textMuted)
                            Text("BLE 实时抄表：扫描 VM6 表具，3 秒轮询实时值，支持写流量系数并回读校验，离线手工补录与同步队列。")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            deviceName = store.settings.targetName
            deviceIdentifier = store.settings.targetIdentifier
        }
        .sheet(isPresented: $showLog) {
            LogView(ble: store.ble)
        }
    }

    private func save() {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = deviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !identifier.isEmpty else {
            store.showToast("设备名或标识至少填一项")
            return
        }
        store.settings.targetName = name.isEmpty ? AppSettings.defaultDeviceName : name
        store.settings.targetIdentifier = identifier
        store.showToast("已保存目标设备")
    }
}

private struct PermissionLine: View {
    let label: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ok ? Theme.syncGreen : Theme.bleConnected)
                .lineLimit(1)
        }
    }
}

/// Live BLE trace — the iOS counterpart of `flutter_reactive_ble`'s debug logger.
private struct LogView: View {
    @ObservedObject var ble: BleService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if ble.log.isEmpty {
                        Text("暂无日志")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textMuted)
                    } else {
                        ForEach(Array(ble.log.enumerated().reversed()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(14)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("BLE 日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }.foregroundColor(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
