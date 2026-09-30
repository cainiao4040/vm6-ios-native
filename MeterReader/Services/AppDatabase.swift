import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Port of `com.kmj.meterreader.AppDb`.
/// Table layout is kept byte-compatible with the Android schema so exported JSON
/// from either platform can be imported by the other.
final class AppDatabase {

    static let shared = AppDatabase()

    static let dbName = "meter_reader.db"
    static let dbVersion = 2

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.kmj.meterreader.db")

    private init() {
        open()
    }

    deinit {
        if let h = handle { sqlite3_close(h) }
    }

    // MARK: - Setup

    var databaseURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(Self.dbName)
    }

    private func open() {
        let path = databaseURL.path
        if sqlite3_open(path, &handle) != SQLITE_OK {
            NSLog("[MeterReader] failed to open database at %@", path)
            handle = nil
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        createTables()
        migrate()
    }

    private func createTables() {
        exec("""
        CREATE TABLE IF NOT EXISTS meters(
            id TEXT PRIMARY KEY,
            serial_number TEXT DEFAULT '',
            display_name TEXT DEFAULT '',
            location TEXT DEFAULT '',
            type TEXT DEFAULT '',
            model TEXT DEFAULT '',
            status TEXT DEFAULT '',
            metadata_json TEXT DEFAULT '{}',
            note TEXT DEFAULT '',
            last_seen_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL)
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS readings(
            id TEXT PRIMARY KEY,
            meter_id TEXT NOT NULL,
            device_id TEXT DEFAULT '',
            recorded_at TEXT NOT NULL,
            received_at TEXT NOT NULL,
            value REAL,
            unit TEXT DEFAULT '',
            source TEXT DEFAULT '',
            status TEXT DEFAULT '',
            notes TEXT DEFAULT '',
            raw_payload_json TEXT DEFAULT 'null',
            metadata_json TEXT DEFAULT 'null',
            battery_level REAL,
            signal_strength REAL,
            flow_rate REAL,
            temperature REAL,
            pressure REAL,
            synced_at TEXT NOT NULL)
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS metric_snapshots(
            id TEXT PRIMARY KEY,
            reading_id TEXT NOT NULL,
            meter_id TEXT NOT NULL,
            captured_at TEXT NOT NULL,
            metric_key TEXT NOT NULL,
            value_text TEXT DEFAULT '',
            value_number REAL,
            value_type TEXT DEFAULT '',
            unit TEXT DEFAULT '',
            source TEXT DEFAULT '',
            recorded_by TEXT DEFAULT '',
            description TEXT DEFAULT '',
            metadata_json TEXT DEFAULT 'null',
            created_at TEXT NOT NULL)
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS sync_queue(
            id TEXT PRIMARY KEY,
            reading_id TEXT NOT NULL,
            meter_id TEXT DEFAULT '',
            status TEXT DEFAULT 'pending',
            action TEXT DEFAULT 'upload',
            payload_json TEXT DEFAULT 'null',
            created_at TEXT NOT NULL,
            synced_at TEXT)
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_readings_meter ON readings(meter_id, recorded_at DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_snapshots_reading ON metric_snapshots(reading_id)")
    }

    /// 幂等迁移：老版本的库没有 meters.note 列，这里补上。
    /// 只加列、不动已有数据，所以已经装过旧版的手机会保留全部记录。
    private func migrate() {
        if !columnExists("meters", "note") {
            exec("ALTER TABLE meters ADD COLUMN note TEXT DEFAULT ''")
            NSLog("[MeterReader] migrated: added meters.note")
        }
    }

    /// PRAGMA table_info 的第 1 列是列名。
    private func columnExists(_ table: String, _ column: String) -> Bool {
        guard let stmt = prepare("PRAGMA table_info(\(table))") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if string(stmt, 1) == column { return true }
        }
        return false
    }

    // MARK: - Low level helpers

    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard let h = handle else { return false }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK {
            if let e = err {
                NSLog("[MeterReader] SQL error: %@ (%@)", String(cString: e), sql)
                sqlite3_free(e)
            }
            return false
        }
        return true
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let h = handle else { return nil }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(h, sql, -1, &stmt, nil) != SQLITE_OK {
            NSLog("[MeterReader] prepare failed: %@ (%@)", String(cString: sqlite3_errmsg(h)), sql)
            return nil
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ values: [Any?]) {
        guard let stmt = stmt else { return }
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case nil, is NSNull:
                sqlite3_bind_null(stmt, idx)
            case let v as String:
                sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Double:
                sqlite3_bind_double(stmt, idx, v)
            case let v as Float:
                sqlite3_bind_double(stmt, idx, Double(v))
            case let v as Int:
                sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64:
                sqlite3_bind_int64(stmt, idx, v)
            case let v as Bool:
                sqlite3_bind_int(stmt, idx, v ? 1 : 0)
            default:
                sqlite3_bind_text(stmt, idx, String(describing: value!), -1, SQLITE_TRANSIENT)
            }
        }
    }

    /// Non-null Double, or nil when the column is NULL (or a NaN was stored).
    private func double(_ stmt: OpaquePointer?, _ col: Int32) -> Double? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        let d = sqlite3_column_double(stmt, col)
        return d.isNaN ? nil : d
    }

    private func string(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    private func stringOrNil(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return string(stmt, col)
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Any?]) -> Bool {
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            NSLog("[MeterReader] step failed rc=%d (%@)", rc, sql)
            return false
        }
        return true
    }

    // MARK: - Meters

    func listMeters() -> [Meter] {
        queue.sync {
            var out: [Meter] = []
            let sql = """
            SELECT id,serial_number,display_name,location,type,model,status,metadata_json,
                   note,last_seen_at,created_at,updated_at
            FROM meters ORDER BY display_name
            """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Meter(
                    id: string(stmt, 0),
                    serialNumber: string(stmt, 1),
                    displayName: string(stmt, 2),
                    location: string(stmt, 3),
                    type: string(stmt, 4),
                    model: string(stmt, 5),
                    status: string(stmt, 6),
                    metadataJson: string(stmt, 7),
                    note: string(stmt, 8),
                    lastSeenAt: stringOrNil(stmt, 9),
                    createdAt: string(stmt, 10),
                    updatedAt: string(stmt, 11)))
            }
            return out
        }
    }

    func meter(withId id: String) -> Meter? {
        listMeters().first { $0.id == id }
    }

    func upsertMeter(_ meter: Meter) {
        queue.sync {
            let now = Timestamps.now()
            run("""
            INSERT INTO meters(id,serial_number,display_name,location,type,model,status,
                               metadata_json,note,last_seen_at,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                serial_number=excluded.serial_number,
                display_name=excluded.display_name,
                location=excluded.location,
                type=excluded.type,
                model=excluded.model,
                status=excluded.status,
                metadata_json=excluded.metadata_json,
                note=CASE WHEN excluded.note IS NULL OR excluded.note = ''
                          THEN meters.note ELSE excluded.note END,
                last_seen_at=excluded.last_seen_at,
                updated_at=excluded.updated_at
            """, [meter.id, meter.serialNumber, meter.displayName, meter.location,
                  meter.type, meter.model, meter.status, meter.metadataJson,
                  meter.note, meter.lastSeenAt,
                  meter.createdAt.isEmpty ? now : meter.createdAt, now])
        }
    }

    /// 修改设备的显示名称与人工备注。传入 nil 表示该字段不动。
    /// 与 upsertMeter 不同，这里用直接 UPDATE，所以**可以清空备注**。
    func updateMeterInfo(id: String, displayName: String? = nil, note: String? = nil) {
        queue.sync {
            var sets: [String] = ["updated_at=?"]
            var args: [Any?] = [Timestamps.now()]
            if let displayName = displayName {
                sets.append("display_name=?")
                args.append(displayName)
            }
            if let note = note {
                sets.append("note=?")
                args.append(note)
            }
            args.append(id)
            run("UPDATE meters SET \(sets.joined(separator: ",")) WHERE id=?", args)
        }
    }

    /// 删除设备行。读数记录保留（与原安卓版一致，不做级联删除）。
    func deleteMeter(id: String) {
        queue.sync {
            run("DELETE FROM meters WHERE id=?", [id])
        }
    }

    /// Ensures a meter row exists for `id`, filling in a sensible display name.
    @discardableResult
    func ensureMeter(id: String, displayName: String, model: String = "VM6", extra: [String: Any] = [:]) -> Meter {
        if let existing = meter(withId: id) { return existing }
        let metadata = (try? JSONSerialization.data(withJSONObject: extra))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let now = Timestamps.now()
        let meter = Meter(id: id,
                          serialNumber: "",
                          displayName: displayName,
                          location: "",
                          type: "flow-meter",
                          model: model,
                          status: "connected",
                          metadataJson: metadata,
                          lastSeenAt: now,
                          createdAt: now,
                          updatedAt: now)
        upsertMeter(meter)
        return meter
    }

    func countReadings(meterId: String) -> Int {
        queue.sync {
            guard let stmt = prepare("SELECT COUNT(*) FROM readings WHERE meter_id=?") else { return 0 }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, [meterId])
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    // MARK: - Readings

    func listReadings(meterId: String) -> [Reading] {
        queue.sync {
            var out: [Reading] = []
            let sql = """
            SELECT id,meter_id,device_id,recorded_at,received_at,value,unit,source,status,notes,
                   raw_payload_json,metadata_json,battery_level,signal_strength,
                   flow_rate,temperature,pressure,synced_at
            FROM readings WHERE meter_id=? ORDER BY recorded_at DESC
            """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, [meterId])
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Reading(
                    id: string(stmt, 0),
                    meterId: string(stmt, 1),
                    deviceId: string(stmt, 2),
                    recordedAt: string(stmt, 3),
                    receivedAt: string(stmt, 4),
                    value: double(stmt, 5),
                    unit: string(stmt, 6),
                    source: string(stmt, 7),
                    status: string(stmt, 8),
                    notes: string(stmt, 9),
                    rawPayloadJson: string(stmt, 10),
                    metadataJson: string(stmt, 11),
                    batteryLevel: double(stmt, 12),
                    signalStrength: double(stmt, 13),
                    flowRate: double(stmt, 14),
                    temperature: double(stmt, 15),
                    pressure: double(stmt, 16),
                    syncedAt: string(stmt, 17)))
            }
            return out
        }
    }

    func reading(withId id: String) -> Reading? {
        queue.sync {
            let sql = """
            SELECT id,meter_id,device_id,recorded_at,received_at,value,unit,source,status,notes,
                   raw_payload_json,metadata_json,battery_level,signal_strength,
                   flow_rate,temperature,pressure,synced_at
            FROM readings WHERE id=?
            """
            guard let stmt = prepare(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, [id])
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Reading(
                id: string(stmt, 0), meterId: string(stmt, 1), deviceId: string(stmt, 2),
                recordedAt: string(stmt, 3), receivedAt: string(stmt, 4), value: double(stmt, 5),
                unit: string(stmt, 6), source: string(stmt, 7), status: string(stmt, 8),
                notes: string(stmt, 9), rawPayloadJson: string(stmt, 10), metadataJson: string(stmt, 11),
                batteryLevel: double(stmt, 12), signalStrength: double(stmt, 13),
                flowRate: double(stmt, 14), temperature: double(stmt, 15), pressure: double(stmt, 16),
                syncedAt: string(stmt, 17))
        }
    }

    /// Mirrors `AppDb.listAllReadings()` — readings LEFT JOIN meters, newest first.
    func listAllReadings(limit: Int = 200) -> [AllReading] {
        queue.sync {
            var out: [AllReading] = []
            let sql = """
            SELECT r.id, r.meter_id, r.recorded_at, r.value, r.unit, r.source, r.notes, m.display_name
            FROM readings r LEFT JOIN meters m ON r.meter_id = m.id
            ORDER BY r.recorded_at DESC LIMIT ?
            """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, [limit])
            while sqlite3_step(stmt) == SQLITE_ROW {
                let meterId = string(stmt, 1)
                let name = stringOrNil(stmt, 7) ?? meterId
                out.append(AllReading(readingId: string(stmt, 0),
                                      meterId: meterId,
                                      meterName: name,
                                      recordedAt: string(stmt, 2),
                                      value: double(stmt, 3),
                                      unit: string(stmt, 4),
                                      source: string(stmt, 5),
                                      notes: string(stmt, 6)))
            }
            return out
        }
    }

    /// Manual (offline) reading — `AppDb.addManualReading`.
    @discardableResult
    func addManualReading(meterId: String, recordedAt: String, value: Double,
                          unit: String = "m3", notes: String) -> String {
        let id = UUID().uuidString
        queue.sync {
            run("""
            INSERT OR REPLACE INTO readings(id,meter_id,device_id,recorded_at,received_at,value,
                unit,source,status,notes,raw_payload_json,metadata_json,synced_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [id, meterId, meterId, recordedAt, recordedAt, value, unit,
                  "manual", "captured", notes, "null", "null", recordedAt])
        }
        return id
    }

    /// BLE-captured reading — `AppDb.addBluetoothReading`.
    /// Also writes the five metric snapshots and queues a sync task.
    @discardableResult
    func addBluetoothReading(meterId: String, deviceId: String, recordedAt: String,
                             metrics: LiveMetrics, notes: String, location: String) -> String {
        let id = UUID().uuidString

        var value: Double
        var unit: String
        if metrics.hasTotal {
            value = Double(metrics.total); unit = "m³"
        } else if metrics.hasFlowRate {
            value = Double(metrics.flowRate); unit = "m³/h"
        } else {
            value = Double.nan; unit = "m³"
        }

        var meta: [String: Any] = [
            "device": deviceId,
            "location": location,
            "summary": metrics.summary,
        ]
        if metrics.hasFlowCoefficient {
            meta["flowCoefficient"] = Double(metrics.flowCoefficient)
        }
        let metaJson = (try? JSONSerialization.data(withJSONObject: meta))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        queue.sync {
            exec("BEGIN IMMEDIATE TRANSACTION")
            run("""
            INSERT OR REPLACE INTO readings(id,meter_id,device_id,recorded_at,received_at,value,
                unit,source,status,notes,raw_payload_json,metadata_json,
                flow_rate,pressure,temperature,synced_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [id, meterId, deviceId, recordedAt, recordedAt, value.magnitude > 0 ? value : nil,
                  unit, "ble", "captured", notes, metrics.summary, metaJson,
                  metrics.hasFlowRate ? Double(metrics.flowRate) : nil,
                  metrics.hasPressure ? Double(metrics.pressure) : nil,
                  metrics.hasTemperature ? Double(metrics.temperature) : nil,
                  ""])

            putSnapshotUnlocked(readingId: id, meterId: meterId, capturedAt: recordedAt,
                                key: "flow_rate", value: metrics.hasFlowRate ? Double(metrics.flowRate) : nil,
                                unit: "m³/h", description: "瞬时流量")
            putSnapshotUnlocked(readingId: id, meterId: meterId, capturedAt: recordedAt,
                                key: "pressure", value: metrics.hasPressure ? Double(metrics.pressure) : nil,
                                unit: "kPa", description: "压力")
            putSnapshotUnlocked(readingId: id, meterId: meterId, capturedAt: recordedAt,
                                key: "temperature", value: metrics.hasTemperature ? Double(metrics.temperature) : nil,
                                unit: "℃", description: "温度")
            putSnapshotUnlocked(readingId: id, meterId: meterId, capturedAt: recordedAt,
                                key: "total", value: metrics.hasTotal ? Double(metrics.total) : nil,
                                unit: "m³", description: "累计流量")
            putSnapshotUnlocked(readingId: id, meterId: meterId, capturedAt: recordedAt,
                                key: "flow_coefficient",
                                value: metrics.hasFlowCoefficient ? Double(metrics.flowCoefficient) : nil,
                                unit: "", description: "流量系数")

            run("""
            INSERT OR REPLACE INTO sync_queue(id,reading_id,meter_id,status,action,payload_json,created_at)
            VALUES(?,?,?,?,?,?,?)
            """, [UUID().uuidString, id, meterId, "pending", "upload", metaJson, recordedAt])
            exec("COMMIT")
        }
        return id
    }

    func deleteReading(id: String) {
        queue.sync {
            exec("BEGIN IMMEDIATE TRANSACTION")
            run("DELETE FROM metric_snapshots WHERE reading_id=?", [id])
            run("DELETE FROM sync_queue WHERE reading_id=?", [id])
            run("DELETE FROM readings WHERE id=?", [id])
            exec("COMMIT")
        }
    }

    // MARK: - Snapshots

    func listSnapshots(readingId: String) -> [MetricSnapshot] {
        queue.sync {
            var out: [MetricSnapshot] = []
            let sql = """
            SELECT id,reading_id,meter_id,captured_at,metric_key,value_text,value_number,value_type,
                   unit,source,recorded_by,description,metadata_json,created_at
            FROM metric_snapshots WHERE reading_id=? ORDER BY captured_at
            """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, [readingId])
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(MetricSnapshot(
                    id: string(stmt, 0), readingId: string(stmt, 1), meterId: string(stmt, 2),
                    capturedAt: string(stmt, 3), metricKey: string(stmt, 4), valueText: string(stmt, 5),
                    valueNumber: double(stmt, 6), valueType: string(stmt, 7), unit: string(stmt, 8),
                    source: string(stmt, 9), recordedBy: string(stmt, 10), description: string(stmt, 11),
                    metadataJson: string(stmt, 12), createdAt: string(stmt, 13)))
            }
            return out
        }
    }

    private func putSnapshotUnlocked(readingId: String, meterId: String, capturedAt: String,
                                     key: String, value: Double?, unit: String, description: String) {
        run("""
        INSERT OR REPLACE INTO metric_snapshots(id,reading_id,meter_id,captured_at,metric_key,
            value_text,value_number,value_type,unit,source,description,created_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        """, [UUID().uuidString, readingId, meterId, capturedAt, key,
              value.map { String(format: "%.4f", $0) } ?? "",
              value, "REAL", unit, "ble", description, capturedAt])
    }

    // MARK: - Sync queue

    func countPendingSync() -> Int {
        queue.sync {
            guard let stmt = prepare("SELECT COUNT(*) FROM sync_queue WHERE status='pending'") else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    /// Human-readable queue lines: "meterId @ createdAt :: payload"
    func listPendingSync(limit: Int = 50) -> [String] {
        queue.sync {
            var out: [String] = []
            let sql = """
            SELECT meter_id, created_at, payload_json FROM sync_queue
            WHERE status='pending' ORDER BY created_at DESC LIMIT ?
            """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, [limit])
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append("\(string(stmt, 0)) @ \(string(stmt, 1)) :: \(string(stmt, 2))")
            }
            return out
        }
    }

    func markAllSynced() {
        queue.sync {
            run("UPDATE sync_queue SET status='synced', synced_at=? WHERE status='pending'",
                [Timestamps.now()])
        }
    }

    // MARK: - Seeding

    /// Loads the bundled meter/reading/snapshot JSON on first launch.
    /// These are the same files the Android build seeds from, so the user's
    /// existing history appears immediately.
    func seedIfEmpty(bundle: Bundle = .main) {
        let already = queue.sync { () -> Int in
            guard let stmt = prepare("SELECT COUNT(*) FROM meters") else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
        guard already == 0 else { return }

        let pairs = [("meters", "meters"), ("readings", "readings"),
                     ("metric_snapshots", "metric_snapshots")]
        for (table, file) in pairs {
            guard let url = bundle.url(forResource: file, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { continue }
            importRows(rows, into: table)
        }
    }

    /// Bulk insert of loosely-typed JSON rows (used by seeding and by import).
    func importRows(_ rows: [[String: Any]], into table: String) {
        guard !rows.isEmpty else { return }
        queue.sync {
            exec("BEGIN IMMEDIATE TRANSACTION")
            for row in rows {
                let columns = row.keys.sorted()
                let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ",")
                let sql = "INSERT OR REPLACE INTO \(table)(\(columns.joined(separator: ","))) VALUES(\(placeholders))"
                let values: [Any?] = columns.map { key -> Any? in
                    let v = row[key]
                    if v is NSNull { return nil }
                    if let n = v as? NSNumber {
                        // Keep integral values integral; SQLite is dynamically typed anyway.
                        return n.doubleValue
                    }
                    return v as? String
                }
                run(sql, values)
            }
            exec("COMMIT")
        }
    }

    // MARK: - Export / import

    /// Writes the three JSON tables next to each other in `directory`.
    @discardableResult
    func exportAll(to directory: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tables = ["meters", "readings", "metric_snapshots", "sync_queue"]
        for table in tables {
            let rows = dump(table: table)
            guard let data = try? JSONSerialization.data(withJSONObject: rows,
                                                        options: [.prettyPrinted, .sortedKeys])
            else { continue }
            try? data.write(to: directory.appendingPathComponent("\(table).json"))
        }
        return true
    }

    func dump(table: String) -> [[String: Any]] {
        queue.sync {
            var out: [[String: Any]] = []
            guard let stmt = prepare("SELECT * FROM \(table)") else { return [] }
            defer { sqlite3_finalize(stmt) }
            let colCount = sqlite3_column_count(stmt)
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: Any] = [:]
                for c in 0..<colCount {
                    let name = String(cString: sqlite3_column_name(stmt, c))
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_NULL:
                        row[name] = NSNull()
                    case SQLITE_INTEGER:
                        row[name] = Int(sqlite3_column_int64(stmt, c))
                    case SQLITE_FLOAT:
                        row[name] = sqlite3_column_double(stmt, c)
                    default:
                        row[name] = string(stmt, c)
                    }
                }
                out.append(row)
            }
            return out
        }
    }

    var totalReadingCount: Int {
        queue.sync {
            guard let stmt = prepare("SELECT COUNT(*) FROM readings") else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }
}
