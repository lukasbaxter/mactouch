import Foundation
import CoreGraphics

var failures = 0
func check(_ cond: Bool, _ msg: String) { if cond { print("  ok   \(msg)") } else { failures += 1; print("  FAIL \(msg)") } }

// 1. Descriptor parser against the real Dell P2424HT / SiW controller descriptor.
let hex = "050d0904a1018510050d0922a102094215002501750195018102950781037508095195018102050126ff7f7510550d65110930350047e0cd00009501810247ce73000009318102c0" +
    String(repeating: "050d0922a102094215002501750195018102950781037508095195018102050126ff7f7510550d65110930350047e0cd00009501810247ce73000009318102c0", count: 9) +
    "050d0954257f950175088102050d550c66011047ffff000027ffff000075109501095681028508095575089501250ab10285060600ff09c5150026ff007508960001b102c005010902a1010901a10085020509190129031500250175019503810275019505810305010930150026ff0f350046ff0f7510950181020931150026ff0f350046ff0f751095018102c0c0"
var bytes: [UInt8] = []
var i = hex.startIndex
while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
print("descriptor parse")
let layouts = HIDDescriptorParser.parse(bytes)
let r16 = layouts.first { $0.reportID == 16 }!
check(r16.appUsage == 0x0D0004, "report 16 belongs to Digitizer/TouchScreen")
check(r16.byteLength == 63, "report 16 is 63 data bytes (got \(r16.byteLength))")
let xs = r16.fields.filter { $0.usagePage == 1 && $0.usage == 0x30 }
let tips = r16.fields.filter { $0.usagePage == 0x0D && $0.usage == 0x42 }
check(xs.count == 10 && tips.count == 10, "10 X fields and 10 tip switches")
check(xs[0].bitOffset == 16 && xs[0].bitSize == 16 && xs[0].logicalMax == 32767, "first X at bit 16, 16 bits, max 32767 (off=\(xs[0].bitOffset))")
check(tips[1].bitOffset == 48, "second finger tip at bit 48 (got \(tips[1].bitOffset))")
let cc = r16.fields.first { $0.usagePage == 0x0D && $0.usage == 0x54 }!
check(cc.bitOffset == 480 && cc.bitSize == 8, "contact count at bit 480 (got \(cc.bitOffset))")
check(Set(xs.map { $0.collection }).count == 10, "each finger in its own collection")
let r2 = layouts.first { $0.reportID == 2 }!
check(r2.appUsage == 0x010002, "report 2 is the mouse collection")

// 2. Extract from a real captured report: 10 01 01 00 00 2e 7b ... (tip=1 id=1 x=0 y=0x7b2e)
let raw: [UInt8] = [0x01, 0x01, 0x00, 0x00, 0x2e, 0x7b] + [UInt8](repeating: 0, count: 57)
raw.withUnsafeBufferPointer { b in
    check(HIDDescriptorParser.extract(b, bitOffset: 0, bitSize: 1) == 1, "tip switch = 1")
    check(HIDDescriptorParser.extract(b, bitOffset: 8, bitSize: 8) == 1, "contact id = 1")
    check(HIDDescriptorParser.extract(b, bitOffset: 16, bitSize: 16) == 0, "x = 0")
    check(HIDDescriptorParser.extract(b, bitOffset: 32, bitSize: 16) == 0x7b2e, "y = 0x7b2e")
}
// unaligned extraction
let odd: [UInt8] = [0b1010_0000, 0b0000_0101]
odd.withUnsafeBufferPointer { b in check(HIDDescriptorParser.extract(b, bitOffset: 5, bitSize: 6) == 0b101101, "unaligned 6-bit field") }

// 3. Display mapping with rotation and flips.
print("display mapping")
let disp = DisplayInfo(id: 3, name: "DELL", vendor: 0, model: 0, serial: 0, bounds: CGRect(x: 3024, y: 0, width: 1920, height: 1080), rotation: 0, isBuiltin: false, isMain: false, mirrorOf: 0)
let p = Displays.point(for: Contact(id: 1, x: 0.5, y: 0.25, down: true), on: disp, cfg: DeviceConfig())
check(abs(p.x - (3024 + 960)) < 0.01 && abs(p.y - 270) < 0.01, "centre-ish maps into the display's global rect (\(p))")
let rot = DisplayInfo(id: 3, name: "DELL", vendor: 0, model: 0, serial: 0, bounds: CGRect(x: 0, y: 0, width: 1080, height: 1920), rotation: 90, isBuiltin: false, isMain: false, mirrorOf: 0)
let pr = Displays.point(for: Contact(id: 1, x: 1.0, y: 0.0, down: true), on: rot, cfg: DeviceConfig())
check(abs(pr.x - 1080) < 0.01 && abs(pr.y - 1920) < 0.01, "panel top-right -> bottom-right when display rotated 90° (\(pr))")
var flip = DeviceConfig(); flip.invertX = true
let pf = Displays.point(for: Contact(id: 1, x: 0.0, y: 0.0, down: true), on: disp, cfg: flip)
check(abs(pf.x - 4944) < 0.01, "invertX moves x=0 to the right edge (\(pf))")

