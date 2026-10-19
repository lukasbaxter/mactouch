import Foundation
import IOKit.hid

struct Contact: Equatable {
    var id: Int
    var x: Double     // normalized 0..1 in panel native orientation
    var y: Double
    var down: Bool
}

struct TouchFrame {
    var contacts: [Contact]   // only contacts with tip down
    var time: TimeInterval
}

/// Wraps one IOHIDDevice that exposes a Digitizer/TouchScreen application collection and turns
/// its raw input reports into TouchFrames. Handles parallel and hybrid report modes.
final class TouchDevice {
    let device: IOHIDDevice
    let name: String
    let vendorID: Int
    let productID: Int
    let serial: String
    let locationID: Int
    var key: String { String(format: "%04x:%04x:%@", vendorID, productID, serial.isEmpty ? String(locationID) : serial) }

    private var layouts: [UInt8: HIDReportLayout] = [:]
    private var slots: [UInt8: [[HIDField]]] = [:]   // per report: finger collections → fields
    private var countField: [UInt8: HIDField] = [:]
    private var buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize: Int
    // hybrid accumulation
    private var pending: [Contact] = []
    private var pendingExpected = 0
    var onFrame: ((TouchFrame) -> Void)?
    var contactCountMax: Int = 0

    init?(device: IOHIDDevice) {
        self.device = device
        name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Touchscreen"
        vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? ""
        locationID = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
        let maxIn = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
        bufferSize = max(maxIn, 64)
        buffer = .allocate(capacity: bufferSize)
        guard let descData = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else { return nil }
        let all = HIDDescriptorParser.parse([UInt8](descData))
        for l in all where l.appUsage == (HU.pageDigitizer << 16 | HU.touchScreen) {
            // group fields by finger collection
            var groups: [Int: [HIDField]] = [:]
            var order: [Int] = []
            for f in l.fields where !f.isConstant {
                if f.usagePage == HU.pageDigitizer && f.usage == HU.contactCount { countField[l.reportID] = f; continue }
                let isFingerField = f.collectionUsage == (HU.pageDigitizer << 16 | HU.finger)
                    || (f.usagePage == HU.pageDesktop && (f.usage == HU.x || f.usage == HU.y))
                    || (f.usagePage == HU.pageDigitizer && (f.usage == HU.tipSwitch || f.usage == HU.contactID))
                guard isFingerField else { continue }
                if groups[f.collection] == nil { order.append(f.collection) }
                groups[f.collection, default: []].append(f)
            }
            let fingerGroups = order.map { groups[$0]! }.filter { g in
                g.contains { $0.usagePage == HU.pageDesktop && $0.usage == HU.x } &&
                g.contains { $0.usagePage == HU.pageDesktop && $0.usage == HU.y }
            }
            if !fingerGroups.isEmpty {
                layouts[l.reportID] = l
                slots[l.reportID] = fingerGroups
                contactCountMax = max(contactCountMax, fingerGroups.count)
            }
        }
        if layouts.isEmpty { return nil }
        // Feature report: Contact Count Maximum (0x0D/0x55) - try to read it for information only.
        for l in all where l.appUsage == (HU.pageDigitizer << 16 | HU.touchScreen) { _ = l }
    }

    deinit { buffer.deallocate() }

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, { ctx, result, sender, type, reportID, report, length in
            guard let ctx = ctx else { return }
            let me = Unmanaged<TouchDevice>.fromOpaque(ctx).takeUnretainedValue()
            me.handle(reportID: UInt8(truncatingIfNeeded: reportID), report: report, length: Int(length))
        }, ctx)
    }

    func stop() {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, nil, nil)
    }

    private func handle(reportID: UInt8, report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard let groups = slots[reportID] else { return }
        // Data after the report-ID byte (if the device uses report IDs the first byte is the ID).
        let usesIDs = layouts.keys.contains { $0 != 0 }
        let start = usesIDs ? 1 : 0
        guard length > start else { return }
        let data = UnsafeBufferPointer(start: UnsafePointer(report + start), count: length - start)
        var count = -1
        if let cf = countField[reportID] { count = Int(HIDDescriptorParser.extract(data, bitOffset: cf.bitOffset, bitSize: cf.bitSize)) }
        var contacts: [Contact] = []
        let limit = count >= 0 ? min(groups.count, max(count, pendingExpected > 0 ? groups.count : 0)) : groups.count
        for (slotIndex, g) in groups.enumerated() {
            if count >= 0 && pendingExpected == 0 && slotIndex >= limit { break }
            var c = Contact(id: slotIndex, x: 0, y: 0, down: false)
            var sawTip = false
            for f in g {
                let raw = HIDDescriptorParser.extract(data, bitOffset: f.bitOffset, bitSize: f.bitSize)
                let range = Double(f.logicalMax - f.logicalMin)
                switch (f.usagePage, f.usage) {
                case (HU.pageDesktop, HU.x): c.x = range > 0 ? (Double(Int(raw) - Int(f.logicalMin)) / range) : 0
                case (HU.pageDesktop, HU.y): c.y = range > 0 ? (Double(Int(raw) - Int(f.logicalMin)) / range) : 0
                case (HU.pageDigitizer, HU.tipSwitch): c.down = raw != 0; sawTip = true
                case (HU.pageDigitizer, HU.contactID): c.id = Int(raw)
                default: break
                }
            }
            if !sawTip { c.down = true }
            contacts.append(c)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if count >= 0 {
            // Hybrid mode: first report carries total count, following ones carry 0.
            if pendingExpected > 0 {
                pending.append(contentsOf: contacts.prefix(pendingExpected))
                pendingExpected -= min(pendingExpected, contacts.count)
                if pendingExpected > 0 { return }
                emit(pending, now); pending = []
                return
            }
            if count > groups.count {
                pending = Array(contacts.prefix(groups.count))
                pendingExpected = count - groups.count
                return
            }
            emit(Array(contacts.prefix(count)), now)
        } else {
            emit(contacts, now)
        }
    }

    private func emit(_ cs: [Contact], _ t: TimeInterval) {
        var seen = Set<Int>()
        let down = cs.filter { $0.down && seen.insert($0.id).inserted }
        onFrame?(TouchFrame(contacts: down, time: t))
    }
}
