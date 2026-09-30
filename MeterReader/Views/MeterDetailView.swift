import SwiftUI

/// `MeterDetailActivity` — readings for one meter plus the offline add dialog.
struct MeterDetailView: View {
    @EnvironmentObject private var store: AppStore
    let meter: Meter

    @State private var readings: [Reading] = []
    @State private var showAdd = false
    @State private var addMeterId = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meter.displayName.isEmpty ? meter.id : meter.displayName)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                        Text("表具 ID: \(meter.id)")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textMuted)
                        if !meter.model.isEmpty {
                            Text("型号 \(meter.model) · \(store.meterDescription(meter.id))")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                }

                AccentButton(title: "+ 离线手工抄表", systemImage: "plus") {
                    addMeterId = meter.id
                    showAdd = true
                }

                SectionEyebrow(text: "读数明细（\(readings.count) 条）")

                if readings.isEmpty {
                    EmptyStateCard(systemImage: "list.bullet.rectangle", message: "该表具暂无读数")
                } else {
                    ForEach(readings) { reading in
                        NavigationLink(destination: ReadingDetailView(reading: reading, meterName: meter.displayName)) {
                            ReadingRow(reading: reading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                store.deleteReading(reading)
                                load()
                            } label: {
                                Label("删除这条读数", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(meter.displayName.isEmpty ? meter.id : meter.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .sheet(isPresented: $showAdd, onDismiss: load) {
            // Reuses the offline-entry sheet; an alert with TextField would
            // require iOS 16, and this app targets iOS 15.
            ManualReadingSheet(meterId: $addMeterId, meters: store.meters)
                .environmentObject(store)
        }
    }

    private func load() {
        readings = store.db.listReadings(meterId: meter.id)
    }
}

private struct ReadingRow: View {
    let reading: Reading

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(reading.recordedAt)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(reading.sourceText)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                }
                Spacer(minLength: 6)
                Text(reading.valueText)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(reading.value == nil ? Theme.textMuted : Theme.accent)
            }
        }
    }
}

/// `ReadingDetailActivity` — the per-metric snapshots of one reading.
struct ReadingDetailView: View {
    @EnvironmentObject private var store: AppStore
    let reading: Reading
    let meterName: String

    @State private var snapshots: [MetricSnapshot] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meterName.isEmpty ? reading.meterId : meterName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                        Text(reading.recordedAt)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textMuted)
                        CardDivider()
                        KeyValueRow(label: "读数", value: reading.valueText,
                                    valueColor: reading.value == nil ? Theme.textMuted : Theme.accent)
                        KeyValueRow(label: "来源", value: reading.sourceText)
                        if let signal = reading.signalStrength {
                            KeyValueRow(label: "信号强度", value: String(format: "%.0f", signal), unit: "dBm")
                        }
                    }
                }

                if !reading.rawPayloadJson.isEmpty && reading.rawPayloadJson != "null" {
                    SectionEyebrow(text: "原始数据")
                    Card {
                        Text(reading.rawPayloadJson)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SectionEyebrow(text: "指标快照")
                if snapshots.isEmpty {
                    EmptyStateCard(systemImage: "square.stack.3d.up", message: "这条读数没有指标快照")
                } else {
                    Card {
                        VStack(spacing: 0) {
                            ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snap in
                                if index > 0 { CardDivider() }
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(snap.displayName)
                                            .font(.system(size: 14))
                                            .foregroundColor(Theme.textSecondary)
                                        Text(snap.metricKey)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Theme.textMuted)
                                    }
                                    Spacer(minLength: 8)
                                    Text(snap.valueText.isEmpty ? (snap.valueNumber.map { String(format: "%.4f", $0) } ?? "—") : snap.valueText)
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(Theme.textPrimary)
                                    if !snap.unit.isEmpty {
                                        Text(snap.unit)
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.textMuted)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("读数详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            snapshots = store.db.listSnapshots(readingId: reading.id)
        }
    }
}
