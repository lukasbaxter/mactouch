import Foundation

/// Every gesture the recognizer can emit. Raw values are the stable keys used in config.json.
enum Gesture: String, Codable, CaseIterable, Identifiable {
    case tap1, doubleTap1, longPress1, drag1
    case tap2, longPress2, scroll2, pinchIn, pinchOut, rotateCW, rotateCCW
    case tap3, swipe3Left, swipe3Right, swipe3Up, swipe3Down
    case tap4, swipe4Left, swipe4Right, swipe4Up, swipe4Down
    case tap5
    case edgeLeft, edgeRight, edgeTop, edgeBottom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tap1: return "Tap"
        case .doubleTap1: return "Double tap"
        case .longPress1: return "Long press"
        case .drag1: return "Drag (one finger)"
        case .tap2: return "Two-finger tap"
        case .longPress2: return "Two-finger long press"
        case .scroll2: return "Two-finger drag"
        case .pinchIn: return "Pinch in (each step)"
        case .pinchOut: return "Pinch out (each step)"
        case .rotateCW: return "Rotate clockwise (each step)"
        case .rotateCCW: return "Rotate counter-clockwise (each step)"
        case .tap3: return "Three-finger tap"
        case .swipe3Left: return "Three-finger swipe left"
        case .swipe3Right: return "Three-finger swipe right"
        case .swipe3Up: return "Three-finger swipe up"
        case .swipe3Down: return "Three-finger swipe down"
        case .tap4: return "Four-finger tap"
        case .swipe4Left: return "Four-finger swipe left"
        case .swipe4Right: return "Four-finger swipe right"
        case .swipe4Up: return "Four-finger swipe up"
        case .swipe4Down: return "Four-finger swipe down"
        case .tap5: return "Five-finger tap"
        case .edgeLeft: return "Swipe in from left edge"
        case .edgeRight: return "Swipe in from right edge"
        case .edgeTop: return "Swipe in from top edge"
        case .edgeBottom: return "Swipe in from bottom edge"
        }
    }
    var section: String {
        switch self {
        case .tap1, .doubleTap1, .longPress1, .drag1: return "One finger"
        case .tap2, .longPress2, .scroll2, .pinchIn, .pinchOut, .rotateCW, .rotateCCW: return "Two fingers"
        case .tap3, .swipe3Left, .swipe3Right, .swipe3Up, .swipe3Down: return "Three fingers"
        case .tap4, .swipe4Left, .swipe4Right, .swipe4Up, .swipe4Down: return "Four fingers"
        case .tap5: return "Five fingers"
        case .edgeLeft, .edgeRight, .edgeTop, .edgeBottom: return "Edges"
        }
    }
    /// Continuous gestures carry began/changed/ended phases.
    var isContinuous: Bool { self == .drag1 || self == .scroll2 }
}

enum Builtin: String, Codable, CaseIterable, Identifiable {
    case leftClick, rightClick, middleClick, doubleClick
    case leftDrag, rightDrag, middleDrag, scroll, horizontalScroll
    case zoomIn, zoomOut, zoomReset
    case missionControl, appExpose, showDesktop, launchpad, spaceLeft, spaceRight, notificationCenter
    case back, forward, copy, paste, cut, undo, redo, selectAll, closeWindow, quitApp, spotlight, screenshot
    case nextTab, previousTab, newTab, reopenTab, fullscreen, minimize, hideApp, appSwitcher, lockScreen
    case volumeUp, volumeDown, mute, playPause, brightnessUp, brightnessDown, keyboardViewer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .leftClick: return "Left click"
        case .rightClick: return "Right click"
        case .middleClick: return "Middle click"
        case .doubleClick: return "Double click"
        case .leftDrag: return "Drag with left button"
        case .rightDrag: return "Drag with right button"
        case .middleDrag: return "Drag with middle button"
        case .scroll: return "Scroll"
        case .horizontalScroll: return "Scroll (horizontal only)"
        case .zoomIn: return "Zoom in (⌘ +)"
        case .zoomOut: return "Zoom out (⌘ −)"
        case .zoomReset: return "Zoom reset (⌘ 0)"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad / Apps"
        case .spaceLeft: return "Move to Space on the left"
        case .spaceRight: return "Move to Space on the right"
        case .notificationCenter: return "Notification Center"
        case .back: return "Back (⌘ [)"
        case .forward: return "Forward (⌘ ])"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .cut: return "Cut"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .selectAll: return "Select all"
        case .closeWindow: return "Close window (⌘ W)"
        case .quitApp: return "Quit app (⌘ Q)"
        case .spotlight: return "Spotlight"
        case .screenshot: return "Screenshot tool"
        case .nextTab: return "Next tab"
        case .previousTab: return "Previous tab"
        case .newTab: return "New tab"
        case .reopenTab: return "Reopen closed tab"
        case .fullscreen: return "Toggle full screen"
        case .minimize: return "Minimize window"
        case .hideApp: return "Hide app"
        case .appSwitcher: return "App switcher (next app)"
        case .lockScreen: return "Lock screen"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute"
        case .playPause: return "Play / pause"
        case .brightnessUp: return "Brightness up"
        case .brightnessDown: return "Brightness down"
        case .keyboardViewer: return "Toggle on-screen keyboard"
        }
    }
    /// Only meaningful for continuous gestures (drag / two-finger drag).
    var isContinuous: Bool { [.leftDrag, .rightDrag, .middleDrag, .scroll, .horizontalScroll].contains(self) }
}

struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64     // CGEventFlags raw value (maskCommand etc.)
}

/// What to do when a gesture fires.
enum Action: Codable, Equatable {
    case none
    case builtin(Builtin)
    case shortcut(KeyShortcut)
    case typeText(String)
    case mouseButton(Int)       // 0 left, 1 right, 2 middle, 3..31 extra
    case shell(String)
    case openApp(String)        // name or path
    case openURL(String)

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case none, builtin, shortcut, typeText, mouseButton, shell, openApp, openURL
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "Nothing"
            case .builtin: return "Built-in action"
            case .shortcut: return "Keyboard shortcut"
            case .typeText: return "Type text"
            case .mouseButton: return "Mouse button"
            case .shell: return "Shell command"
            case .openApp: return "Open app"
            case .openURL: return "Open URL / file"
            }
        }
    }
    var kind: Kind {
        switch self {
        case .none: return .none
        case .builtin: return .builtin
        case .shortcut: return .shortcut
        case .typeText: return .typeText
        case .mouseButton: return .mouseButton
        case .shell: return .shell
        case .openApp: return .openApp
        case .openURL: return .openURL
        }
    }
    var isContinuous: Bool {
        if case .builtin(let b) = self { return b.isContinuous }
        if case .mouseButton = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey { case kind, builtin, shortcut, text, button, command, app, url }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .none: self = .none
        case .builtin: self = .builtin(try c.decode(Builtin.self, forKey: .builtin))
        case .shortcut: self = .shortcut(try c.decode(KeyShortcut.self, forKey: .shortcut))
        case .typeText: self = .typeText(try c.decode(String.self, forKey: .text))
        case .mouseButton: self = .mouseButton(try c.decode(Int.self, forKey: .button))
        case .shell: self = .shell(try c.decode(String.self, forKey: .command))
        case .openApp: self = .openApp(try c.decode(String.self, forKey: .app))
        case .openURL: self = .openURL(try c.decode(String.self, forKey: .url))
        }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .none: break
        case .builtin(let b): try c.encode(b, forKey: .builtin)
        case .shortcut(let s): try c.encode(s, forKey: .shortcut)
        case .typeText(let t): try c.encode(t, forKey: .text)
        case .mouseButton(let n): try c.encode(n, forKey: .button)
        case .shell(let s): try c.encode(s, forKey: .command)
        case .openApp(let a): try c.encode(a, forKey: .app)
        case .openURL(let u): try c.encode(u, forKey: .url)
        }
    }
}

struct DeviceConfig: Codable, Equatable {
    var displayName: String? = nil     // localized display name, e.g. "DELL P2424HT"
    var displayVendor: UInt32? = nil
    var displayModel: UInt32? = nil
    var displaySerial: UInt32? = nil
    var swapXY = false
    var invertX = false
    var invertY = false
    var enabled = true
    /// Calibration: normalized panel coords that correspond to the display's corners.
    var calMinX = 0.0, calMinY = 0.0, calMaxX = 1.0, calMaxY = 1.0
}

