import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var router = SettingsTabRouter.shared
    init(state: AppState, initialTab: String) { self.state = state; SettingsTabRouter.shared.tab = initialTab }

    var body: some View {
        TabView(selection: $router.tab) {
            DevicesTab(state: state).tabItem { Text("Devices") }.tag("devices")
            GesturesTab(state: state).tabItem { Text("Gestures") }.tag("gestures")
            OptionsTab(state: state).tabItem { Text("Options") }.tag("options")
            MA3Tab(state: state).tabItem { Text("grandMA3") }.tag("ma3")
            StatusTab(state: state).tabItem { Text("Status") }.tag("status")
        }
        .padding(12)
        .frame(minWidth: 680, minHeight: 500)
    }
}

// MARK: Devices

struct DevicesTab: View {
    @ObservedObject var state: AppState
    var body: some View {
        let _ = state.tick
        let pipes = state.engine.pipelines.values.sorted { $0.device.name < $1.device.name }
        let displays = state.engine.displays
        VStack(alignment: .leading, spacing: 12) {
            if !state.engine.running {
                Label("Driver is not running. Grant Input Monitoring in the Status tab.", systemImage: "exclamationmark.triangle").foregroundColor(.orange)
            } else if pipes.isEmpty {
                Text("No touchscreen connected. Plug the monitor's USB cable into this Mac.").foregroundColor(.secondary)
            }
            ForEach(pipes, id: \.device.key) { p in
                DeviceCard(state: state, pipeline: p, displays: displays)
            }
            Divider()
            Text("Displays").font(.headline)
            ForEach(displays) { d in
                HStack {
                    Text(d.name).frame(width: 220, alignment: .leading)
                    Text("\(Int(d.bounds.width))×\(Int(d.bounds.height)) @ (\(Int(d.bounds.minX)), \(Int(d.bounds.minY)))").foregroundColor(.secondary)
                    if d.rotation != 0 { Text("rotated \(d.rotation)°").foregroundColor(.secondary) }
                    if d.isMain { Text("main").foregroundColor(.secondary) }
                    if d.mirrorOf != kCGNullDirectDisplay { Text("mirroring").foregroundColor(.secondary) }
                    Spacer()
                    Button("Identify") { IdentifyOverlay.show(d) }
                }.font(.system(size: 12))
            }
            Spacer()
        }
    }
}

struct DeviceCard: View {
    @ObservedObject var state: AppState
    let pipeline: TouchPipeline
    let displays: [DisplayInfo]
    @State private var calibrating = false

    private var cfg: Binding<DeviceConfig> {
        Binding(get: { state.config.devices[pipeline.device.key] ?? DeviceConfig() },
                set: { state.config.devices[pipeline.device.key] = $0; state.save() })
    }

    var body: some View {
        let auto = Displays.resolve(nil, displays: displays)
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "hand.tap").font(.title2)
                    VStack(alignment: .leading) {
                        Text(pipeline.device.name).font(.headline)
                        Text("USB \(String(format: "%04X:%04X", pipeline.device.vendorID, pipeline.device.productID)) · up to \(pipeline.device.contactCountMax) contacts").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: cfg.enabled)
                }
                HStack {
                    Text("Display")
                    Picker("", selection: Binding<String>(
                        get: { cfg.wrappedValue.displayVendor == nil && cfg.wrappedValue.displayName == nil ? "auto" : "\(cfg.wrappedValue.displayVendor ?? 0):\(cfg.wrappedValue.displayModel ?? 0):\(cfg.wrappedValue.displaySerial ?? 0)" },
                        set: { sel in
                            var c = cfg.wrappedValue
                            if sel == "auto" { c.displayVendor = nil; c.displayModel = nil; c.displaySerial = nil; c.displayName = nil }
                            else if let d = displays.first(where: { "\($0.vendor):\($0.model):\($0.serial)" == sel }) {
                                c.displayVendor = d.vendor; c.displayModel = d.model; c.displaySerial = d.serial; c.displayName = d.name
                            }
                            cfg.wrappedValue = c
                        })) {
                        Text("Automatic" + (auto.map { " (\($0.name))" } ?? " (ambiguous: choose one)")).tag("auto")
                        ForEach(displays) { d in Text(d.name).tag("\(d.vendor):\(d.model):\(d.serial)") }
                    }.frame(maxWidth: 360)
                    Spacer()
                    Text("Now: \(pipeline.display?.name ?? "none")").foregroundColor(pipeline.display == nil ? .orange : .secondary).font(.caption)
                }
                HStack(spacing: 16) {
                    Toggle("Swap X/Y", isOn: cfg.swapXY)
                    Toggle("Flip horizontal", isOn: cfg.invertX)
                    Toggle("Flip vertical", isOn: cfg.invertY)
                    Spacer()
                    Button(calibrating ? "Calibrating…" : "Calibrate") { calibrating = true; CalibrationOverlay.run(state: state, pipeline: pipeline) { calibrating = false } }
                        .disabled(pipeline.display == nil || calibrating)
                    Button("Reset calibration") { var c = cfg.wrappedValue; c.calMinX = 0; c.calMinY = 0; c.calMaxX = 1; c.calMaxY = 1; cfg.wrappedValue = c }
                }
                LiveTouchView(state: state, pipeline: pipeline)
            }.padding(4)
        }
    }
}

