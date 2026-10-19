import Foundation
import IOKit.hid
import ApplicationServices

let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
print("InputMonitoring access:", im.rawValue, "(0=granted,1=denied,2=unknown)")
print("Accessibility trusted:", AXIsProcessTrusted())

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [kIOHIDDeviceUsagePageKey as String: 0x0D, kIOHIDDeviceUsageKey as String: 0x04]
IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
print("ManagerOpen:", String(format: "0x%08x", r))
let devs = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
print("matched devices:", devs.count)
for d in devs {
  let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
  let vid = IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int ?? 0
  let pid = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? 0
  print(" dev:", name, String(format:"%04x:%04x", vid, pid))
  if let els = IOHIDDeviceCopyMatchingElements(d, nil, 0) as? [IOHIDElement] {
    for e in els {
      let t = IOHIDElementGetType(e).rawValue
      if t == kIOHIDElementTypeCollection.rawValue { continue }
      print(String(format:"   el rid=%d up=0x%02x u=0x%02x type=%d lmin=%d lmax=%d size=%d", IOHIDElementGetReportID(e), IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e), t, IOHIDElementGetLogicalMin(e), IOHIDElementGetLogicalMax(e), IOHIDElementGetReportSize(e)))
    }
  }
}
var count = 0
IOHIDManagerRegisterInputReportCallback(mgr, { ctx, res, sender, type, rid, data, len in
  count += 1
  let b = UnsafeBufferPointer(start: data, count: Int(len))
  if count <= 40 { print("report rid=\(rid) len=\(len): " + b.prefix(24).map{String(format:"%02x",$0)}.joined(separator:" ")) }
}, nil)
let deadline = Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "15") ?? 15)
while Date() < deadline { CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.25, false) }
print("total reports:", count)
