import Foundation
import AppKit
import Carbon.HIToolbox

/// Executes Actions by synthesizing HID-level events or running commands.
final class ActionRunner {
    var tuning: Tuning
    private let source = CGEventSource(stateID: .hidSystemState)
    private var momentumTimer: DispatchSourceTimer?
    private var momentumVelocity = CGVector.zero
    private var momentumPoint = CGPoint.zero
    private var dragButton: Int? = nil
    private var dragPoint = CGPoint.zero
    private var horizontalOnly = false

    init(tuning: Tuning) { self.tuning = tuning }

    // MARK: pointer

    func movePointer(to p: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
    }

    // MARK: discrete

    func perform(_ a: Action, at p: CGPoint, clickCount: Int) {
        switch a {
        case .none: break
        case .builtin(let b): builtin(b, at: p, clickCount: clickCount)
        case .shortcut(let s): shortcut(s.keyCode, flags: CGEventFlags(rawValue: s.modifiers))
        case .typeText(let t): typeText(t)
        case .mouseButton(let n): click(button: n, at: p, clickCount: clickCount)
        case .shell(let cmd): shell(cmd)
        case .openApp(let app): openApp(app)
        case .openURL(let u): openURL(u)
        }
    }

    private func builtin(_ b: Builtin, at p: CGPoint, clickCount: Int) {
        switch b {
        case .leftClick: click(button: 0, at: p, clickCount: clickCount)
        case .rightClick: click(button: 1, at: p, clickCount: 1)
        case .middleClick: click(button: 2, at: p, clickCount: 1)
        case .doubleClick: click(button: 0, at: p, clickCount: 2)
        case .leftDrag, .rightDrag, .middleDrag, .scroll, .horizontalScroll: break   // continuous only
        case .zoomIn: shortcut(UInt16(kVK_ANSI_Equal), flags: .maskCommand)
        case .zoomOut: shortcut(UInt16(kVK_ANSI_Minus), flags: .maskCommand)
        case .zoomReset: shortcut(UInt16(kVK_ANSI_0), flags: .maskCommand)
        case .missionControl: shortcut(UInt16(kVK_UpArrow), flags: .maskControl)
        case .appExpose: shortcut(UInt16(kVK_DownArrow), flags: .maskControl)
        case .showDesktop: shortcut(UInt16(kVK_F11), flags: [])
        case .launchpad: shortcut(131, flags: [])
        case .spaceLeft: shortcut(UInt16(kVK_LeftArrow), flags: .maskControl)
        case .spaceRight: shortcut(UInt16(kVK_RightArrow), flags: .maskControl)
        case .notificationCenter: notificationCenter()
        case .back: shortcut(UInt16(kVK_ANSI_LeftBracket), flags: .maskCommand)
        case .forward: shortcut(UInt16(kVK_ANSI_RightBracket), flags: .maskCommand)
        case .copy: shortcut(UInt16(kVK_ANSI_C), flags: .maskCommand)
        case .paste: shortcut(UInt16(kVK_ANSI_V), flags: .maskCommand)
        case .cut: shortcut(UInt16(kVK_ANSI_X), flags: .maskCommand)
        case .undo: shortcut(UInt16(kVK_ANSI_Z), flags: .maskCommand)
        case .redo: shortcut(UInt16(kVK_ANSI_Z), flags: [.maskCommand, .maskShift])
        case .selectAll: shortcut(UInt16(kVK_ANSI_A), flags: .maskCommand)
        case .closeWindow: shortcut(UInt16(kVK_ANSI_W), flags: .maskCommand)
        case .quitApp: shortcut(UInt16(kVK_ANSI_Q), flags: .maskCommand)
        case .spotlight: shortcut(UInt16(kVK_Space), flags: .maskCommand)
        case .screenshot: shortcut(UInt16(kVK_ANSI_5), flags: [.maskCommand, .maskShift])
        case .nextTab: shortcut(UInt16(kVK_ANSI_RightBracket), flags: [.maskCommand, .maskShift])
        case .previousTab: shortcut(UInt16(kVK_ANSI_LeftBracket), flags: [.maskCommand, .maskShift])
        case .newTab: shortcut(UInt16(kVK_ANSI_T), flags: .maskCommand)
        case .reopenTab: shortcut(UInt16(kVK_ANSI_T), flags: [.maskCommand, .maskShift])
        case .fullscreen: shortcut(UInt16(kVK_ANSI_F), flags: [.maskCommand, .maskControl])
        case .minimize: shortcut(UInt16(kVK_ANSI_M), flags: .maskCommand)
        case .hideApp: shortcut(UInt16(kVK_ANSI_H), flags: .maskCommand)
        case .appSwitcher: shortcut(UInt16(kVK_Tab), flags: .maskCommand)
        case .lockScreen: shortcut(UInt16(kVK_ANSI_Q), flags: [.maskCommand, .maskControl])
        case .volumeUp: mediaKey(NX_KEYTYPE_SOUND_UP)
        case .volumeDown: mediaKey(NX_KEYTYPE_SOUND_DOWN)
        case .mute: mediaKey(NX_KEYTYPE_MUTE)
        case .playPause: mediaKey(NX_KEYTYPE_PLAY)
        case .brightnessUp: mediaKey(NX_KEYTYPE_BRIGHTNESS_UP)
        case .brightnessDown: mediaKey(NX_KEYTYPE_BRIGHTNESS_DOWN)
        case .keyboardViewer: toggleAccessibilityKeyboard()
        }
    }