/// Small live preview of contacts for the device: proves the data path without any mouse side effects.
struct LiveTouchView: View {
    @ObservedObject var state: AppState
    let pipeline: TouchPipeline
    @State private var pts: [CGPoint] = []
    @State private var timer: Timer? = nil
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.secondary.opacity(0.08)).border(Color.secondary.opacity(0.3))
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                        .position(x: p.x * g.size.width, y: p.y * g.size.height)
                }
                Text(pts.isEmpty ? "Touch the screen to see contacts here (\(pipeline.touchCount) so far)" : "\(pts.count) contact(s)")
                    .font(.caption).foregroundColor(.secondary).padding(4)
            }
        }
        .frame(height: 90)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                let f = pipeline.lastFrame
                let fresh = f.map { ProcessInfo.processInfo.systemUptime - $0.time < 0.2 } ?? false
                pts = fresh ? (f?.contacts.map { CGPoint(x: $0.x, y: $0.y) } ?? []) : []
            }
        }
        .onDisappear { timer?.invalidate() }
    }
}

// MARK: Gestures

struct GesturesTab: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Map any gesture to an action. Last recognized: ").foregroundColor(.secondary)
                Text(state.lastGesture).bold()
                Spacer()
                Button("Restore defaults") { state.config.gestures = Config.defaultGestures; state.save() }
            }.font(.system(size: 12))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sections, id: \.self) { sec in
                        Text(sec).font(.headline).padding(.top, 8)
                        ForEach(Gesture.allCases.filter { $0.section == sec }) { g in
                            GestureRow(state: state, gesture: g)
                            Divider()
                        }
                    }
                }.padding(.trailing, 8)
            }
        }
    }
    var sections: [String] { var seen: [String] = []; for g in Gesture.allCases where !seen.contains(g.section) { seen.append(g.section) }; return seen }
}

struct GestureRow: View {
    @ObservedObject var state: AppState
    let gesture: Gesture
    private var action: Binding<Action> {
        Binding(get: { state.config.action(for: gesture) }, set: { state.config.gestures[gesture.rawValue] = $0; state.save() })
    }
    var body: some View {
        HStack(alignment: .center) {
            Text(gesture.title).frame(width: 230, alignment: .leading)
            Picker("", selection: Binding<Action.Kind>(get: { action.wrappedValue.kind }, set: { setKind($0) })) {
                ForEach(Action.Kind.allCases) { k in Text(k.title).tag(k) }
            }.frame(width: 160)
            ActionEditor(action: action, gesture: gesture)
            Spacer()
        }.font(.system(size: 12))
    }
    private func setKind(_ k: Action.Kind) {
        switch k {
        case .none: action.wrappedValue = .none
        case .builtin: action.wrappedValue = .builtin(gesture.isContinuous ? (gesture == .scroll2 ? .scroll : .leftDrag) : .leftClick)
        case .shortcut: action.wrappedValue = .shortcut(KeyShortcut(keyCode: UInt16(kVK_Space), modifiers: CGEventFlags.maskCommand.rawValue))
        case .typeText: action.wrappedValue = .typeText("")
        case .mouseButton: action.wrappedValue = .mouseButton(2)
        case .shell: action.wrappedValue = .shell("")
        case .openApp: action.wrappedValue = .openApp("")
        case .openURL: action.wrappedValue = .openURL("https://")
        }
    }
}