struct Tuning: Codable, Equatable {
    var tapMaxDuration = 0.25          // s
    var tapMoveTolerance = 12.0        // points
    var doubleTapInterval = 0.35       // s
    var longPressDuration = 0.6        // s
    var dragThreshold = 8.0            // points before a touch becomes a drag
    var multiFingerWindow = 0.08       // s to wait for additional fingers before committing a one-finger press
    var swipeMinDistance = 60.0        // points
    var swipeMaxDuration = 0.6         // s
    var edgeMargin = 14.0              // points from the display edge
    var scrollSpeed = 1.0
    var naturalScrolling = true
    var momentumScrolling = true
    var pinchStep = 0.12               // fraction of initial distance per zoom step
    var rotateStep = 20.0              // degrees per rotate step
    var moveCursorOnTouch = true
    var showTouchFeedback = false
}

struct Config: Codable, Equatable {
    var version = 1
    var devices: [String: DeviceConfig] = [:]        // keyed by TouchDevice.key
    var gestures: [String: Action] = Config.defaultGestures
    var tuning = Tuning()
    var launchAtLogin = true
    var ma3 = MA3Config()

    func action(for g: Gesture) -> Action { gestures[g.rawValue] ?? .none }

    static let defaultGestures: [String: Action] = [
        Gesture.tap1.rawValue: .builtin(.leftClick),
        Gesture.doubleTap1.rawValue: .builtin(.doubleClick),
        Gesture.longPress1.rawValue: .builtin(.rightClick),
        Gesture.drag1.rawValue: .builtin(.leftDrag),
        Gesture.tap2.rawValue: .builtin(.rightClick),
        Gesture.longPress2.rawValue: .none,
        Gesture.scroll2.rawValue: .builtin(.scroll),
        Gesture.pinchIn.rawValue: .builtin(.zoomOut),
        Gesture.pinchOut.rawValue: .builtin(.zoomIn),
        Gesture.rotateCW.rawValue: .none,
        Gesture.rotateCCW.rawValue: .none,
        Gesture.tap3.rawValue: .builtin(.middleClick),
        Gesture.swipe3Left.rawValue: .builtin(.spaceRight),
        Gesture.swipe3Right.rawValue: .builtin(.spaceLeft),
        Gesture.swipe3Up.rawValue: .builtin(.missionControl),
        Gesture.swipe3Down.rawValue: .builtin(.appExpose),
        Gesture.tap4.rawValue: .none,
        Gesture.swipe4Left.rawValue: .builtin(.nextTab),
        Gesture.swipe4Right.rawValue: .builtin(.previousTab),
        Gesture.swipe4Up.rawValue: .builtin(.showDesktop),
        Gesture.swipe4Down.rawValue: .builtin(.launchpad),
        Gesture.tap5.rawValue: .builtin(.keyboardViewer),
        Gesture.edgeLeft.rawValue: .builtin(.back),
        Gesture.edgeRight.rawValue: .builtin(.notificationCenter),
        Gesture.edgeTop.rawValue: .none,
        Gesture.edgeBottom.rawValue: .none,
    ]

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacTouch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            var c = try JSONDecoder().decode(Config.self, from: data)
            // Fill gestures added in newer versions with their defaults.
            for (k, v) in defaultGestures where c.gestures[k] == nil { c.gestures[k] = v }
            return c
        } catch {
            Log.w("config.json unreadable (\(error)); using defaults")
            return Config()
        }
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: Config.url, options: .atomic) }
    }
}

enum Log {
    static var verbose = false
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs", isDirectory: true)
        return dir.appendingPathComponent("MacTouch.log")
    }()
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
    private static let q = DispatchQueue(label: "mactouch.log")
    static func i(_ s: String) { write("I", s) }
    static func w(_ s: String) { write("W", s) }
    static func d(_ s: String) { if verbose { write("D", s) } }
    private static func write(_ lvl: String, _ s: String) {
        let line = "\(fmt.string(from: Date())) [\(lvl)] \(s)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        q.async {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
            else { try? line.data(using: .utf8)!.write(to: url) }
        }
    }
}