    // MARK: continuous

    func begin(_ a: Action, at p: CGPoint) {
        stopMomentum()
        switch a {
        case .builtin(.leftDrag): startDrag(button: 0, at: p)
        case .builtin(.rightDrag): startDrag(button: 1, at: p)
        case .builtin(.middleDrag): startDrag(button: 2, at: p)
        case .mouseButton(let n): startDrag(button: n, at: p)
        case .builtin(.scroll): horizontalOnly = false; scroll(dx: 0, dy: 0, at: p, phase: 1)
        case .builtin(.horizontalScroll): horizontalOnly = true; scroll(dx: 0, dy: 0, at: p, phase: 1)
        default: perform(a, at: p, clickCount: 1)   // discrete action mapped to a continuous gesture: fire once
        }
    }

    func change(_ a: Action, to p: CGPoint, delta: CGVector) {
        switch a {
        case .builtin(.leftDrag), .builtin(.rightDrag), .builtin(.middleDrag), .mouseButton: drag(to: p)
        case .builtin(.scroll), .builtin(.horizontalScroll): scroll(dx: delta.dx, dy: delta.dy, at: p, phase: 2)
        default: break
        }
    }

    func end(_ a: Action, at p: CGPoint, velocity: CGVector) {
        switch a {
        case .builtin(.leftDrag), .builtin(.rightDrag), .builtin(.middleDrag), .mouseButton: endDrag(at: p)
        case .builtin(.scroll), .builtin(.horizontalScroll):
            scroll(dx: 0, dy: 0, at: p, phase: 4)
            if tuning.momentumScrolling { startMomentum(velocity, at: p) }
        default: break
        }
    }

    // MARK: mouse primitives