struct ActionEditor: View {
    @Binding var action: Action
    let gesture: Gesture
    var body: some View {
        switch action {
        case .none: EmptyView()
        case .builtin(let b):
            Picker("", selection: Binding(get: { b }, set: { action = .builtin($0) })) {
                ForEach(Builtin.allCases.filter { gesture.isContinuous || !$0.isContinuous }) { x in Text(x.title).tag(x) }
            }.frame(width: 260)
        case .shortcut(let s):
            ShortcutRecorder(shortcut: Binding(get: { s }, set: { action = .shortcut($0) }))
        case .typeText(let t):
            TextField("Text to type", text: Binding(get: { t }, set: { action = .typeText($0) })).frame(width: 260)
        case .mouseButton(let n):
            Picker("", selection: Binding(get: { n }, set: { action = .mouseButton($0) })) {
                Text("Left").tag(0); Text("Right").tag(1); Text("Middle").tag(2)
                ForEach(3..<8) { i in Text("Button \(i + 1)").tag(i) }
            }.frame(width: 140)
        case .shell(let c):
            TextField("Shell command (zsh)", text: Binding(get: { c }, set: { action = .shell($0) })).frame(width: 300).font(.system(size: 12, design: .monospaced))
        case .openApp(let a):
            HStack {
                TextField("App name or path", text: Binding(get: { a }, set: { action = .openApp($0) })).frame(width: 220)
                Button("Choose…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications")
                    if p.runModal() == .OK, let u = p.url { action = .openApp(u.path) }
                }
            }
        case .openURL(let u):
            TextField("https://… or /path/to/file", text: Binding(get: { u }, set: { action = .openURL($0) })).frame(width: 300)
        }
    }
}

/// Click, then press the key combination.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: KeyShortcut
    func makeNSView(context: Context) -> RecorderView { let v = RecorderView(); v.onChange = { shortcut = $0 }; v.shortcut = shortcut; return v }
    func updateNSView(_ v: RecorderView, context: Context) { v.shortcut = shortcut; v.needsDisplay = true }

    final class RecorderView: NSView {
        var shortcut = KeyShortcut(keyCode: 49, modifiers: 0) { didSet { needsDisplay = true } }
        var onChange: ((KeyShortcut) -> Void)?
        var recording = false { didSet { needsDisplay = true } }
        override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 24) }
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); recording = true }
        override func resignFirstResponder() -> Bool { recording = false; return true }
        override func keyDown(with e: NSEvent) {
            guard recording else { super.keyDown(with: e); return }
            if e.keyCode == UInt16(kVK_Escape) && e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { recording = false; window?.makeFirstResponder(nil); return }
            var f = CGEventFlags()
            let m = e.modifierFlags
            if m.contains(.command) { f.insert(.maskCommand) }
            if m.contains(.shift) { f.insert(.maskShift) }
            if m.contains(.option) { f.insert(.maskAlternate) }
            if m.contains(.control) { f.insert(.maskControl) }
            if m.contains(.function) && KeyNames.special[e.keyCode] == nil { f.insert(.maskSecondaryFn) }
            shortcut = KeyShortcut(keyCode: e.keyCode, modifiers: f.rawValue)
            onChange?(shortcut)
            recording = false; window?.makeFirstResponder(nil)
        }
        override func flagsChanged(with e: NSEvent) { needsDisplay = true }
        override func draw(_ r: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill(); path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke(); path.stroke()
            let s = recording ? "Press keys… (esc to cancel)" : KeyNames.name(for: shortcut)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }
}

// MARK: Options

