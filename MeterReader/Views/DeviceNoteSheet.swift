import SwiftUI

/// 从扫描列表直接给一台设备写备注（不必先连接）。
///
/// 设备还没进 meters 表时按 CoreBluetooth 标识新建一行；
/// 已存在则只更新名称与备注。
struct DeviceNoteSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let device: DiscoveredDevice

    @State private var name: String
    @State private var note: String

    init(device: DiscoveredDevice) {
        self.device = device
        let existing = AppDatabase.shared.meter(withId: device.id.uuidString)
        _name = State(initialValue: existing?.label ?? device.displayName)
        _note = State(initialValue: existing?.note ?? "")
    }

    private var deviceKey: String { device.id.uuidString }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("设备标识")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textMuted)
                            Text(deviceKey)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("信号 RSSI \(device.rssi) dBm")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textMuted)
                        }
                    }

                    SectionEyebrow(text: "显示名称")
                    DarkTextField(placeholder: "例如：1号井流量计", text: $name)

                    SectionEyebrow(text: "人工备注")
                    ZStack(alignment: .topLeading) {
                        if note.isEmpty {
                            Text("例如：王家坡计量间，负责人王工 138xxxx")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.textMuted)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $note)
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textPrimary)
                            .frame(minHeight: 110)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.clear)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.fieldBorder, lineWidth: 1)
                    )

                    AccentButton(title: "保存", systemImage: "checkmark") { save() }
                }
                .padding(14)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("设备备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        if AppDatabase.shared.meter(withId: deviceKey) == nil {
            var meter = Meter(id: deviceKey)
            meter.serialNumber = ""
            meter.displayName = trimmedName.isEmpty ? device.displayName : trimmedName
            meter.type = "flow-meter"
            meter.model = "VM6"
            meter.status = "seen"
            meter.note = trimmedNote
            meter.lastSeenAt = Timestamps.now()
            meter.createdAt = Timestamps.now()
            meter.updatedAt = Timestamps.now()
            AppDatabase.shared.upsertMeter(meter)
        } else {
            AppDatabase.shared.updateMeterInfo(
                id: deviceKey,
                displayName: trimmedName.isEmpty ? nil : trimmedName,
                note: trimmedNote)
        }

        store.reload()
        store.showToast("已保存「\(trimmedName.isEmpty ? device.displayName : trimmedName)」的备注")
        dismiss()
    }
}
