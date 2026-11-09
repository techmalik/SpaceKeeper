import Cocoa
import ApplicationServices

/// "Slack always opens on Desktop 3": new windows of an app with a home desktop are sent there as they appear,
/// and clicking that app in the Dock goes to its home desktop.
@MainActor
final class HomeDesktops {
    static let shared = HomeDesktops()

    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var queue: [(wid: CGWindowID, pid: pid_t)] = []
    private var draining = false
    /// Windows SpaceKeeper itself creates or places (Dock "new window here", layout restore) are left alone.
    private var quietUntil: [pid_t: Date] = [:]
    /// Apps launched while SpaceKeeper runs: their first windows can appear before the observer is attached.
    private var launchedAt: [pid_t: Date] = [:]
    var onMoveFailed: (WindowMover.Failure) -> Void = { _ in }

    nonisolated static func home(of bundleID: String?) -> Int? {
        guard let bundleID, Prefs.homeDesktopsEnabled else { return nil }
        return Prefs.homeDesktops[bundleID]
    }

    static func setHome(_ n: Int?, for bundleID: String) {
        var all = Prefs.homeDesktops
        if let n, n > 0 { all[bundleID] = n } else { all.removeValue(forKey: bundleID) }
        Prefs.homeDesktops = all
        shared.sync()
    }

    func start() {
        guard workspaceTokens.isEmpty else { sync(); return }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated {
                    if let pid { if launched { self?.launchedAt[pid] = Date() } else { self?.launchedAt[pid] = nil; self?.quietUntil[pid] = nil } }
                    self?.sync()
                }
            })
        }
        sync()
    }

    func stop() {
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens = []
        for pid in Array(observers.keys) { detach(pid) }
        queue = []
    }

    /// Don't treat this app's next windows as "new" for a moment.
    func suppress(_ pid: pid_t, for seconds: Double = 3) { quietUntil[pid] = Date().addingTimeInterval(seconds) }

    /// Observe exactly the running apps that have a home desktop.
    func sync() {
        guard !workspaceTokens.isEmpty else { return }
        let rules = Prefs.homeDesktopsEnabled ? Prefs.homeDesktops : [:]
        var wanted = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let b = app.bundleIdentifier, rules[b] != nil { wanted.insert(app.processIdentifier) }
        }
        for pid in observers.keys where !wanted.contains(pid) { detach(pid) }
        for pid in wanted where observers[pid] == nil { attach(pid) }
    }

    private func attach(_ pid: pid_t) {
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<HomeDesktops>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let el = element
            MainActor.assumeIsolated { me.windowCreated(el, pid: pid) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(obs, app, kAXWindowCreatedNotification as CFString, refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
        // Just launched: the windows it opened before we were listening count as new too.
        if let at = launchedAt.removeValue(forKey: pid), Date().timeIntervalSince(at) < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let app = NSRunningApplication(processIdentifier: pid) else { return }
                    if let until = self.quietUntil[pid], Date() < until { return }
                    for w in Windows.ofApp(app) where w.isStandard && !w.minimized { self.queue.append((w.id, pid)) }
                    self.drain()
                }
            }
        }
    }

    private func detach(_ pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    private func windowCreated(_ el: AXUIElement, pid: pid_t) {
        if let until = quietUntil[pid], Date() < until { return }
        // Let the window settle (apps often create, then size and title it).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, AX.string(el, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                      let wid = AX.windowID(el) else { return }
                self.queue.append((wid, pid))
                self.drain()
            }
        }
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        Task { @MainActor in
            defer { self.draining = false }
            var waited = 0
            while !self.queue.isEmpty {
                if WindowMover.shared.busy {
                    waited += 1
                    if waited > 40 { self.queue.removeAll(); break }          // give up after ~20 s
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                let item = self.queue.removeFirst()
                await self.sendHome(item.wid, pid: item.pid)
            }
        }
    }

    private func sendHome(_ wid: CGWindowID, pid: pid_t) async {
        guard let app = NSRunningApplication(processIdentifier: pid), let home = Self.home(of: app.bundleIdentifier),
              let w = Windows.ofApp(app).first(where: { $0.id == wid }), !w.minimized, !w.fullScreen,
              w.spaces.count == 1,
              let (display, desktop) = Spaces.locate(space: w.spaces[0], in: Spaces.displays()),
              desktop != home, home <= display.userSpaces.count else { return }
        dbg("\(app.localizedName ?? "?"): new window \(wid) on Desktop \(desktop) -> home Desktop \(home)")
        if let f = await WindowMover.shared.move(ax: w.ax, wid: w.id, pid: pid, to: .display(display.uuid, home)) {
            onMoveFailed(f)
        }
    }
}