struct OptionsTab: View {
    @ObservedObject var state: AppState
    private var t: Binding<Tuning> { Binding(get: { state.config.tuning }, set: { state.config.tuning = $0; state.save() }) }
    var body: some View {
        Form {
            Section(header: Text("General").font(.headline)) {
                Toggle("Launch at login", isOn: Binding(get: { state.config.launchAtLogin }, set: { state.config.launchAtLogin = $0; state.save() }))
                Toggle("Move the pointer to the finger on touch", isOn: t.moveCursorOnTouch)
                Toggle("Natural scrolling (content follows fingers)", isOn: t.naturalScrolling)
                Toggle("Momentum scrolling", isOn: t.momentumScrolling)
                slider("Scroll speed", t.scrollSpeed, 0.25...4, "×%.2f")
            }
            Section(header: Text("Timing").font(.headline)) {
                slider("Tap max duration", t.tapMaxDuration, 0.1...0.6, "%.2f s")
                slider("Double tap interval", t.doubleTapInterval, 0.15...0.8, "%.2f s")
                slider("Long press duration", t.longPressDuration, 0.3...1.5, "%.2f s")
                slider("Extra-finger wait", t.multiFingerWindow, 0...0.2, "%.2f s")
                slider("Swipe max duration", t.swipeMaxDuration, 0.2...1.5, "%.2f s")
            }
            Section(header: Text("Distances (points)").font(.headline)) {
                slider("Tap movement tolerance", t.tapMoveTolerance, 2...40, "%.0f")
                slider("Drag threshold", t.dragThreshold, 2...40, "%.0f")
                slider("Swipe min distance", t.swipeMinDistance, 20...300, "%.0f")
                slider("Edge margin", t.edgeMargin, 2...60, "%.0f")
                slider("Pinch step (fraction)", t.pinchStep, 0.03...0.4, "%.2f")
                slider("Rotate step (degrees)", t.rotateStep, 5...90, "%.0f°")
            }
            Section {
                Button("Reset all options") { state.config.tuning = Tuning(); state.save() }
                Text("Config file: \(Config.url.path)").font(.caption).foregroundColor(.secondary)
            }
        }
    }
    private func slider(_ label: String, _ b: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String) -> some View {
        HStack { Text(label).frame(width: 200, alignment: .leading); Slider(value: b, in: range); Text(String(format: fmt, b.wrappedValue)).frame(width: 64, alignment: .trailing).font(.system(size: 12, design: .monospaced)) }
    }
}

// MARK: grandMA3

struct MA3Tab: View {
    @ObservedObject var state: AppState
    @State private var installMsg = ""
    @State private var alive = false
    @State private var running = false
    @State private var windows: [MA3Bridge.OnPCWindow] = []
    @State private var timer: Timer? = nil
    private var m: Binding<MA3Config> { Binding(get: { state.config.ma3 }, set: { state.config.ma3 = $0; state.save() }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("grandMA3 onPC multi-touch").font(.headline)
            Text("macOS has one pointer, so plain cursor emulation can only press one thing at a time. Touches that land on a grandMA3 onPC window are instead sent into onPC through its Lua Touch() API with their real finger ids, so several executors or faders can be operated at once. Everything outside onPC still uses the normal cursor gestures.").font(.system(size: 12)).foregroundColor(.secondary)
            Toggle("Route touches on onPC windows into grandMA3", isOn: m.enabled)
            GroupBox("Setup (once)") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("1.").bold(); Button("Install plugin into gma3 library") { installMsg = MA3Bridge.installPlugin() }; Text(installMsg).font(.caption).foregroundColor(.secondary) }
                    Text("2. In onPC: open the Plugins pool, edit an empty slot, Import → MacTouch.").font(.system(size: 12))
                    Text("3. Run it (tap the pool item, or type  Plugin \"MacTouch\"  in the command line). Add that to a startup macro so it runs with every show.").font(.system(size: 12))
                }.padding(4)
            }
            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 4) {
                    row("onPC running", running)
                    row("MacTouch plugin running inside onPC", alive)
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, w in
                        Text("window: \(w.title.isEmpty ? "(untitled)" : w.title) → MA3 display \(w.displayIndex.map(String.init) ?? "? (fallback \(state.config.ma3.fallbackDisplayIndex))")  at \(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))×\(Int(w.frame.height))").font(.caption)
                    }
                }.padding(4)
            }
            HStack {
                Text("Fallback MA3 display index").frame(width: 200, alignment: .leading)
                Stepper(value: m.fallbackDisplayIndex, in: 1...8) { Text("\(state.config.ma3.fallbackDisplayIndex)") }
            }
            HStack {
                Text("Pixel scale (0 = automatic)").frame(width: 200, alignment: .leading)
                TextField("", value: m.pixelScale, formatter: NumberFormatter()).frame(width: 60)
                Text("X offset").padding(.leading); TextField("", value: m.offsetX, formatter: NumberFormatter()).frame(width: 60)
                Text("Y offset").padding(.leading); TextField("", value: m.offsetY, formatter: NumberFormatter()).frame(width: 60)
            }
            Text("Events file: \(MA3Bridge.eventsURL.path)").font(.caption).foregroundColor(.secondary)
            Spacer()
        }
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                alive = state.engine.ma3.pluginAlive; running = state.engine.ma3.onPCRunning
                state.engine.ma3.refreshWindows(force: true); windows = state.engine.ma3.windows
            }
        }
        .onDisappear { timer?.invalidate() }
    }
    private func row(_ t: String, _ ok: Bool) -> some View {
        HStack { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundColor(ok ? .green : .secondary); Text(t).font(.system(size: 12)) }
    }
}

