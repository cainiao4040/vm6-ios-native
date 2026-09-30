import Foundation

/// VM6 / A5 Modbus-like protocol.
/// Direct port of `com.kmj.meterreader.A5Protocol` (decompiled from the Android APK).
enum A5Protocol {

    // MARK: - Constants

    static let header: UInt8 = 0xA5

    static let funcReadHolding: UInt8 = 3
    static let funcWriteSingle: UInt8 = 6
    static let funcWriteMulti: UInt8 = 16
    static let funcReadRealtime: UInt8 = 71
    static let funcReadParam: UInt8 = 77

    static let regTemperature = 8
    static let regCoeff = 16

    /// Number of floats carried by a realtime (0x47) response.
    static let realtimeValueCount = 5

    // MARK: - CRC16 (Modbus, poly 0xA001, init 0xFFFF)

    static func crc16(_ bytes: [UInt8], _ start: Int, _ count: Int) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        guard count > 0, start >= 0, start + count <= bytes.count else { return crc }
        for i in start..<(start + count) {
            crc ^= UInt16(bytes[i])
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    // MARK: - Frame building

    /// `[0xA5, fn, payload..., crcLo, crcHi]` — CRC covers header + fn + payload.
    static func frame(_ fn: UInt8, _ payload: [UInt8]?) -> [UInt8] {
        let len = payload?.count ?? 0
        let bodyLen = len + 2
        var out = [UInt8](repeating: 0, count: bodyLen + 2)
        out[0] = header
        out[1] = fn
        if len > 0, let p = payload {
            out.replaceSubrange(2..<(2 + len), with: p)
        }
        let crc = crc16(out, 0, bodyLen)
        out[bodyLen] = UInt8(crc & 0xFF)
        out[bodyLen + 1] = UInt8((crc >> 8) & 0xFF)
        return out
    }

    static func readHolding(_ register: Int, _ count: Int) -> [UInt8] {
        frame(funcReadHolding, [
            UInt8((register >> 8) & 0xFF), UInt8(register & 0xFF),
            UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF),
        ])
    }

    /// 0x47 — all five live values in one response.
    static func readRealtime() -> [UInt8] { frame(funcReadRealtime, nil) }

    /// 0x4D — parameter table dump.
    static func readParamTable() -> [UInt8] { frame(funcReadParam, nil) }

    /// 0x10 write-multiple: write a float into holding register 16 (2 registers).
    static func writeCoeff(_ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return frame(funcWriteMulti, [
            0x00, 0x10,
            0x00, 0x02,
            0x04,
            UInt8((bits >> 24) & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 8) & 0xFF),
            UInt8(bits & 0xFF),
        ])
    }

    // MARK: - Frame parsing

    /// Scans a (possibly fragmented / concatenated) notification buffer for the
    /// first well-formed frame with the given function code.
    static func extractFrame(_ buffer: [UInt8], _ fn: UInt8) -> [UInt8]? {
        guard buffer.count >= 4 else { return nil }
        for i in 0..<buffer.count {
            guard i + 3 < buffer.count else { break }
            guard buffer[i] == header, buffer[i + 1] == fn else { continue }

            var len = 4
            while true {
                let end = i + len
                if end > buffer.count { break }
                let computed = crc16(buffer, i, len - 2)
                let carried = (UInt16(buffer[end - 1]) << 8) | UInt16(buffer[end - 2])
                if computed == carried {
                    return Array(buffer[i..<end])
                }
                len += 1
            }
        }
        return nil
    }

    /// Returns the payload length, or -1 when the CRC/header check fails.
    static func validate(_ frame: [UInt8]) -> Int {
        guard frame.count >= 4, frame[0] == header else { return -1 }
        let length = frame.count - 4
        let computed = crc16(frame, 0, length + 2)
        let carried = (UInt16(frame[frame.count - 1]) << 8) | UInt16(frame[frame.count - 2])
        return computed == carried ? length : -1
    }

    /// Big-endian IEEE-754 float at `offset` (firmware byte order).
    private static func beFloat(_ b: [UInt8], _ offset: Int) -> Float {
        // Built up with |= rather than a leading-`|` continuation, which Swift
        // would parse as a prefix operator.
        var bits: UInt32 = UInt32(b[offset]) << 24
        bits |= UInt32(b[offset + 1]) << 16
        bits |= UInt32(b[offset + 2]) << 8
        bits |= UInt32(b[offset + 3])
        return Float(bitPattern: bits)
    }

    /// 0x47 response → `[flowRate, pressure, temperature, total, flowCoefficient]`.
    static func parseRealtime(_ frame: [UInt8]) -> [Float]? {
        guard validate(frame) == 20, frame[1] == funcReadRealtime else { return nil }
        var out = [Float]()
        out.reserveCapacity(realtimeValueCount)
        for i in 0..<realtimeValueCount {
            out.append(beFloat(frame, i * 4 + 2))
        }
        return out
    }

    /// 0x03 response holding a single big-endian float (flow coefficient readback).
    static func parseHoldingFloat(_ frame: [UInt8]) -> Float? {
        let length = validate(frame)
        guard length >= 5, frame[1] == funcReadHolding else { return nil }
        let byteCount = Int(frame[2])
        guard byteCount == 4, length == byteCount + 1 else { return nil }
        return beFloat(frame, 3)
    }

    // MARK: - Debug helper

    static func hex(_ bytes: [UInt8]?) -> String {
        guard let bytes = bytes else { return "null" }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
