import Foundation
import IOKit.hid
import AppKit

/// One connected touchscreen: HID device + display mapping + recognizer.
final class TouchPipeline: GestureSink {
    let device: TouchDevice
    let recognizer: GestureRecognizer
    unowned let engine: Engine
    var display: DisplayInfo?
    var cfg: DeviceConfig
    private var activeContinuous: [Gesture: Action] = [:]
    var lastFrame: TouchFrame?
    var touchCount = 0

    init(device: TouchDevice, engine: Engine) {
        self.device = device
        self.engine = engine
        self.cfg = engine.config.devices[device.key] ?? DeviceConfig()
        self.recognizer = GestureRecognizer(tuning: engine.config.tuning)
        recognizer.sink = self
        device.onFrame = { [weak self] f in self?.frame(f) }
    }

    func applyConfig() {
        cfg = engine.config.devices[device.key] ?? DeviceConfig()
        recognizer.tuning = engine.config.tuning
        display = Displays.resolve(cfg, displays: engine.displays)
        recognizer.displayBounds = display?.bounds ?? .zero
        Log.i("\(device.name) [\(device.key)] -> \(display.map { "\($0.name) \($0.bounds) rot=\($0.rotation)" } ?? "NO DISPLAY (assign in Settings)")")
    }

    private var routed: [Int: CGPoint] = [:]   // contact id -> last point, for contacts sent to grandMA3

    private func frame(_ f: TouchFrame) {
        lastFrame = f
        engine.rawFrameObserver?(self, f)
        guard cfg.enabled, let d = display else { return }
        if !f.contacts.isEmpty { touchCount += f.contacts.count }
        var pts = f.contacts.map { TouchPoint(id: $0.id, point: Displays.point(for: $0, on: d, cfg: cfg)) }
        Log.d("frame " + pts.map { String(format: "%d:(%.0f,%.0f)", $0.id, $0.point.x, $0.point.y) }.joined(separator: " "))
        // grandMA3 onPC routing: contacts that start on an onPC window go to the MA3 bridge, with
        // their real contact ids, so onPC gets true multi-point input.
        let bridge = engine.ma3
        if engine.config.ma3.enabled, bridge.pluginAlive {
            let key = device.key
            var cursorPts: [TouchPoint] = []
            for p in pts {
                if let last = routed[p.id] {
                    if p.point != last { bridge.move(device: key, contact: p.id, at: p.point, display: d) }
                    routed[p.id] = p.point
                } else if let w = bridge.window(at: p.point), !recognizerBusy {
                    bridge.press(device: key, contact: p.id, at: p.point, window: w, display: d)
                    routed[p.id] = p.point
                } else {
                    cursorPts.append(p)
                }
            }
            let live = Set(pts.map { $0.id })
            for (id, last) in routed where !live.contains(id) {
                bridge.release(device: key, contact: id, at: last, display: d)
                routed[id] = nil
            }
            pts = cursorPts
        } else if !routed.isEmpty {
            for (id, last) in routed { bridge.release(device: device.key, contact: id, at: last, display: d) }
            routed.removeAll()
        }
        recognizer.frame(pts, now: f.time)
    }

    /// True while a cursor gesture is in progress; new fingers then stay with the recognizer.
    private var recognizerBusy: Bool { recognizer.isActive }

    // GestureSink
    func pointerMoved(to p: CGPoint) { engine.runner.movePointer(to: p) }
    func discrete(_ g: Gesture, at p: CGPoint, clickCount: Int) {
        let a = engine.config.action(for: g)
        Log.d("gesture \(g.rawValue) x\(clickCount) -> \(a)")
        engine.gestureObserver?(g)
        engine.runner.perform(a, at: p, clickCount: clickCount)
    }
    func continuousBegan(_ g: Gesture, at p: CGPoint) {
        let a = engine.config.action(for: g)
        Log.d("gesture \(g.rawValue) began -> \(a)")
        engine.gestureObserver?(g)
        activeContinuous[g] = a
        engine.runner.begin(a, at: p)
    }
    func continuousChanged(_ g: Gesture, to p: CGPoint, delta: CGVector) {
        guard let a = activeContinuous[g] else { return }
        engine.runner.change(a, to: p, delta: delta)
    }
    func continuousEnded(_ g: Gesture, at p: CGPoint, velocity: CGVector) {
        guard let a = activeContinuous.removeValue(forKey: g) else { return }
        Log.d("gesture \(g.rawValue) ended")
        engine.runner.end(a, at: p, velocity: velocity)
    }
    func isMapped(_ g: Gesture) -> Bool {
        let a = engine.config.action(for: g)
        if g == .doubleTap1 { return a != .none && a != .builtin(.doubleClick) && a != .builtin(.leftClick) }
        return a != .none
    }
}