// MARK: Status

struct StatusTab: View {
    @ObservedObject var state: AppState
    @State private var timer: Timer? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.headline)
            Text("MacTouch reads the touchscreen through Input Monitoring and injects clicks, scrolls and key presses through Accessibility. Both are required; nothing leaves your Mac.").font(.system(size: 12)).foregroundColor(.secondary)
            permRow("Input Monitoring", state.inputMonitoring, "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            permRow("Accessibility", state.accessibility, "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            Button("Request permissions again") { state.requestPermissions() }
            Divider()
            Text("Driver").font(.headline)
            let _ = state.tick
            Text(state.engine.running ? "Running (\(state.engine.pipelines.count) touchscreen(s))" : "Stopped: waiting for Input Monitoring").font(.system(size: 12))
            Text("Log: \(Log.url.path)").font(.caption).foregroundColor(.secondary)
            HStack { Button("Open log") { NSWorkspace.shared.open(Log.url) }; Button("Open config folder") { NSWorkspace.shared.open(Config.url.deletingLastPathComponent()) } }
            Spacer()
        }
        .onAppear { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in state.refreshPermissions() } }
        .onDisappear { timer?.invalidate() }
    }
    private func permRow(_ name: String, _ ok: Bool, _ url: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundColor(ok ? .green : .red)
            Text(name).frame(width: 150, alignment: .leading)
            if !ok { Button("Open System Settings") { NSWorkspace.shared.open(URL(string: url)!) } }
            Text(ok ? "granted" : "not granted — enable MacTouch in the list, then come back").font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: overlays

enum IdentifyOverlay {
    static var windows: [NSWindow] = []
    static func show(_ d: DisplayInfo) {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == (d.mirrorOf == kCGNullDirectDisplay ? d.id : d.mirrorOf) }) else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true
        w.contentView = NSHostingView(rootView: ZStack { Color.black.opacity(0.5); Text(d.name).font(.system(size: 72, weight: .bold)).foregroundColor(.white) })
        w.orderFrontRegardless()
        windows.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { w.orderOut(nil); windows.removeAll { $0 == w } }
    }
}

