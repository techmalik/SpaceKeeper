import Cocoa
import ApplicationServices

/// Per-desktop "running" dots for the Dock.
///
/// macOS puts a dot under every running app, on every desktop, so an app whose only window is on Desktop 2 still
/// looks "open" on Desktop 1. When this feature is on, SpaceKeeper turns the Dock's own dots off and draws its own
/// dot only under apps that have a window (minimized ones included) on the desktop you're looking at, using the
/// same rule as the hover card's "No windows on this desktop".
///
/// The dots live in a transparent, click-through panel just above the Dock. Window membership is worked out off
/// the main thread (Accessibility calls into other apps can be slow); Dock icon positions are re-read often while
/// the pointer is over the Dock so the dots follow magnification.
final class DockDots {
    static let shared = DockDots()

    private var panel: NSPanel?
    private var view: DotsView?
    private var observers: [NSObjectProtocol] = []
    private var windowTimer: Timer?
    private var frameTimer: Timer?
    private let queue = DispatchQueue(label: "SpaceKeeper.DockDots", qos: .userInitiated)
    private var scanning = false
    private var rescanWanted = false

    /// pids with a window on the current desktop (written on the main thread from the background scan).
    private var appsHere: Set<pid_t> = []
    private var items: [DockAppItem] = []
    private var lastFrameRead = Date.distantPast

    var isRunning: Bool { panel != nil }

    // MARK: Start / stop

