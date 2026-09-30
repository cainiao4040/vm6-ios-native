import SwiftUI

/// 历史 — port of `page_history.xml` + `MainActivity.initHistory()`.
struct HistoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showManualSheet = false
    @State private var manualMeterId: String = "offline-manual"

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("表具与抄表历史")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    Text("点击表具查看读数明细；下方为全部抄表记录。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)

                    if store.meters.isEmpty {
                        EmptyStateCard(systemImage: "gauge", message: "暂无表具记录")
                    } else {
                        ForEach(store.meters) { meter in
                            NavigationLink(destination: MeterDetailView(meter: meter)) {
                                MeterRow(meter: meter,
                                         readingCount: store.db.countReadings(meterId: meter.id),
                                         subtitle: subtitle(for: meter))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    SectionEyebrow(text: "全部抄表记录")
                    if store.allReadings.isEmpty {
                        EmptyStateCard(systemImage: "tray", message: "暂无抄表记录")
                    } else {
                        Card {
                            VStack(spacing: 0) {
                                ForEach(Array(store.allReadings.prefix(50).enumerated()), id: \.element.id) { index, item in
                                    if index > 0 { CardDivider() }
                                    AllReadingRow(item: item)
                                }
                            }
                        }
                    }

                    AccentButton(title: "离线手工抄表", systemImage: "square.and.pencil") {
                        manualMeterId = store.meters.first?.id ?? "offline-manual"
                        showManualSheet = true
                    }
                    .padding(.top, 4)
                }
                .padding(14)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("历史")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showManualSheet) {
            ManualReadingSheet(meterId: $manualMeterId, meters: store.meters)
                .environmentObject(store)
        }
    }

    /// "型号 VM6 · MAC B4:… · connected · RSSI -68dBm"
    private func subtitle(for meter: Meter) -> String {
        var parts: [String] = []
        if !meter.model.isEmpty { parts.append("型号 \(meter.model)") }
        parts.append(store.meterDescription(meter.id))
        parts.append(meter.connectionPhase)
        if let rssi = meter.rssi { parts.append("RSSI \(rssi)dBm") }
        return parts.joined(separator: " · ")
    }
}

private struct MeterRow: View {
    let meter: Meter
    let readingCount: Int
    let subtitle: String

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(connected: meter.isConnected)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(meter.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    if meter.hasNote {
                        Text("备注：\(meter.note)")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(2)
                }

                Spacer(minLength: 6)

                Text("\(readingCount) 条读数")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.accent)
            }
        }
    }
}

private struct AllReadingRow: View {
    let item: AllReading

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.meterName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(Timestamps.short(item.recordedAt)) · \(item.sourceText)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(item.valueText)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.vertical, 2)
    }
}

/// The "+ 离线手工抄表" dialog (`dialog_add_reading.xml`).
struct ManualReadingSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Binding var meterId: String
    let meters: [Meter]

    @State private var value = ""
    @State private var notes = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("读数归属表具")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                    Menu {
                        ForEach(meters) { meter in
                            Button("\(meter.displayName)（\(meter.id)）") { meterId = meter.id }
                        }
                        Button("离线手工抄表") { meterId = "offline-manual" }
                    } label: {
                        HStack {
                            Text(meters.first(where: { $0.id == meterId })?.displayName ?? meterId)
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textMuted)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.fieldBorder, lineWidth: 1))
                    }

                    Text("抄表读数 (m³)")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                    DarkTextField(placeholder: "例如 12345.67", text: $value, keyboard: .decimalPad)

                    Text("备注")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                    DarkTextField(placeholder: "可选", text: $notes)

                    AccentButton(title: "保存", systemImage: "checkmark") {
                        if store.addManualReading(meterId: meterId, valueText: value, notes: notes) {
                            dismiss()
                        }
                    }
                    .padding(.top, 6)
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("离线手工抄表")
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
}
