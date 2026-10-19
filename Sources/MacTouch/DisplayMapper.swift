import Foundation
import AppKit

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let bounds: CGRect       // global points, origin top-left (CG coordinate space)
    let rotation: Int        // 0 / 90 / 180 / 270
    let isBuiltin: Bool
    let isMain: Bool
    let mirrorOf: CGDirectDisplayID
}

enum Displays {
    static func all() -> [DisplayInfo] {
        var n: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetOnlineDisplayList(n, &ids, &n)
        var out: [DisplayInfo] = []
        for id in ids.prefix(Int(n)) {
            let mirror = CGDisplayMirrorsDisplay(id)
            let effective = mirror == kCGNullDirectDisplay ? id : mirror
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == effective }?.localizedName ?? "Display \(id)"
            out.append(DisplayInfo(id: id, name: name,
                                   vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                                   bounds: CGDisplayBounds(effective), rotation: Int(CGDisplayRotation(id).rounded()),
                                   isBuiltin: CGDisplayIsBuiltin(id) != 0, isMain: CGDisplayIsMain(id) != 0, mirrorOf: mirror))
        }
        return out
    }

    /// Choose the display a touch device should drive.
    static func resolve(_ cfg: DeviceConfig?, displays: [DisplayInfo]) -> DisplayInfo? {
        if let cfg = cfg {
            if let v = cfg.displayVendor, let m = cfg.displayModel,
               let d = displays.first(where: { $0.vendor == v && $0.model == m && (cfg.displaySerial == nil || cfg.displaySerial == 0 || $0.serial == cfg.displaySerial) }) { return d }
            if let n = cfg.displayName, let d = displays.first(where: { $0.name == n }) { return d }
        }
        let external = displays.filter { !$0.isBuiltin }
        if external.count == 1 { return external[0] }
        if external.isEmpty { return displays.first { $0.isMain } }
        return nil   // ambiguous: user must pick in Settings
    }

    /// Map a normalized panel coordinate to a global point on the display, honouring rotation
    /// (CGDisplayBounds is already the rotated frame; the HID panel reports native orientation).
    static func point(for c: Contact, on d: DisplayInfo, cfg: DeviceConfig) -> CGPoint {
        var u = c.x, v = c.y
        if cfg.swapXY { swap(&u, &v) }
        if cfg.invertX { u = 1 - u }
        if cfg.invertY { v = 1 - v }
        // calibration
        let cw = max(cfg.calMaxX - cfg.calMinX, 0.01), ch = max(cfg.calMaxY - cfg.calMinY, 0.01)
        u = (u - cfg.calMinX) / cw; v = (v - cfg.calMinY) / ch
        switch d.rotation {
        case 90:  (u, v) = (1 - v, u)
        case 180: (u, v) = (1 - u, 1 - v)
        case 270: (u, v) = (v, 1 - u)
        default: break
        }
        u = min(max(u, 0), 1); v = min(max(v, 0), 1)
        return CGPoint(x: d.bounds.minX + u * d.bounds.width, y: d.bounds.minY + v * d.bounds.height)
    }
}
