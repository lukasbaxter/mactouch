import AppKit
import SwiftUI
import IOKit.hid
import ServiceManagement

final class AppState: ObservableObject {
    @Published var config: Config
    @Published var inputMonitoring = false
    @Published var accessibility = false
    @Published var tick = 0            // bump to refresh device/display lists
    @Published var lastGesture: String = ""
    let engine: Engine

    init() {
        let c = Config.load()
        config = c
        engine = Engine(config: c)
        engine.onChange = { [weak self] in DispatchQueue.main.async { self?.tick += 1 } }
        engine.gestureObserver = { [weak self] g in DispatchQueue.main.async { self?.lastGesture = g.title } }
    }

    func save() {
        config.save()
        engine.update(config: config)
        applyLoginItem()
    }

    func refreshPermissions() {
        inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        accessibility = AXIsProcessTrusted()
    }

    func requestPermissions() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    func applyLoginItem() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications") || Bundle.main.bundleURL.path.contains("/Applications/") else { return }
        do {
            if config.launchAtLogin { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch { Log.w("login item: \(error)") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var permTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        if CommandLine.arguments.contains("--verbose") { Log.verbose = true }
        Log.i("MacTouch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") starting; config at \(Config.url.path)")
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        state.refreshPermissions()
        if !state.inputMonitoring || !state.accessibility {
            state.requestPermissions()
            openSettings(tab: "status")
        }
        tryStart()
        permTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tryStart() }
        state.applyLoginItem()
        state.engine.onChange = { [weak self] in DispatchQueue.main.async { self?.state.tick += 1; self?.rebuildMenu() } }
        if CommandLine.arguments.contains("--settings") { openSettings(tab: "devices") }
    }

    func tryStart() {
        state.refreshPermissions()
        if state.inputMonitoring && !state.engine.running { state.engine.start(); rebuildMenu() }
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "MacTouch") { img.isTemplate = true; statusItem.button?.image = img }
        rebuildMenu()
    }

    func rebuildMenu() {
        let m = NSMenu()
        let title = NSMenuItem(title: "MacTouch", action: nil, keyEquivalent: ""); title.isEnabled = false; m.addItem(title)
        if !state.engine.running {
            let i = NSMenuItem(title: "Not running: grant Input Monitoring", action: #selector(openStatus), keyEquivalent: ""); i.target = self; m.addItem(i)
        } else if state.engine.pipelines.isEmpty {
            let i = NSMenuItem(title: "No touchscreen connected", action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i)
        } else {
            for p in state.engine.pipelines.values.sorted(by: { $0.device.name < $1.device.name }) {
                let t = "\(p.device.name) → \(p.display?.name ?? "no display assigned")"
                let i = NSMenuItem(title: t, action: #selector(openDevices), keyEquivalent: ""); i.target = self; m.addItem(i)
            }
        }
        m.addItem(.separator())
        let s = NSMenuItem(title: "Settings…", action: #selector(openDevices), keyEquivalent: ","); s.target = self; m.addItem(s)
        let g = NSMenuItem(title: "Gestures…", action: #selector(openGestures), keyEquivalent: ""); g.target = self; m.addItem(g)
        let l = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: ""); l.target = self; m.addItem(l)
        m.addItem(.separator())
        let q = NSMenuItem(title: "Quit MacTouch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); m.addItem(q)
        statusItem.menu = m
    }

    @objc func openStatus() { openSettings(tab: "status") }
    @objc func openDevices() { openSettings(tab: "devices") }
    @objc func openGestures() { openSettings(tab: "gestures") }
    @objc func openLog() { NSWorkspace.shared.open(Log.url) }

    func openSettings(tab: String) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "MacTouch"
            w.isReleasedWhenClosed = false
            w.center()
            w.contentView = NSHostingView(rootView: SettingsView(state: state, initialTab: tab))
            settingsWindow = w
        } else {
            SettingsTabRouter.shared.select(tab)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(tab: "devices"); return true
    }
}

final class SettingsTabRouter: ObservableObject {
    static let shared = SettingsTabRouter()
    @Published var tab: String = "devices"
    func select(_ t: String) { tab = t }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
