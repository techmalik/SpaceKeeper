import Cocoa
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    let preview = DockPreviewController()
    let clicker = DockClickMinimizer()
    private var tick: Timer?
    private var frontAtMenuOpen: NSRunningApplication?
    private var lastProblem: String?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        setupStatusItem()
        registerHotkeys()
        DebugControl.shared.startIfEnabled()

        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        if !CGPreflightScreenCaptureAccess() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { _ = CGRequestScreenCaptureAccess() }
        }
        tick = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.startServicesIfPermitted() }
        startServicesIfPermitted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.offerStayOnDesktop() }
    }

    /// One-time offer to turn off macOS's "jump to the desktop where the app has windows" behavior.
    private func offerStayOnDesktop() {
        guard Prefs.systemSwitchOnActivate, !UserDefaults.standard.bool(forKey: "askedStayOnDesktop") else { return }
        UserDefaults.standard.set(true, forKey: "askedStayOnDesktop")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Keep apps on the desktop you're on?"
        alert.informativeText = "Right now, clicking an app in the Dock jumps you to another desktop where that app already has a window. Turn that off so clicking an app opens a new window right here instead? The Dock restarts for a second. You can change this later from the SpaceKeeper menu."
        alert.addButton(withTitle: "Turn Off Jumping")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { Prefs.setSystemSwitchOnActivate(false) }
    }

    private func startServicesIfPermitted() {
        guard AXIsProcessTrusted() else { return }
        preview.start()
        clicker.start()
    }

    // MARK: Hotkeys  (⌃⌥⌘ + 1…9 = send front window to that desktop, ⌃⌥⌘ + ←/→ = previous/next)

    private func registerHotkeys() {
        let mods = cmdKey | optionKey | controlKey
        let numberKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, key) in numberKeys.enumerated() {
            HotKeys.shared.register(keyCode: key, modifiers: mods) { [weak self] in self?.sendFrontWindow(.desktop(i + 1)) }
        }
        HotKeys.shared.register(keyCode: kVK_LeftArrow, modifiers: mods) { [weak self] in self?.sendFrontWindow(.relative(-1)) }
        HotKeys.shared.register(keyCode: kVK_RightArrow, modifiers: mods) { [weak self] in self?.sendFrontWindow(.relative(1)) }
    }

    private func sendFrontWindow(_ target: WindowMover.Target, app: NSRunningApplication? = nil, delay: Double = 0) {
        let app = app ?? NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let failure = await WindowMover.shared.moveFocusedWindow(of: app, to: target)
            self.report(failure)
        }
    }

    private func report(_ failure: WindowMover.Failure?) {
        lastProblem = failure?.rawValue
        guard failure != nil else { statusItem.button?.title = ""; return }
        NSSound.beep()
        statusItem.button?.title = " ⚠︎"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.statusItem.button?.title = "" }
    }

    // MARK: Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "SpaceKeeper")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let front = NSWorkspace.shared.frontmostApplication
        frontAtMenuOpen = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let displays = Spaces.displays()
        let primary = displays.first
        let here = primary?.currentDesktopNumber.map { "Desktop \($0) of \(primary?.userSpaces.count ?? 0)" } ?? "Full-screen space"
        menu.addItem(header("SpaceKeeper — \(here)"))
        if let p = lastProblem { menu.addItem(header("⚠︎ Last move failed: \(p)")) }
        menu.addItem(.separator())

        // Send window submenu
        let sendItem = NSMenuItem(title: "Send Front Window To", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let count = primary?.userSpaces.count ?? 0
        for n in 1...max(count, 1) {
            let it = NSMenuItem(title: "Desktop \(n)", action: #selector(sendToDesktop(_:)), keyEquivalent: n <= 9 ? "\(n)" : "")
            it.keyEquivalentModifierMask = [.control, .option, .command]
            it.tag = n; it.target = self
            it.isEnabled = n != primary?.currentDesktopNumber
            sub.addItem(it)
        }
        sub.addItem(.separator())
        for (title, delta, key) in [("Previous Desktop", -1, NSLeftArrowFunctionKey), ("Next Desktop", 1, NSRightArrowFunctionKey)] {
            let it = NSMenuItem(title: title, action: #selector(sendRelative(_:)),
                                keyEquivalent: String(UnicodeScalar(UInt32(key))!))
            it.keyEquivalentModifierMask = [.control, .option, .command]
            it.tag = delta; it.target = self
            sub.addItem(it)
        }
        sendItem.submenu = sub
        menu.addItem(sendItem)
        menu.addItem(.separator())

        menu.addItem(toggle("Dock hover previews (this desktop only)", Prefs.previewsEnabled, #selector(togglePreviews)))
        menu.addItem(toggle("Click Dock icon to minimize", Prefs.clickToMinimize, #selector(toggleMinimize)))
        menu.addItem(toggle("New window here if app has none on this desktop", Prefs.openNewWindowHere, #selector(toggleNewWindow)))
        menu.addItem(toggle("Follow window to its new desktop", Prefs.followWindow, #selector(toggleFollow)))
        menu.addItem(toggle("Don't jump to other desktops when opening apps", !Prefs.systemSwitchOnActivate, #selector(toggleSwitchOnActivate)))
        menu.addItem(toggle("Launch at login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(.separator())

        menu.addItem(permission("Accessibility", AXIsProcessTrusted(), "Privacy_Accessibility"))
        menu.addItem(permission("Screen Recording (previews)", CGPreflightScreenCaptureAccess(), "Privacy_ScreenCapture"))
        for (bundleID, name) in Self.otherPreviewTools {
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                let it = NSMenuItem(title: "\(name) is running — quit it to avoid duplicate previews", action: #selector(quitOther(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = other
                menu.addItem(it)
            }
        }
        menu.addItem(.separator())
        for (title, sel) in [("About SpaceKeeper", #selector(showAbout)), ("Send Feedback…", #selector(sendFeedback)),
                             ("Project on GitHub", #selector(openGitHub)), ("Check for Updates…", #selector(checkUpdates))] {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SpaceKeeper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func header(_ s: String) -> NSMenuItem { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }

    private func toggle(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self; i.state = on ? .on : .off
        return i
    }

    private func permission(_ name: String, _ granted: Bool, _ pane: String) -> NSMenuItem {
        let i = NSMenuItem(title: granted ? "\(name): granted ✓" : "\(name): not granted — click to fix", action: #selector(openPane(_:)), keyEquivalent: "")
        i.target = self; i.representedObject = pane; i.isEnabled = !granted
        return i
    }

    // MARK: Actions

    @objc private func sendToDesktop(_ s: NSMenuItem) { sendFrontWindow(.desktop(s.tag), app: frontAtMenuOpen, delay: 0.35) }
    @objc private func sendRelative(_ s: NSMenuItem) { sendFrontWindow(.relative(s.tag), app: frontAtMenuOpen, delay: 0.35) }
    @objc private func togglePreviews() { Prefs.previewsEnabled.toggle(); if !Prefs.previewsEnabled { preview.hide() } }
    @objc private func toggleMinimize() { Prefs.clickToMinimize.toggle() }
    @objc private func toggleNewWindow() { Prefs.openNewWindowHere.toggle() }
    @objc private func toggleFollow() { Prefs.followWindow.toggle() }
    @objc private func toggleSwitchOnActivate() { Prefs.setSystemSwitchOnActivate(!Prefs.systemSwitchOnActivate) }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }
    @objc private func openPane(_ s: NSMenuItem) {
        guard let pane = s.representedObject as? String else { return }
        if pane == "Privacy_Accessibility" {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        } else {
            _ = CGRequestScreenCaptureAccess()
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
    @objc private func quitOther(_ s: NSMenuItem) { (s.representedObject as? NSRunningApplication)?.terminate() }
    @objc private func showAbout() { AboutWindowController.shared.show() }
    @objc private func sendFeedback() { NSWorkspace.shared.open(AppInfo.feedbackURL) }
    @objc private func openGitHub() { NSWorkspace.shared.open(AppInfo.repo) }
    @objc private func checkUpdates() { NSWorkspace.shared.open(AppInfo.releases) }

    /// Other Dock-preview apps that would draw their own cards on top of ours.
    private static let otherPreviewTools: [(String, String)] = [
        ("cn.better365.iDock", "iDock"),
        ("com.ethanbills.DockDoor", "DockDoor"),
    ]
}
