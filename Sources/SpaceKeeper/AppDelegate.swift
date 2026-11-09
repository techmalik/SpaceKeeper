import Cocoa
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    let preview = DockPreviewController()
    let clicker = DockClickMinimizer()
    private var tick: Timer?
    private var frontAtMenuOpen: NSRunningApplication?
    private var lastProblem: String?
    private var warningToken = 0
    private var warning = false
    private var restoredAtLaunch = false
    private var spaceObserver: NSObjectProtocol?

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
        tick = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.startServicesIfPermitted() } }
        startServicesIfPermitted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.offerStayOnDesktop(); self?.offerAutoUpdates() }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshTitle() } }
        NotificationCenter.default.addObserver(forName: .desktopNamesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTitle() }
        }
        Layouts.shared.onStateChange = { [weak self] in self?.refreshTitle() }
        HomeDesktops.shared.onMoveFailed = { [weak self] f in self?.report(f) }
        SwitcherController.shared.onGo = { desktop, display in
            Task { @MainActor in await WindowMover.shared.switchTo(desktop: desktop, display: display) }
        }
        SwitcherController.shared.onSend = { [weak self] desktop, display, app, all in
            if all { self?.sendAppWindows(app, to: .display(display, desktop), delay: 0.3) }
            else { self?.sendFrontWindow(.display(display, desktop), app: app, delay: 0.3) }
        }
        SettingsWindowController.shared.applyHotkeys = { [weak self] suspended in
            if suspended { HotKeys.shared.unregisterAll() } else { self?.registerHotkeys() }
        }
        refreshTitle()
    }

    /// One-time offer to check GitHub for new versions once a day.
    private func offerAutoUpdates() {
        guard !UserDefaults.standard.bool(forKey: "askedAutoUpdates") else { return }
        UserDefaults.standard.set(true, forKey: "askedAutoUpdates")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Check for SpaceKeeper updates automatically?"
        alert.informativeText = "Once a day SpaceKeeper would ask GitHub whether a newer version exists and tell you if there is one. Nothing about you or your Mac is sent. You can change this later from the SpaceKeeper menu."
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Don't Check")
        Prefs.autoCheckUpdates = alert.runModal() == .alertFirstButtonReturn
        Updates.checkIfDue()
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
        Updates.checkIfDue()
        guard AXIsProcessTrusted() else { preview.stop(); clicker.stop(); HomeDesktops.shared.stop(); return }
        preview.start()
        clicker.onHandled = { [weak self] in self?.preview.dismiss() }
        clicker.start()
        HomeDesktops.shared.start()
        restoreAtLaunchIfAsked()
    }

    private func restoreAtLaunchIfAsked() {
        guard !restoredAtLaunch else { return }
        restoredAtLaunch = true
        guard let name = Prefs.restoreLayoutAtLaunch, let layout = Layouts.all.first(where: { $0.name == name }) else { return }
        // Give login items time to open their windows first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.restore(layout, confirm: false) }
    }

    // MARK: Hotkeys (configurable in Settings › Shortcuts)

    private func registerHotkeys() {
        HotKeys.shared.registerActions { [weak self] id in self?.perform(id) }
        SettingsWindowController.shared.shortcuts.reload()
    }

    func debugPerform(_ id: String) { perform(id) }
    var debugTitle: String { statusItem.button?.title ?? "" }

    private func perform(_ id: String) {
        let parts = id.split(separator: ".").map(String.init)
        guard let kind = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        let target: WindowMover.Target?
        switch arg {
        case "prev": target = .relative(-1)
        case "next": target = .relative(1)
        case "display": target = .nextDisplay
        default: target = Int(arg).map { .desktop($0) }
        }
        switch kind {
        case "switcher": SwitcherController.shared.toggle()
        case "send": if let target { sendFrontWindow(target) }
        case "sendApp": if let target, let app = NSWorkspace.shared.frontmostApplication { sendAppWindows(app, to: target) }
        default: break
        }
    }

    private func sendFrontWindow(_ target: WindowMover.Target, app: NSRunningApplication? = nil, delay: Double = 0) {
        let app = app ?? NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let failure = await WindowMover.shared.moveFocusedWindow(of: app, to: target)
            self.report(failure)
        }
    }

    /// Every movable window of `app` on this desktop.
    private func movableWindows(of app: NSRunningApplication) -> [Win] {
        Windows.ofApp(app).filter { !$0.minimized && !$0.fullScreen && $0.spaces.count == 1 && $0.isStandard }
    }

    private func sendAppWindows(_ app: NSRunningApplication, to target: WindowMover.Target, delay: Double = 0) {
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let wins = self.movableWindows(of: app)
            guard !wins.isEmpty else { self.report(.noWindow); return }
            let r = await WindowMover.shared.moveAll(wins, to: target)
            self.report(r.failures.first, partial: r.moved > 0 ? (r.moved, wins.count) : nil)
        }
    }

    private func sendDesktopWindows(to target: WindowMover.Target, delay: Double = 0) {
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let me = ProcessInfo.processInfo.processIdentifier
            let wins = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isHidden }
                .flatMap { self.movableWindows(of: $0) }
            guard !wins.isEmpty else { self.report(.noWindow); return }
            let r = await WindowMover.shared.moveAll(wins, to: target)
            self.report(r.failures.first, partial: r.moved > 0 ? (r.moved, wins.count) : nil)
        }
    }

    private func report(_ failure: WindowMover.Failure?, partial: (moved: Int, of: Int)? = nil) {
        guard let failure else { lastProblem = nil; warning = false; refreshTitle(); return }
        if let partial { lastProblem = "\(partial.moved) of \(partial.of) windows moved — \(failure.rawValue)" }
        else { lastProblem = failure.rawValue }
        NSSound.beep()
        warning = true
        refreshTitle()
        warningToken += 1
        let token = warningToken
        // A newer warning keeps its own four seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.warningToken == token else { return }
            self.warning = false
            self.refreshTitle()
        }
    }

    /// Menu-bar text: the current desktop's name (if turned on), a restore indicator and the move warning.
    private func refreshTitle() {
        var t = ""
        if Prefs.showDesktopName, let (d, n) = currentDesktop() { t += " " + DesktopNames.short(display: d, desktop: n) }
        if Layouts.shared.restoring { t += " ↻" }
        if warning { t += " ⚠︎" }
        statusItem?.button?.title = t
    }

    /// The desktop showing on the display with the menu bar the user is looking at.
    private func currentDesktop() -> (DisplaySpaces, Int)? {
        let displays = Spaces.displays()
        let screenID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let uuid = screenID.flatMap(DisplayGeometry.uuid(of:))
        let d = displays.first { $0.uuid.caseInsensitiveCompare(uuid ?? "") == .orderedSame } ?? displays.first
        guard let d, let n = d.currentDesktopNumber else { return nil }
        return (d, n)
    }

    // MARK: Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "SpaceKeeper")
        let menu = NSMenu()
        menu.autoenablesItems = false        // otherwise every item with a target is enabled and isEnabled is ignored
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
        let app = frontAtMenuOpen ?? NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "App"
        let windowSpaces = app.flatMap { Windows.focused(of: $0) }.flatMap(AX.windowID).map(Spaces.spaces) ?? []
        let primary = displays.first(where: { windowSpaces.contains($0.current) }) ?? currentDesktop()?.0 ?? displays.first
        let here: String
        if let p = primary, let n = p.currentDesktopNumber {
            here = "\(DesktopNames.label(display: p, desktop: n)) of \(p.userSpaces.count)"
        } else {
            here = "Full-screen space"
        }
        menu.addItem(header("SpaceKeeper — \(here)"))
        if let p = lastProblem { menu.addItem(header("⚠︎ Last move failed: \(p)")) }
        if Layouts.shared.restoring { menu.addItem(item("Stop Restoring Layout", #selector(stopRestore))) }
        menu.addItem(.separator())

        menu.addItem(item("Show Desktop Switcher", #selector(showSwitcher), shortcut: "switcher"))
        menu.addItem(submenu("Send Front Window To", sendMenu(primary, displays, #selector(sendTo(_:)), shortcutPrefix: "send")))
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            menu.addItem(submenu("Send All \(appName) Windows To", sendMenu(primary, displays, #selector(sendAppTo(_:)), shortcutPrefix: "sendApp")))
        }
        menu.addItem(submenu("Send All Windows on This Desktop To", sendMenu(primary, displays, #selector(sendDesktopTo(_:)), shortcutPrefix: nil)))
        menu.addItem(.separator())

        // Workspaces
        if let p = primary, let n = p.currentDesktopNumber {
            let rename = item("Rename This Desktop…", #selector(renameDesktop(_:)))
            rename.representedObject = Box(p.uuid, n)
            menu.addItem(rename)
        }
        if let app, let bundleID = app.bundleIdentifier, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            menu.addItem(submenu("Home Desktop for \(appName)", homeMenu(bundleID: bundleID, count: primary?.userSpaces.count ?? 1)))
        }
        menu.addItem(submenu("Layouts", layoutsMenu()))
        menu.addItem(.separator())

        menu.addItem(toggle("Dock hover previews (this desktop only)", Prefs.previewsEnabled, #selector(togglePreviews)))
        menu.addItem(toggle("Click Dock icon to minimize", Prefs.clickToMinimize, #selector(toggleMinimize)))
        menu.addItem(toggle("New window here if app has none on this desktop", Prefs.openNewWindowHere, #selector(toggleNewWindow)))
        menu.addItem(toggle("Follow window to its new desktop", Prefs.followWindow, #selector(toggleFollow)))
        menu.addItem(toggle("Send new windows to their app's home desktop", Prefs.homeDesktopsEnabled, #selector(toggleHomes)))
        menu.addItem(toggle("Show desktop name in menu bar", Prefs.showDesktopName, #selector(toggleShowName)))
        menu.addItem(toggle("Don't jump to other desktops when opening apps", !Prefs.systemSwitchOnActivate, #selector(toggleSwitchOnActivate)))
        menu.addItem(toggle("Launch at login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(toggle("Check for updates automatically", Prefs.autoCheckUpdates, #selector(toggleAutoUpdates)))
        menu.addItem(.separator())

        menu.addItem(permission("Accessibility", AXIsProcessTrusted(), "Privacy_Accessibility"))
        menu.addItem(permission("Screen Recording (previews)", CGPreflightScreenCaptureAccess(), "Privacy_ScreenCapture"))
        if !HotKeys.shared.unavailable.isEmpty {
            menu.addItem(item("⚠︎ \(HotKeys.shared.unavailable.count) shortcut(s) are taken by another app — change them…", #selector(showShortcuts)))
        }
        for (bundleID, name) in Self.otherPreviewTools {
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                let it = NSMenuItem(title: "\(name) is running — quit it to avoid duplicate previews", action: #selector(quitOther(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = other
                menu.addItem(it)
            }
        }
        menu.addItem(.separator())
        let settings = item("Settings…", #selector(showSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        for (title, sel) in [("About SpaceKeeper", #selector(showAbout)), ("Send Feedback…", #selector(sendFeedback)),
                             ("Project on GitHub", #selector(openGitHub)), ("Check for Updates…", #selector(checkUpdates))] {
            menu.addItem(item(title, sel))
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SpaceKeeper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Carries a target (or a display + desktop) through a menu item.
    private final class Box: NSObject {
        let target: WindowMover.Target?
        let display: String
        let desktop: Int
        init(target: WindowMover.Target) { self.target = target; display = ""; desktop = 0 }
        init(_ display: String, _ desktop: Int) { target = nil; self.display = display; self.desktop = desktop }
    }

    private func item(_ title: String, _ sel: Selector, shortcut id: String? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        if let id, let s = HotKeyBindings.shortcut(forID: id), let key = s.menuKeyEquivalent {
            it.keyEquivalent = key
            it.keyEquivalentModifierMask = s.modifierFlags
        }
        return it
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = sub
        return it
    }

    /// Desktops on the window's display (+ previous / next), then the other displays' desktops.
    private func sendMenu(_ primary: DisplaySpaces?, _ displays: [DisplaySpaces], _ sel: Selector, shortcutPrefix: String?) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        func add(_ title: String, _ target: WindowMover.Target, id: String?, enabled: Bool = true) {
            let it = item(title, sel, shortcut: id.flatMap { id in shortcutPrefix.map { "\($0).\(id)" } })
            it.representedObject = Box(target: target)
            it.isEnabled = enabled
            sub.addItem(it)
        }
        if let p = primary {
            if displays.count > 1 { sub.addItem(header(DisplayGeometry.name(forUUID: p.uuid))) }
            for n in 1...max(p.userSpaces.count, 1) {
                add(DesktopNames.label(display: p, desktop: n), .desktop(n), id: "\(n)", enabled: n != p.currentDesktopNumber)
            }
            sub.addItem(.separator())
            add("Previous Desktop", .relative(-1), id: "prev")
            add("Next Desktop", .relative(1), id: "next")
        }
        for d in displays where d.uuid != primary?.uuid {
            sub.addItem(.separator())
            sub.addItem(header(DisplayGeometry.name(forUUID: d.uuid)))
            let usable = d.currentDesktopNumber != nil
            add("Desktop Showing There", .display(d.uuid, 0), id: shortcutPrefix == "send" ? "display" : nil, enabled: usable)
            for n in 1...max(d.userSpaces.count, 1) {
                add(DesktopNames.label(display: d, desktop: n), .display(d.uuid, n), id: nil, enabled: usable)
            }
        }
        return sub
    }

    private func homeMenu(bundleID: String, count: Int) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let current = Prefs.homeDesktops[bundleID]
        let none = item("None", #selector(setHome(_:)))
        none.representedObject = HomeChoice(bundleID, nil)
        none.state = current == nil ? .on : .off
        sub.addItem(none)
        sub.addItem(.separator())
        for n in 1...max(count, current ?? 1, 1) {
            let it = item("Desktop \(n)", #selector(setHome(_:)))
            it.representedObject = HomeChoice(bundleID, n)
            it.state = current == n ? .on : .off
            sub.addItem(it)
        }
        sub.addItem(.separator())
        sub.addItem(item("Manage Home Desktops…", #selector(showHomes)))
        return sub
    }

    private final class HomeChoice: NSObject {
        let bundleID: String; let desktop: Int?
        init(_ b: String, _ d: Int?) { bundleID = b; desktop = d }
    }

    private func layoutsMenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(item("Save Current Layout…", #selector(saveLayout)))
        let layouts = Layouts.all
        if layouts.isEmpty {
            sub.addItem(header("No saved layouts"))
            return sub
        }
        sub.addItem(.separator())
        sub.addItem(header("Restore"))
        for l in layouts {
            let it = item(l.name, #selector(restoreLayout(_:)))
            it.representedObject = l.name
            it.isEnabled = !Layouts.shared.restoring
            it.toolTip = "\(l.entries.count) windows · saved \(l.saved.formatted(date: .abbreviated, time: .shortened))"
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let atLaunch = NSMenu()
        atLaunch.autoenablesItems = false
        let none = item("Don't Restore", #selector(setRestoreAtLaunch(_:)))
        none.state = Prefs.restoreLayoutAtLaunch == nil ? .on : .off
        atLaunch.addItem(none)
        for l in layouts {
            let it = item(l.name, #selector(setRestoreAtLaunch(_:)))
            it.representedObject = l.name
            it.state = Prefs.restoreLayoutAtLaunch == l.name ? .on : .off
            atLaunch.addItem(it)
        }
        sub.addItem(submenu("Restore When SpaceKeeper Starts", atLaunch))
        let del = NSMenu()
        del.autoenablesItems = false
        for l in layouts {
            let it = item(l.name, #selector(deleteLayout(_:)))
            it.representedObject = l.name
            del.addItem(it)
        }
        sub.addItem(submenu("Delete", del))
        return sub
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

    @objc private func sendTo(_ s: NSMenuItem) {
        guard let t = (s.representedObject as? Box)?.target else { return }
        sendFrontWindow(t, app: frontAtMenuOpen, delay: 0.35)
    }
    @objc private func sendAppTo(_ s: NSMenuItem) {
        guard let t = (s.representedObject as? Box)?.target, let app = frontAtMenuOpen ?? NSWorkspace.shared.frontmostApplication else { return }
        sendAppWindows(app, to: t, delay: 0.35)
    }
    @objc private func sendDesktopTo(_ s: NSMenuItem) {
        guard let t = (s.representedObject as? Box)?.target else { return }
        sendDesktopWindows(to: t, delay: 0.35)
    }
    @objc private func showSwitcher() {
        // Let the menu close first so the pointer's display and the frontmost app are the real ones.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { SwitcherController.shared.show() }
    }
    @objc private func renameDesktop(_ s: NSMenuItem) {
        guard let b = s.representedObject as? Box, let d = Spaces.displays().first(where: { $0.uuid == b.display }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Name Desktop \(b.desktop)"
        alert.informativeText = "Leave it empty to go back to \"Desktop \(b.desktop)\"."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = DesktopNames.custom(display: d, desktop: b.desktop) ?? ""
        field.placeholderString = "e.g. Work"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DesktopNames.set(field.stringValue, display: d, desktop: b.desktop)
        refreshTitle()
    }
    @objc private func setHome(_ s: NSMenuItem) {
        guard let c = s.representedObject as? HomeChoice else { return }
        HomeDesktops.setHome(c.desktop, for: c.bundleID)
    }
    @objc private func saveLayout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save Current Layout"
        let count = Layouts.placedWindows().count
        alert.informativeText = "Remembers which desktop each of the \(count) open windows is on. Saving with an existing name replaces it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Layout \(Layouts.all.count + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { NSSound.beep(); return }
        Layouts.saveCurrent(named: String(name.prefix(60)))
    }
    @objc private func restoreLayout(_ s: NSMenuItem) {
        guard let name = s.representedObject as? String, let l = Layouts.all.first(where: { $0.name == name }) else { return }
        restore(l, confirm: true)
    }
    private func restore(_ layout: SavedLayout, confirm: Bool) {
        guard AXIsProcessTrusted(), !Layouts.shared.restoring else { return }
        if confirm {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Restore \"\(layout.name)\"?"
            alert.informativeText = "SpaceKeeper opens any apps that aren't running, then visits your desktops and carries windows to where they were. It uses the mouse and keyboard for about a second per desktop crossed — please don't touch them until it's done. Choose Stop Restoring Layout in the menu to cancel."
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Layouts.shared.restore(layout) { [weak self] moved, failed, cancelled in
            if failed > 0 || cancelled {
                self?.lastProblem = cancelled ? "Layout restore stopped after \(moved) windows"
                                              : "Layout restore: \(moved) moved, \(failed) couldn't be moved"
                NSSound.beep()
            }
        }
    }
    @objc private func stopRestore() { Layouts.shared.cancel() }
    @objc private func setRestoreAtLaunch(_ s: NSMenuItem) { Prefs.restoreLayoutAtLaunch = s.representedObject as? String }
    @objc private func deleteLayout(_ s: NSMenuItem) {
        guard let name = s.representedObject as? String else { return }
        Layouts.delete(named: name)
    }
    @objc private func toggleHomes() { Prefs.homeDesktopsEnabled.toggle(); HomeDesktops.shared.sync() }
    @objc private func toggleShowName() { Prefs.showDesktopName.toggle(); refreshTitle() }
    @objc private func toggleAutoUpdates() { Prefs.autoCheckUpdates.toggle(); Updates.checkIfDue() }
    @objc private func showSettings() { SettingsWindowController.shared.show(.shortcuts) }
    @objc private func showShortcuts() { SettingsWindowController.shared.show(.shortcuts) }
    @objc private func showHomes() { SettingsWindowController.shared.show(.home) }
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
    @objc private func sendFeedback() { FeedbackWindowController.shared.show() }
    @objc private func openGitHub() { NSWorkspace.shared.open(AppInfo.repo) }
    @objc private func checkUpdates() { Updates.check(userInitiated: true) }

    /// Other Dock-preview apps that would draw their own cards on top of ours.
    private static let otherPreviewTools: [(String, String)] = [
        ("cn.better365.iDock", "iDock"),
        ("com.ethanbills.DockDoor", "DockDoor"),
    ]
}
