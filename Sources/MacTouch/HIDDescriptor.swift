import Foundation

/// One data field inside a HID input report, as laid out by the report descriptor.
struct HIDField {
    let reportID: UInt8
    let usagePage: UInt32
    let usage: UInt32
    let bitOffset: Int        // offset in bits, counted after the report-ID byte
    let bitSize: Int
    let logicalMin: Int32
    let logicalMax: Int32
    let physicalMin: Int32
    let physicalMax: Int32
    let isConstant: Bool
    let collection: Int       // innermost collection instance id
    let collectionUsage: UInt32  // (page<<16|usage) of innermost collection
    let appUsage: UInt32      // (page<<16|usage) of the top-level application collection
}

struct HIDReportLayout {
    let reportID: UInt8
    let appUsage: UInt32
    let fields: [HIDField]
    let byteLength: Int       // excluding the report-ID byte
}

/// Minimal but complete-enough HID report descriptor parser (main/global/local items, push/pop,
/// usage min/max, report IDs, collections). Produces per-report-ID field layouts for INPUT items.
enum HIDDescriptorParser {
    struct GlobalState {
        var usagePage: UInt32 = 0
        var logicalMin: Int32 = 0
        var logicalMax: Int32 = 0
        var physicalMin: Int32 = 0
        var physicalMax: Int32 = 0
        var reportSize: Int = 0
        var reportCount: Int = 0
        var reportID: UInt8 = 0
    }

    static func parse(_ desc: [UInt8]) -> [HIDReportLayout] {
        var g = GlobalState()
        var stack: [GlobalState] = []
        var usages: [UInt32] = []         // page<<16 | usage
        var usageMin: UInt32? = nil
        var bitPos: [UInt8: Int] = [:]    // per report ID
        var fields: [UInt8: [HIDField]] = [:]
        var appOf: [UInt8: UInt32] = [:]
        var collStack: [(id: Int, usage: UInt32)] = []
        var collCounter = 0
        var appUsage: UInt32 = 0
        var i = 0
        func signed(_ v: UInt32, _ size: Int) -> Int32 {
            switch size {
            case 1: return Int32(Int8(truncatingIfNeeded: v))
            case 2: return Int32(Int16(truncatingIfNeeded: v))
            default: return Int32(truncatingIfNeeded: v)
            }
        }
        while i < desc.count {
            let b = desc[i]; i += 1
            if b == 0xFE { // long item
                guard i < desc.count else { break }
                let n = Int(desc[i]); i += 2 + n; continue
            }
            var size = Int(b & 3); if size == 3 { size = 4 }
            let type = (b >> 2) & 3
            let tag = b >> 4
            var raw: UInt32 = 0
            for k in 0..<size where i + k < desc.count { raw |= UInt32(desc[i + k]) << (8 * k) }
            i += size
            switch type {
            case 1: // global
                switch tag {
                case 0: g.usagePage = raw
                case 1: g.logicalMin = signed(raw, size)
                case 2: g.logicalMax = signed(raw, size)
                case 3: g.physicalMin = signed(raw, size)
                case 4: g.physicalMax = signed(raw, size)
                case 7: g.reportSize = Int(raw)
                case 8: g.reportID = UInt8(raw & 0xFF)
                case 9: g.reportCount = Int(raw)
                case 10: stack.append(g)
                case 11: if let s = stack.popLast() { g = s }
                default: break
                }
            case 2: // local
                let full = size == 4 ? raw : (g.usagePage << 16 | raw)
                switch tag {
                case 0: usages.append(full)
                case 1: usageMin = full
                case 2:
                    if let lo = usageMin, lo <= full { for u in lo...full { usages.append(u) } }
                    usageMin = nil
                default: break
                }
            case 0: // main
                switch tag {
                case 10: // collection
                    let u = usages.first ?? 0
                    collCounter += 1
                    if collStack.isEmpty { appUsage = u }
                    collStack.append((collCounter, u))
                    usages.removeAll()
                case 12: // end collection
                    _ = collStack.popLast()
                    usages.removeAll()
                case 8, 9, 11: // input / output / feature
                    let isConst = (raw & 1) != 0
                    let rid = g.reportID
                    if tag == 8 {
                        var pos = bitPos[rid] ?? 0
                        if appOf[rid] == nil { appOf[rid] = appUsage }
                        var lmax = g.logicalMax
                        // Logical max is unsigned when min >= 0 and the signed read went negative.
                        if g.logicalMin >= 0 && lmax < 0 && g.reportSize <= 32 {
                            lmax = Int32(truncatingIfNeeded: UInt32(bitPattern: lmax) & ((g.reportSize >= 32) ? 0xFFFF_FFFF : ((1 << UInt32(g.reportSize)) - 1)))
                        }
                        for n in 0..<g.reportCount {
                            let u: UInt32 = isConst ? 0 : (n < usages.count ? usages[n] : (usages.last ?? 0))
                            let f = HIDField(reportID: rid, usagePage: u >> 16, usage: u & 0xFFFF,
                                             bitOffset: pos, bitSize: g.reportSize,
                                             logicalMin: g.logicalMin, logicalMax: lmax,
                                             physicalMin: g.physicalMin, physicalMax: g.physicalMax,
                                             isConstant: isConst,
                                             collection: collStack.last?.id ?? 0,
                                             collectionUsage: collStack.last?.usage ?? 0,
                                             appUsage: appUsage)
                            fields[rid, default: []].append(f)
                            pos += g.reportSize
                        }
                        bitPos[rid] = pos
                    }
                    usages.removeAll()
                default:
                    usages.removeAll()
                }
            default: break
            }
        }
        return fields.keys.sorted().map { rid in
            HIDReportLayout(reportID: rid, appUsage: appOf[rid] ?? 0, fields: fields[rid]!,
                            byteLength: ((bitPos[rid] ?? 0) + 7) / 8)
        }
    }

    /// Little-endian bit extraction.
    static func extract(_ data: UnsafeBufferPointer<UInt8>, bitOffset: Int, bitSize: Int) -> UInt32 {
        var v: UInt64 = 0
        let firstByte = bitOffset / 8
        let shift = bitOffset % 8
        var k = 0
        while k < 8 && firstByte + k < data.count {
            v |= UInt64(data[firstByte + k]) << (8 * k)
            k += 1
        }
        v >>= UInt64(shift)
        let mask: UInt64 = bitSize >= 32 ? 0xFFFF_FFFF : ((1 << UInt64(bitSize)) - 1)
        return UInt32(v & mask)
    }
}

// HID usage constants we care about.
enum HU {
    static let pageDesktop: UInt32 = 0x01
    static let pageDigitizer: UInt32 = 0x0D
    static let x: UInt32 = 0x30, y: UInt32 = 0x31
    static let touchScreen: UInt32 = 0x04, finger: UInt32 = 0x22
    static let tipSwitch: UInt32 = 0x42, inRange: UInt32 = 0x32, confidence: UInt32 = 0x47
    static let contactID: UInt32 = 0x51, contactCount: UInt32 = 0x54, scanTime: UInt32 = 0x56
}