// 4. Gesture recognizer with synthetic frames.
print("gesture recognizer")
final class Sink: GestureSink {
    var log: [String] = []
    var mapped: Set<Gesture> = Set(Gesture.allCases).subtracting([.doubleTap1, .edgeTop, .edgeBottom, .rotateCW, .rotateCCW])
    func pointerMoved(to p: CGPoint) {}
    func discrete(_ g: Gesture, at p: CGPoint, clickCount: Int) { log.append("\(g.rawValue)x\(clickCount)") }
    func continuousBegan(_ g: Gesture, at p: CGPoint) { log.append("\(g.rawValue):begin") }
    func continuousChanged(_ g: Gesture, to p: CGPoint, delta: CGVector) { if log.last != "\(g.rawValue):change" { log.append("\(g.rawValue):change") } }
    func continuousEnded(_ g: Gesture, at p: CGPoint, velocity: CGVector) { log.append("\(g.rawValue):end") }
    func isMapped(_ g: Gesture) -> Bool { mapped.contains(g) }
}
func run(_ steps: [(Double, [TouchPoint])], ticks: [Double] = []) -> [String] {
    let s = Sink(); let r = GestureRecognizer(tuning: Tuning()); r.timerQueue = nil; r.sink = s
    r.displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    var events: [(Double, Bool, [TouchPoint])] = steps.map { ($0.0, false, $0.1) } + ticks.map { ($0, true, []) }
    events.sort { $0.0 < $1.0 }
    for e in events { if e.1 { r.tick(now: e.0) } else { r.frame(e.2, now: e.0) } }
    return s.log
}
func pt(_ id: Int, _ x: Double, _ y: Double) -> TouchPoint { TouchPoint(id: id, point: CGPoint(x: x, y: y)) }
var l = run([(0, [pt(1, 500, 500)]), (0.05, [pt(1, 502, 501)]), (0.1, [])])
check(l == ["tap1x1"], "tap -> tap1 x1 (\(l))")
l = run([(0, [pt(1, 500, 500)]), (0.1, []), (0.2, [pt(1, 503, 500)]), (0.3, [])])
check(l == ["tap1x1", "tap1x2"], "two quick taps -> click count 2 (\(l))")
l = run([(0, [pt(1, 500, 500)]), (0.05, [pt(1, 520, 500)]), (0.2, [pt(1, 600, 500)]), (0.3, [])])
check(l == ["drag1:begin", "drag1:change", "drag1:end"], "move beyond threshold -> drag (\(l))")
l = run([(0, [pt(1, 500, 500)]), (0.3, [pt(1, 501, 500)]), (0.9, [])], ticks: [0.6])
check(l == ["longPress1x1"], "hold still -> long press (\(l))")
l = run([(0, [pt(1, 500, 500)]), (0.02, [pt(1, 500, 500), pt(2, 560, 500)]), (0.12, [pt(2, 560, 500)]), (0.15, [])])
check(l == ["tap2x1"], "two-finger tap (\(l))")
l = run([(0, [pt(1, 500, 500), pt(2, 560, 500)]), (0.05, [pt(1, 500, 520), pt(2, 560, 520)]), (0.1, [pt(1, 500, 600), pt(2, 560, 600)]), (0.2, [])])
check(l == ["scroll2:begin", "scroll2:change", "scroll2:end"], "two fingers moving together -> scroll (\(l))")
l = run([(0, [pt(1, 500, 500), pt(2, 600, 500)]), (0.05, [pt(1, 480, 500), pt(2, 620, 500)]), (0.1, [pt(1, 440, 500), pt(2, 660, 500)]), (0.2, [])])
check(l.contains("pinchOutx1") && !l.contains("scroll2:begin"), "fingers spreading -> pinch out (\(l))")
l = run([(0, [pt(1, 500, 500), pt(2, 560, 500), pt(3, 620, 500)]), (0.05, [pt(1, 460, 500), pt(2, 520, 500), pt(3, 580, 500)]), (0.15, [pt(1, 400, 500), pt(2, 460, 500), pt(3, 520, 500)]), (0.3, [])])
check(l == ["swipe3Leftx1"], "three fingers moving left -> swipe3Left (\(l))")
l = run([(0, [pt(1, 5, 500)]), (0.05, [pt(1, 30, 502)]), (0.2, [pt(1, 120, 505)]), (0.3, [])])
check(l == ["edgeLeftx1"], "start at left edge, move inward -> edgeLeft (\(l))")
l = run([(0, [pt(1, 500, 5)]), (0.05, [pt(1, 500, 30)]), (0.2, [pt(1, 500, 120)]), (0.3, [])])
check(l == ["drag1:begin", "drag1:change", "drag1:end"], "unmapped top edge -> plain drag (\(l))")
l = run([(0, [pt(1, 500, 500)]), (0.03, [pt(1, 520, 500)]), (0.05, [pt(1, 520, 500), pt(2, 580, 500)]), (0.1, [pt(1, 520, 540), pt(2, 580, 540)]), (0.2, [pt(1, 520, 600), pt(2, 580, 600)]), (0.3, [])])
check(l.first == "scroll2:begin" && !l.contains("drag1:begin"), "second finger within the wait window converts a starting drag into scroll (\(l))")

// 5. Config round trip.
print("config")
var c = Config(); c.gestures[Gesture.tap3.rawValue] = .shortcut(KeyShortcut(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue)); c.gestures[Gesture.swipe4Up.rawValue] = .shell("say hi")
let data = try! JSONEncoder().encode(c)
let back = try! JSONDecoder().decode(Config.self, from: data)
check(back == c, "config JSON round trip")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