/// Owns the IOHIDManager, hot-plug, display reconfiguration and the per-device pipelines.
final class Engine {
    private(set) var config: Config
    let runner: ActionRunner
    let ma3: MA3Bridge
    private var manager: IOHIDManager?
    private(set) var pipelines: [String: TouchPipeline] = [:]
    private(set) var displays: [DisplayInfo] = []
    var onChange: (() -> Void)?                       // devices/displays changed (UI refresh)
    var rawFrameObserver: ((TouchPipeline, TouchFrame) -> Void)?
    var gestureObserver: ((Gesture) -> Void)?
    private(set) var running = false
    private(set) var lastOpenError: IOReturn = kIOReturnSuccess

    init(config: Config) {
        self.config = config
        runner = ActionRunner(tuning: config.tuning)
        ma3 = MA3Bridge(cfg: config.ma3)
        displays = Displays.all()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard let ctx = ctx, flags.contains(.beginConfigurationFlag) == false else { return }
            let me = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.displaysChanged() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func update(config: Config) {
        self.config = config
        runner.tuning = config.tuning
        ma3.cfg = config.ma3
        for p in pipelines.values { p.applyConfig() }
        onChange?()
    }

    func displaysChanged() {
        displays = Displays.all()
        Log.i("displays: " + displays.map { "\($0.name)#\($0.id) \($0.bounds) rot=\($0.rotation)\($0.mirrorOf != kCGNullDirectDisplay ? " (mirror of \($0.mirrorOf))" : "")" }.joined(separator: "; "))
        for p in pipelines.values { p.applyConfig() }
        onChange?()
    }

    /// Returns true when the HID manager opened (Input Monitoring granted).
    @discardableResult
    func start() -> Bool {
        if running { return true }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey as String: Int(HU.pageDigitizer), kIOHIDDeviceUsageKey as String: Int(HU.touchScreen)],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, match as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().deviceAdded(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().deviceRemoved(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        lastOpenError = r
        if r != kIOReturnSuccess {
            Log.w(String(format: "IOHIDManagerOpen failed: 0x%08x (Input Monitoring not granted?)", r))
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return false
        }
        manager = m
        running = true
        Log.i("engine started")
        return true
    }

    func stop() {
        guard let m = manager else { return }
        for p in pipelines.values { p.device.stop() }
        pipelines.removeAll()
        runner.releaseAll()
        ma3.releaseAll()
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        manager = nil; running = false
        onChange?()
    }

    private func deviceAdded(_ dev: IOHIDDevice) {
        guard let td = TouchDevice(device: dev) else {
            Log.w("ignoring HID device without a usable touch-screen report: \(IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?")")
            return
        }
        if pipelines[td.key] != nil { return }
        let p = TouchPipeline(device: td, engine: self)
        pipelines[td.key] = p
        p.applyConfig()
        td.start()
        Log.i("touchscreen attached: \(td.name) \(td.key) (\(td.contactCountMax) contacts)")
        onChange?()
    }

    private func deviceRemoved(_ dev: IOHIDDevice) {
        if let (k, p) = pipelines.first(where: { $0.value.device.device == dev }) {
            p.device.stop()
            pipelines[k] = nil
            runner.releaseAll()
            Log.i("touchscreen detached: \(p.device.name)")
            onChange?()
        }
    }
}
