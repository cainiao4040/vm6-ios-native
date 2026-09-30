import SwiftUI

/// 设备与备注：列出所有表具，人工修改显示名称与备注信息。
///
/// 备注存在 `meters.note`，与读数、系数互不影响。
/// 旧版本的库没有这一列，AppDatabase.migrate() 会自动补上，已有记录不会丢。
struct DevicesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var editing: Meter?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.meters.isEmpty {
                        EmptyStateCard(
                            systemImage: "gauge",
                            message: "还没有设备记录\n\n先到「选择设备」连接一台表具，\n或在扫描列表里点一下设备名先写备注。"
                        )
                    } else {
                        SectionEyebrow(text: "共 \(store.meters.count) 台设备 · 点击编辑备注")

                        ForEach(store.meters) { meter in
                            DeviceCard(meter: meter)
                                .contentShape(Rectangle())
                                .onTapGesture { editing = meter }
                        }
                    }
                }
                .padding(14)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("设备与备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("‹ 返回") { dismiss() }
                        .foregroundColor(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { store.reload() }
        .sheet(item: $editing) { meter in
            MeterInfoSheet(meter: meter)
                .environmentObject(store)
        }
    }
}

// MARK: - 列表行

private struct DeviceCard: View {
    let meter: Meter

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .foregroundColor(Theme.accent)
                    Text(meter.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textMuted)
                }

                Text(meter.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)

                if meter.hasNote {
                    Text("备注：\(meter.note)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("（无备注，点击添加）")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                }

                HStack(spacing: 10) {
                    if let coeff = coefficientValue {
                        Text("系数 K=" + String(format: "%.4f", coeff))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                    }
                    if let seen = meter.lastSeenAt, !seen.isEmpty {
                        Text("最近 \(Timestamps.short(seen))")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
        }
    }

    /// 系数存在 metadata_json 里（{"coefficient": x}）。
    private var coefficientValue: Double? {
        guard let data = meter.metadataJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let n = obj["coefficient"] as? NSNumber { return n.doubleValue }
        return nil
    }
}

// MARK: - 编辑弹层

/// 编辑某台设备的显示名称 / 人工备注，也可删除。
/// 不声明为 private：MeterDetailView 也复用它。
struct MeterInfoSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let meter: Meter

    @State private var name: String
    @State private var note: String
    @State private var confirmDelete = false

    init(meter: Meter) {
        self.meter = meter
        _name = State(initialValue: meter.label)
        _note = State(initialValue: meter.note)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("设备标识")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textMuted)
                            Text(meter.id)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    SectionEyebrow(text: "显示名称")
                    DarkTextField(placeholder: "例如：1号井流量计", text: $name)

                    SectionEyebrow(text: "人工备注")
                    noteEditor

                    AccentButton(title: "保存", systemImage: "checkmark") { save() }

                    SecondaryButton(title: "删除这台设备", systemImage: "trash") {
                        confirmDelete = true
                    }
                }
                .padding(14)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("设备信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
        .alert("删除设备？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                store.db.deleteMeter(id: meter.id)
                store.reload()
                store.showToast("已删除设备「\(meter.label)」，读数记录保留")
                dismiss()
            }
        } message: {
            Text("只删除设备信息，该设备的读数记录不会被删除。")
        }
    }

    private var noteEditor: some View {
        ZStack(alignment: .topLeading) {
            if note.isEmpty {
                Text("例如：王家坡计量间，2026-03 更换电池，负责人王工 138xxxx")
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
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.db.updateMeterInfo(
            id: meter.id,
            displayName: trimmedName.isEmpty ? meter.label : trimmedName,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        store.reload()
        store.showToast("已保存")
        dismiss()
    }
}