/// Four-corner calibration: shows targets on the mapped display and records raw panel coordinates.
enum CalibrationOverlay {
    static var window: NSWindow?
    static func run(state: AppState, pipeline: TouchPipeline, done: @escaping () -> Void) {
        guard let d = pipeline.display, let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == (d.mirrorOf == kCGNullDirectDisplay ? d.id : d.mirrorOf) }) else { done(); return }
        let model = CalModel()
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver; w.isOpaque = true; w.backgroundColor = .black; w.ignoresMouseEvents = true
        w.contentView = NSHostingView(rootView: CalView(model: model))
        w.orderFrontRegardless(); window = w
        // Suspend gesture output while calibrating.
        var raw: [CGPoint] = []
        let inset = 0.08
        let targets = [CGPoint(x: inset, y: inset), CGPoint(x: 1 - inset, y: inset), CGPoint(x: 1 - inset, y: 1 - inset), CGPoint(x: inset, y: 1 - inset)]
        model.target = targets[0]
        var saved = state.config.devices[pipeline.device.key] ?? DeviceConfig()
        let wasEnabled = saved.enabled
        saved.enabled = false; state.config.devices[pipeline.device.key] = saved; state.engine.update(config: state.config)
        var touching = false
        var sample: CGPoint = .zero
        state.engine.rawFrameObserver = { p, f in
            guard p === pipeline else { return }
            if let c = f.contacts.first { touching = true; sample = CGPoint(x: c.x, y: c.y) }
            else if touching {
                touching = false
                raw.append(sample)
                DispatchQueue.main.async {
                    if raw.count < 4 { model.target = targets[raw.count]; model.step = raw.count }
                    else {
                        state.engine.rawFrameObserver = nil
                        // Solve: raw = a + b * target for x and y independently using the 4 samples (least squares).
                        func fit(_ t: [Double], _ r: [Double]) -> (Double, Double) {
                            let n = Double(t.count), st = t.reduce(0, +), sr = r.reduce(0, +)
                            let stt = zip(t, t).map(*).reduce(0, +), str = zip(t, r).map(*).reduce(0, +)
                            let b = (n * str - st * sr) / max(n * stt - st * st, 1e-9)
                            return ((sr - b * st) / n, b)
                        }
                        var c = state.config.devices[pipeline.device.key] ?? DeviceConfig()
                        // undo current flips/swap so samples are in the same orientation the mapper expects after flips
                        var pts = raw
                        if c.swapXY { pts = pts.map { CGPoint(x: $0.y, y: $0.x) } }
                        if c.invertX { pts = pts.map { CGPoint(x: 1 - $0.x, y: $0.y) } }
                        if c.invertY { pts = pts.map { CGPoint(x: $0.x, y: 1 - $0.y) } }
                        // map display-space targets back to panel space for the display rotation
                        let tp = targets.map { t -> CGPoint in
                            switch d.rotation { case 90: return CGPoint(x: t.y, y: 1 - t.x); case 180: return CGPoint(x: 1 - t.x, y: 1 - t.y); case 270: return CGPoint(x: 1 - t.y, y: t.x); default: return t }
                        }
                        let (ax, bx) = fit(tp.map { $0.x }, pts.map { $0.x })
                        let (ay, by) = fit(tp.map { $0.y }, pts.map { $0.y })
                        if abs(bx) > 0.3 && abs(by) > 0.3 {
                            c.calMinX = ax; c.calMaxX = ax + bx; c.calMinY = ay; c.calMaxY = ay + by
                        } else { Log.w("calibration rejected (degenerate fit)") }
                        c.enabled = wasEnabled
                        state.config.devices[pipeline.device.key] = c
                        state.save()
                        w.orderOut(nil); window = nil
                        done()
                    }
                }
            }
        }
        // Escape hatch: auto-cancel after 60 s
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if window === w {
                state.engine.rawFrameObserver = nil
                var c = state.config.devices[pipeline.device.key] ?? DeviceConfig(); c.enabled = wasEnabled
                state.config.devices[pipeline.device.key] = c; state.save()
                w.orderOut(nil); window = nil; done()
            }
        }
    }
    final class CalModel: ObservableObject { @Published var target = CGPoint(x: 0.08, y: 0.08); @Published var step = 0 }
    struct CalView: View {
        @ObservedObject var model: CalModel
        var body: some View {
            GeometryReader { g in
                ZStack {
                    Color.black
                    Text("Tap the target (\(model.step + 1) of 4)").foregroundColor(.white).font(.system(size: 36))
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 3).frame(width: 60, height: 60)
                        Circle().fill(Color.red).frame(width: 12, height: 12)
                    }.position(x: model.target.x * g.size.width, y: model.target.y * g.size.height)
                }
            }
        }
    }
}
