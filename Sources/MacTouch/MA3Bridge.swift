import Foundation
import AppKit
import ApplicationServices

struct MA3Config: Codable, Equatable {
    var enabled = true
    var bundleID = "com.malighting.grandMA3"   // matched by name too
    var processName = "grandMA3"
    var fallbackDisplayIndex = 1               // used when the window title carries no "Display N"
    var pixelScale = 0.0                       // 0 = auto (display backing scale)
    var offsetX = 0.0, offsetY = 0.0           // extra pixel offset if MA3's origin differs
}

/// Routes contacts that land on a grandMA3 onPC window into onPC through its Lua `Touch()` API.
/// Transport: an append-only event file read by the MacTouch plugin running inside onPC.
final class MA3Bridge {
    var cfg: MA3Config
    struct OnPCWindow { let pid: pid_t; let title: String; let frame: CGRect; let displayIndex: Int? }
    private(set) var windows: [OnPCWindow] = []
    private var lastScan: TimeInterval = 0
    private var seq: UInt64 = 0
    private var fh: FileHandle?
    private var bytesWritten: UInt64 = 0
    private var lastEvent: TimeInterval = 0
    private var active: [String: (display: Int, id: Int)] = [:]   // routed contacts: deviceKey:contactID

    static let dir: URL = {
        let d = Config.url.deletingLastPathComponent().appendingPathComponent("ma3", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var eventsURL: URL { dir.appendingPathComponent("events.txt") }
    static var aliveURL: URL { dir.appendingPathComponent("plugin.alive") }
    static var pluginsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MALightingTechnology/gma3_library/datapools/plugins", isDirectory: true)
    }

    init(cfg: MA3Config) {
        self.cfg = cfg
        if !FileManager.default.fileExists(atPath: MA3Bridge.eventsURL.path) { FileManager.default.createFile(atPath: MA3Bridge.eventsURL.path, contents: nil) }
        fh = try? FileHandle(forWritingTo: MA3Bridge.eventsURL)
        fh?.seekToEndOfFile()
        bytesWritten = fh?.offsetInFile ?? 0
    }

    /// True when the onPC plugin wrote its heartbeat within the last 3 seconds.
    var pluginAlive: Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: MA3Bridge.aliveURL.path), let m = a[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(m) < 3
    }

    var onPCRunning: Bool { !onPCProcesses().isEmpty }

