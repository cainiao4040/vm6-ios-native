import SwiftUI

/// 抄表主页 — port of `page_home.xml` + `MainActivity.initHome()`.
struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmWrite = false

    /// 一个 sheet 槽位放两种弹层：SwiftUI 在同一层级叠两个 .sheet 时只有最后一个生效。
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: Identifiable {
        case devicePicker
        case devices
        var id: Int { hashValue }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ConnectionStatusCard(ble: store.ble, pendingCount: store.pendingCount)

                    AccentButton(title: "刷新实时值", systemImage: "arrow.clockwise") {
                        store.refreshLiveValues()
                    }

                    SectionEyebrow(text: "实时数据")
                    LiveMetricsCard(ble: store.ble)

                    SectionEyebrow(text: "流量系数编辑")
                    coefficientCard

                    SectionEyebrow(text: "执行抄表")
                    captureCard

                    SectionEyebrow(text: "同步队列")
                    syncQueueCard
                }
                .padding(14)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("抄表主页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { activeSheet = .devices } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .foregroundColor(Theme.accent)
                    .accessibilityLabel("设备与备注")
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .devicePicker:
                DeviceScanView().environmentObject(store)
            case .devices:
                DevicesView().environmentObject(store)
            }
        }
        .alert("确认写入流量系数？", isPresented: $confirmWrite) {
            Button("取消", role: .cancel) {}
            Button("写入并校验") { store.writeCoefficient() }
        } message: {
            Text("将把 \(store.coefficientInput) 写入设备寄存器并回读校验。")
        }
    }

    // MARK: - 流量系数编辑

    private var coefficientCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("目标流量系数")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)

                DarkTextField(placeholder: "例如 9.99", text: $store.coefficientInput, keyboard: .decimalPad)

                Button {
                    confirmWrite = true
                } label: {
                    Text("写入设备并校验")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundColor(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.primary)
                        )
                }
                .buttonStyle(.plain)

                Text("写入寄存器 16 后会立即回读校验，容差 max(1e-4, |系数| × 0.001)。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 执行抄表

    private var captureCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                ConnectedDeviceLine(ble: store.ble, fallback: store.settings.targetDisplay)

                ParamDescriptionLine(ble: store.ble)

                CardDivider()

                Text("读数归属表具")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                MeterPicker(selection: $store.captureMeterId, meters: store.meters)

                SecondaryButton(title: "选择设备", systemImage: "antenna.radiowaves.left.and.right") {
                    store.beginScan()
                    activeSheet = .devicePicker
                }

                DarkTextField(placeholder: "备注（可选）", text: $store.notesInput)

                AccentButton(title: "保存时间与位置后抄表", systemImage: "square.and.arrow.down") {
                    store.saveReading()
                }

                if let summary = store.lastCaptureSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最近一次抄表")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.syncGreen)
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - 同步队列

    private var syncQueueCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(store.syncDescription)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    if store.pendingCount > 0 {
                        Button("全部标记已同步") { store.markAllSynced() }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    }
                }

                if store.pendingList.isEmpty {
                    Text("（空）")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                } else {
                    ForEach(Array(store.pendingList.prefix(20).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

// MARK: - Sub-views that observe BleService directly

private struct ConnectionStatusCard: View {
    @ObservedObject var ble: BleService
    let pendingCount: Int

    var body: some View {
        Card {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: ble.isConnected ? "bluetooth" : "bluetooth")
                        .font(.system(size: 15))
                        .foregroundColor(ble.isConnected ? Theme.syncGreen : Theme.bleConnected)
                    Text(ble.statusText)
                        .font(.system(size: 13))
                        .foregroundColor(ble.isConnected ? Theme.syncGreen : Theme.bleConnected)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.syncGreen)
                    Text("待同步 \(pendingCount) 条")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.syncGreen)
                }
            }
        }
    }
}

private struct LiveMetricsCard: View {
    @ObservedObject var ble: BleService

    var body: some View {
        Card {
            VStack(spacing: 0) {
                KeyValueRow(label: "瞬时流量", value: ble.metrics.flowRateText, unit: "m³/h")
                CardDivider()
                KeyValueRow(label: "压力", value: ble.metrics.pressureText, unit: "kPa")
                CardDivider()
                KeyValueRow(label: "温度", value: ble.metrics.temperatureText, unit: "℃")
                CardDivider()
                KeyValueRow(label: "累计流量", value: ble.metrics.totalText, unit: "m³")
                CardDivider()
                KeyValueRow(label: "流量系数", value: ble.metrics.flowCoefficientText,
                            valueColor: Theme.accent)
            }
        }
    }
}

private struct ParamDescriptionLine: View {
    @ObservedObject var ble: BleService

    var body: some View {
        Text(ble.metrics.paramDescription)
            .font(.system(size: 12))
            .foregroundColor(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ConnectedDeviceLine: View {
    @ObservedObject var ble: BleService
    let fallback: String

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(connected: ble.isConnected)
            Text(ble.isConnected && !ble.connectedName.isEmpty ? ble.connectedName : fallback)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
        }
    }
}

private struct MeterPicker: View {
    @Binding var selection: String
    let meters: [Meter]

    var body: some View {
        Menu {
            ForEach(meters) { meter in
                Button {
                    selection = meter.id
                } label: {
                    Text("\(meter.displayName)（\(meter.id)）")
                }
            }
            Button("离线手工抄表") { selection = "offline-manual" }
        } label: {
            HStack {
                Text(meters.first(where: { $0.id == selection })?.displayName ?? selection)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.fieldBorder, lineWidth: 1))
        }
    }
}