    private func mouseTypes(button: Int) -> (CGEventType, CGEventType, CGEventType, CGMouseButton) {
        switch button {
        case 0: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
        case 1: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
        default: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, CGMouseButton(rawValue: UInt32(button)) ?? .center)
        }
    }

    func click(button: Int, at p: CGPoint, clickCount: Int) {
        let (down, up, _, btn) = mouseTypes(button: button)
        movePointer(to: p)
        let d = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: p, mouseButton: btn)
        let u = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: p, mouseButton: btn)
        d?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        u?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        if button > 2 { d?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)); u?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
        post(d); post(u)
    }

    private func startDrag(button: Int, at p: CGPoint) {
        if dragButton != nil { endDrag(at: dragPoint) }
        dragButton = button; dragPoint = p
        let (down, _, _, btn) = mouseTypes(button: button)
        movePointer(to: p)
        let d = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: p, mouseButton: btn)
        d?.setIntegerValueField(.mouseEventClickState, value: 1)
        if button > 2 { d?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
        post(d)
    }

    private func drag(to p: CGPoint) {
        guard let b = dragButton else { return }
        dragPoint = p
        let (_, _, dragged, btn) = mouseTypes(button: b)
        let e = CGEvent(mouseEventSource: source, mouseType: dragged, mouseCursorPosition: p, mouseButton: btn)
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
        if b > 2 { e?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b)) }
        post(e)
    }

    private func endDrag(at p: CGPoint) {
        guard let b = dragButton else { return }
        dragButton = nil
        let (_, up, _, btn) = mouseTypes(button: b)
        let e = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: p, mouseButton: btn)
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
        if b > 2 { e?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b)) }
        post(e)
    }

    /// Releases any held button (used when a device disappears mid-drag).
    func releaseAll() { endDrag(at: dragPoint); stopMomentum() }

    // MARK: scroll

    private var scrollRemainder = CGVector.zero

    private func scroll(dx: CGFloat, dy: CGFloat, at p: CGPoint, phase: Int64, momentum: Int64 = 0) {
        let sign: CGFloat = tuning.naturalScrolling ? 1 : -1
        if phase == 1 { scrollRemainder = .zero }
        // Accumulate sub-pixel movement so slow scrolling is not truncated away.
        let fx = dx * sign * CGFloat(tuning.scrollSpeed) + scrollRemainder.dx
        let fy = (horizontalOnly ? 0 : dy * sign * CGFloat(tuning.scrollSpeed)) + scrollRemainder.dy
        let sx = Int32(fx.rounded(.towardZero)), sy = Int32(fy.rounded(.towardZero))
        scrollRemainder = CGVector(dx: fx - CGFloat(sx), dy: fy - CGFloat(sy))
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: sy, wheel2: sx, wheel3: 0) else { return }
        e.location = p
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: momentum == 0 ? phase : 0)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        post(e)
    }

    private func startMomentum(_ v: CGVector, at p: CGPoint) {
        let speed = hypot(v.dx, v.dy)
        guard speed > 150 else { return }
        momentumVelocity = v; momentumPoint = p
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.016, repeating: 0.016)
        var first = true
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.momentumVelocity = CGVector(dx: self.momentumVelocity.dx * 0.95, dy: self.momentumVelocity.dy * 0.95)
            let dx = self.momentumVelocity.dx * 0.016, dy = self.momentumVelocity.dy * 0.016
            if hypot(dx, dy) < 0.5 {
                self.scroll(dx: 0, dy: 0, at: self.momentumPoint, phase: 0, momentum: 3)
                self.stopMomentum(); return
            }
            self.scroll(dx: dx, dy: dy, at: self.momentumPoint, phase: 0, momentum: first ? 1 : 2)
            first = false
        }
        momentumTimer = t
        t.resume()
    }

    private func stopMomentum() {
        momentumTimer?.cancel(); momentumTimer = nil
    }

    // MARK: keyboard

    func shortcut(_ keyCode: UInt16, flags: CGEventFlags) {
        let d = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let u = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        d?.flags = flags; u?.flags = flags
        post(d); post(u)
    }

    func typeText(_ s: String) {
        for chunk in s.unicodeScalars.map({ $0 }).chunked(into: 20) {
            var u16 = Array(String(String.UnicodeScalarView(chunk)).utf16)
            let d = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let u = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            d?.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: &u16)
            u?.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: &u16)
            post(d); post(u)
        }
    }

    private func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags: NSEvent.ModifierFlags = down ? NSEvent.ModifierFlags(rawValue: 0xa00) : NSEvent.ModifierFlags(rawValue: 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1) {
                ev.cgEvent?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: misc

    private func notificationCenter() {
        // Default macOS has no key shortcut for Notification Center; click the clock via System Events.
        let script = "tell application \"System Events\" to tell process \"ControlCenter\" to click (first menu bar item of menu bar 1 whose description contains \"Clock\" or description contains \"clock\")"
        run("/usr/bin/osascript", ["-e", script])
    }

    private func toggleAccessibilityKeyboard() {
        // Flip the Accessibility Keyboard preference, then poke the panel server to apply it.
        let script = """
        tell application "System Events"
          set cur to (do shell script "defaults read com.apple.Accessibility AccessibilityKeyboardEnabled 2>/dev/null || echo 0")
          if cur is "1" then
            do shell script "defaults write com.apple.Accessibility AccessibilityKeyboardEnabled -bool false"
          else
            do shell script "defaults write com.apple.Accessibility AccessibilityKeyboardEnabled -bool true"
          end if
        end tell
        """
        run("/usr/bin/osascript", ["-e", script])
    }

    func shell(_ cmd: String) { run("/bin/zsh", ["-lc", cmd]) }

    private func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { Log.w("run \(path) failed: \(error)") }
    }

    private func openApp(_ app: String) {
        if app.hasPrefix("/") { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: .init()) }
        else { run("/usr/bin/open", ["-a", app]) }
    }

    private func openURL(_ s: String) {
        if let u = URL(string: s), u.scheme != nil { NSWorkspace.shared.open(u) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: (s as NSString).expandingTildeInPath)) }
    }

    private func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// Human-readable names for key shortcuts.
enum KeyNames {
    static let special: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦", 114: "Help", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        131: "Launchpad", 160: "Mission Control", 130: "Dashboard", 57: "⇪", 63: "fn",
    ]
    static func name(for s: KeyShortcut) -> String {
        let f = CGEventFlags(rawValue: s.modifiers)
        var out = ""
        if f.contains(.maskControl) { out += "⌃" }
        if f.contains(.maskAlternate) { out += "⌥" }
        if f.contains(.maskShift) { out += "⇧" }
        if f.contains(.maskCommand) { out += "⌘" }
        if f.contains(.maskSecondaryFn) { out += "fn " }
        out += special[s.keyCode] ?? keyString(s.keyCode)
        return out
    }
    static func keyString(_ keyCode: UInt16) -> String {
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "key \(keyCode)" }
        let layout = unsafeBitCast(CFDataGetBytePtr(unsafeBitCast(data, to: CFData.self)), to: UnsafePointer<UCKeyboardLayout>.self)
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let err = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        if err == noErr, len > 0 { return String(utf16CodeUnits: chars, count: len).uppercased() }
        return "key \(keyCode)"
    }
}