    func start() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let v = DotsView()
        p.contentView = v
        panel = p; view = v

        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                // A space change makes the old dots wrong at once: clear them rather than show stale ones.
                if n.name == NSWorkspace.activeSpaceDidChangeNotification { self?.appsHere = []; self?.redraw() }
                self?.rescan()
            })
        }
        let wt = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.rescan() }
        let ft = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.frameTick() }
        RunLoop.main.add(wt, forMode: .common); RunLoop.main.add(ft, forMode: .common)
        windowTimer = wt; frameTimer = ft
        rescan()
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        windowTimer?.invalidate(); frameTimer?.invalidate()
        windowTimer = nil; frameTimer = nil
        panel?.orderOut(nil); panel = nil; view = nil
        appsHere = []; items = []
    }

    // MARK: Work

    /// Re-read Dock icon positions: every 20th of a second while the pointer is near the Dock (magnification moves
    /// icons), otherwise once a second (icons added, removed, reordered).
    private func frameTick() {
        let near = CGEvent(source: nil).map { DockInspector.shared.isNearDock($0.location) } ?? false
        guard near || Date().timeIntervalSince(lastFrameRead) >= 1.0 else { return }
        lastFrameRead = Date()
        queue.async {
            let fresh = DockAppItem.all()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel != nil else { return }
                if fresh != self.items { self.items = fresh; self.redraw() }
            }
        }
    }

    private func rescan() {
        guard panel != nil else { return }
        if scanning { rescanWanted = true; return }
        scanning = true
        queue.async {
            let fresh = DockAppItem.all()
            let here = Self.appsWithWindowsHere(among: Set(fresh.map(\.pid)))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanning = false
                guard self.panel != nil else { return }
                self.items = fresh
                self.appsHere = here
                self.redraw()
                if self.rescanWanted { self.rescanWanted = false; self.rescan() }
            }
        }
    }

    /// Same rule as the hover card: a standard window or dialog of the app on this desktop, minimized or not.
    /// The window server is asked first (one cheap call) so apps with nothing here skip the Accessibility query.
    private static func appsWithWindowsHere(among pids: Set<pid_t>) -> Set<pid_t> {
        let current = Spaces.currentIDs()
        var candidates = Set<pid_t>()
        if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid), !candidates.contains(pid),
                      (w[kCGWindowLayer as String] as? Int) == 0,
                      let id = w[kCGWindowNumber as String] as? Int else { continue }
                if !current.isDisjoint(with: Spaces.spaces(of: CGWindowID(id))) { candidates.insert(pid) }
            }
        }
        var here = Set<pid_t>()
        for pid in candidates {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { continue }
            if !Windows.ofApp(app).isEmpty { here.insert(pid) }
        }
        return here
    }

    private func redraw() {
        guard let panel, let view else { return }
        // No Dock to decorate on a full-screen app's space.
        let onFullScreen = Spaces.displays().contains { d in d.spaces.contains { $0.id == d.current && !$0.isUser } }
        let orientation = DockInspector.shared.orientation
        let dots: [CGPoint] = items.filter { appsHere.contains($0.pid) }.map { i in
            switch orientation {                                   // global, top-left origin
            case .bottom: return CGPoint(x: i.frame.midX, y: i.frame.maxY - Self.inset)
            case .left:   return CGPoint(x: i.frame.minX + Self.inset, y: i.frame.midY)
            case .right:  return CGPoint(x: i.frame.maxX - Self.inset, y: i.frame.midY)
            }
        }
        // When the Dock is hidden (auto-hide) its icons report positions off the screen.
        let screens = NSScreen.screens.map { $0.frame }
        let visible = dots.filter { p in
            let c = CGRect(x: p.x, y: p.y, width: 0, height: 0).cocoaRect.origin
            return screens.contains { $0.insetBy(dx: -1, dy: -1).contains(c) }
        }
        guard !onFullScreen, !visible.isEmpty else { panel.orderOut(nil); view.dots = []; return }

        let r = Self.diameter
        let bounds = visible.reduce(CGRect.null) { $0.union(CGRect(x: $1.x - r, y: $1.y - r, width: 2 * r, height: 2 * r)) }
        let frame = bounds.cocoaRect.integral
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        view.dots = visible.map { p in
            let c = CGRect(x: p.x, y: p.y, width: 0, height: 0).cocoaRect.origin
            return CGPoint(x: c.x - frame.minX, y: c.y - frame.minY)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Measured from the Dock's own dots: 4 pt across, centred 6 pt in from the edge of the icon's Dock tile.
    static let inset: CGFloat = 6
    static let diameter: CGFloat = 4

    /// For the debug channel.
    var debugDescription: String {
        let names = items.map { i in "\(NSRunningApplication(processIdentifier: i.pid)?.localizedName ?? "?")\(appsHere.contains(i.pid) ? " •" : "")" }
        return "dots running=\(isRunning) visible=\(panel?.isVisible ?? false) frame=\(panel?.frame ?? .zero) nativeDots=\(Prefs.nativeDockDots)\n  " + names.joined(separator: "\n  ")
    }
}

/// A running app's icon in the Dock.
struct DockAppItem: Equatable {
    let pid: pid_t
    let frame: CGRect          // global, top-left origin

    /// Every running app's Dock icon, read straight from the Dock (safe to call off the main thread).
    static func all() -> [DockAppItem] {
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let dock = AXUIElementCreateApplication(dockApp.processIdentifier)
        AXUIElementSetMessagingTimeout(dock, 0.25)
        guard let list = AX.elements(dock, kAXChildrenAttribute).first(where: { AX.string($0, kAXRoleAttribute) == "AXList" }) else { return [] }
        var out: [DockAppItem] = []
        for el in AX.elements(list, kAXChildrenAttribute) {
            guard AX.string(el, kAXSubroleAttribute) == "AXApplicationDockItem",
                  AX.bool(el, "AXIsApplicationRunning") ?? false,
                  let url = AX.value(el, "AXURL") as? URL,
                  let bundleID = Bundle(url: url)?.bundleIdentifier,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .first(where: { $0.activationPolicy == .regular }),
                  let frame = AX.frame(el) else { continue }
            out.append(DockAppItem(pid: app.processIdentifier, frame: frame))
        }
        return out
    }
}

private final class DotsView: NSView {
    var dots: [CGPoint] = [] { didSet { if dots != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.setFill()
        let r = DockDots.diameter / 2
        for p in dots { NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill() }
    }
}