    private func onPCProcesses() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            ($0.bundleIdentifier?.lowercased().contains("grandma3") ?? false) || ($0.localizedName?.lowercased() == cfg.processName.lowercased())
        }
    }

    /// Scans onPC windows through the Accessibility API (cached for 0.5 s).
    func refreshWindows(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastScan > 0.5 else { return }
        lastScan = now
        var out: [OnPCWindow] = []
        for app in onPCProcesses() {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success, let wins = value as? [AXUIElement] else { continue }
            for w in wins {
                var t: CFTypeRef?, p: CFTypeRef?, s: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
                AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p)
                AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s)
                var pos = CGPoint.zero, size = CGSize.zero
                if let p = p { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
                if let s = s { AXValueGetValue(s as! AXValue, .cgSize, &size) }
                guard size.width > 50, size.height > 50 else { continue }
                let title = (t as? String) ?? ""
                var idx: Int? = nil
                if let r = title.range(of: #"[Dd]isplay\s*(\d+)"#, options: .regularExpression) {
                    idx = Int(title[r].filter { $0.isNumber })
                }
                out.append(OnPCWindow(pid: app.processIdentifier, title: title, frame: CGRect(origin: pos, size: size), displayIndex: idx))
            }
        }
        windows = out
    }

    /// The onPC window under a global point, if any.
    func window(at p: CGPoint) -> OnPCWindow? {
        refreshWindows()
        return windows.first { $0.frame.contains(p) }
    }

    // MARK: contact routing

    func isRouted(device: String, contact: Int) -> Bool { active["\(device):\(contact)"] != nil }

    func press(device: String, contact: Int, at p: CGPoint, window w: OnPCWindow, display d: DisplayInfo) {
        let idx = w.displayIndex ?? cfg.fallbackDisplayIndex
        active["\(device):\(contact)"] = (idx, contact)
        write("press", idx, contact, p, w, d)
    }

    func move(device: String, contact: Int, at p: CGPoint, display d: DisplayInfo) {
        guard let a = active["\(device):\(contact)"] else { return }
        let w = windows.first { ($0.displayIndex ?? cfg.fallbackDisplayIndex) == a.display } ?? windows.first
        guard let w = w else { return }
        write("move", a.display, contact, p, w, d)
    }

    func release(device: String, contact: Int, at p: CGPoint, display d: DisplayInfo) {
        guard let a = active.removeValue(forKey: "\(device):\(contact)") else { return }
        let w = windows.first { ($0.displayIndex ?? cfg.fallbackDisplayIndex) == a.display } ?? windows.first
        guard let w = w else { return }
        write("release", a.display, contact, p, w, d)
    }

    /// Releases every routed contact (device unplugged, app quitting).
    func releaseAll() {
        for (k, a) in active {
            if let w = windows.first { ($0.displayIndex ?? cfg.fallbackDisplayIndex) == a.display } {
                line("release", a.display, a.id, 0, 0)
                _ = w
            }
            active[k] = nil
        }
    }

    private func write(_ type: String, _ display: Int, _ id: Int, _ p: CGPoint, _ w: OnPCWindow, _ d: DisplayInfo) {
        let scale = cfg.pixelScale > 0 ? cfg.pixelScale : backingScale(for: d)
        let x = Int(((p.x - w.frame.minX) * scale + cfg.offsetX).rounded())
        let y = Int(((p.y - w.frame.minY) * scale + cfg.offsetY).rounded())
        line(type, display, id, x, y)
    }

    private func line(_ type: String, _ display: Int, _ id: Int, _ x: Int, _ y: Int) {
        seq += 1
        let s = "\(seq) \(type) \(display) \(id) \(x) \(y)\n"
        guard let data = s.data(using: .utf8), let fh = fh else { return }
        fh.write(data)
        bytesWritten += UInt64(data.count)
        lastEvent = ProcessInfo.processInfo.systemUptime
        Log.d("ma3 " + s.trimmingCharacters(in: .newlines))
        if bytesWritten > 4_000_000 && active.isEmpty { rotate() }
    }

    private func rotate() {
        // Plugin detects a shrinking file and restarts from offset 0.
        fh?.truncateFile(atOffset: 0)
        fh?.seek(toFileOffset: 0)
        bytesWritten = 0
    }

    private func backingScale(for d: DisplayInfo) -> Double {
        let id = d.mirrorOf == kCGNullDirectDisplay ? d.id : d.mirrorOf
        return Double(NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }?.backingScaleFactor ?? 1)
    }

    // MARK: plugin install

    static let pluginLua = """
    -- MacTouch bridge for grandMA3 onPC (macOS). Reads touch events written by the MacTouch app and
    -- feeds them into onPC's own multi-touch engine through Touch(display, type, id, x, y).
    -- Start it with:  Plugin "MacTouch"      Stop it with:  SetGlobalVar? no: run it again (toggles).
    local DIR = "__MACTOUCH_DIR__/"
    local EVENTS = DIR .. "events.txt"
    local ALIVE = DIR .. "plugin.alive"
    local POLL = 0.01

    local function log(s) Printf("MacTouch: " .. tostring(s)) end

    local function heartbeat()
        local f = io.open(ALIVE, "w")
        if f then f:write(tostring(os.time())); f:close() end
    end

    local function main()
        if MacTouchRunning then
            MacTouchRunning = false
            log("stopping")
            return
        end
        local f = io.open(EVENTS, "rb")
        if not f then
            log("cannot open " .. EVENTS .. " (is the MacTouch app running?)")
            return
        end
        local pos = f:seek("end") or 0
        f:close()
        MacTouchRunning = true
        local ticks = 0
        local lastSeq = 0
        local held = {}
        log("running, reading " .. EVENTS)
        heartbeat()
        local function tick()
            if not MacTouchRunning then
                for key, h in pairs(held) do Touch(h.d, "release", h.id, h.x, h.y) end
                held = {}
                os.remove(ALIVE)
                return
            end
            ticks = ticks + 1
            if ticks % 50 == 0 then heartbeat() end
            local fh = io.open(EVENTS, "rb")
            if not fh then return end
            local size = fh:seek("end") or 0
            if size < pos then pos = 0 end
            if size > pos then
                fh:seek("set", pos)
                local chunk = fh:read(size - pos) or ""
                -- only consume whole lines
                local lastNL = chunk:match(".*()\\n")
                if lastNL then
                    pos = pos + lastNL
                    for line in chunk:sub(1, lastNL):gmatch("[^\\n]+") do
                        local seq, typ, d, id, x, y = line:match("^(%d+) (%a+) (%d+) (%d+) (%-?%d+) (%-?%d+)$")
                        if seq then
                            d = tonumber(d); id = tonumber(id); x = tonumber(x); y = tonumber(y)
                            local key = d .. ":" .. id
                            if typ == "press" then held[key] = {d = d, id = id, x = x, y = y}
                            elseif typ == "move" and held[key] then held[key].x = x; held[key].y = y
                            elseif typ == "release" then held[key] = nil end
                            Touch(d, typ, id, x, y)
                        end
                    end
                end
            end
            fh:close()
        end
        Timer(tick, POLL, 2000000000, function() MacTouchRunning = false; os.remove(ALIVE) end)
    end

    return main
    """

    static let pluginXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <GMA3 DataVersion="2.4.2.0">
    \t<UserPlugin Name="MacTouch" Author="MacTouch" Version="1.0.0.0">
    \t\t<ComponentLua Name="MacTouch" FileName="MacTouch.lua" />
    \t</UserPlugin>
    </GMA3>
    """

    /// Copies the plugin into the gma3 library so it can be imported from the Plugins pool.
    @discardableResult
    static func installPlugin() -> String {
        do {
            try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
            let lua = pluginLua.replacingOccurrences(of: "__MACTOUCH_DIR__", with: dir.path)
            try lua.write(to: pluginsDir.appendingPathComponent("MacTouch.lua"), atomically: true, encoding: .utf8)
            try pluginXML.write(to: pluginsDir.appendingPathComponent("MacTouch.xml"), atomically: true, encoding: .utf8)
            return "Installed to \(pluginsDir.path)"
        } catch { return "Install failed: \(error.localizedDescription)" }
    }
}
