import Cocoa
import ApplicationServices

struct DockItem {
    let app: NSRunningApplication
    let title: String
    let frame: CGRect          // global, top-left origin (same space as CGEvent locations)
}

/// Asks the Dock process (through Accessibility) which app icon is under a point.
final class DockInspector {
    static let shared = DockInspector()

    private var dock: AXUIElement?
    private var dockPID: pid_t = 0
    private var lastRefresh = Date.distantPast
    private(set) var listFrame: CGRect = .zero
    /// Dock settings, re-read with the list frame (at most once a second) instead of on every 12 Hz poll and click.
    private(set) var orientation: Orientation = .bottom
    private var magnificationReach: CGFloat = 0
    /// Auto-hidden Dock: the Dock counts as "there" only after the pointer has touched the screen edge, the Dock
    /// had time to slide in, and the pointer hasn't left the Dock area since.
    private(set) var autohide = false
    private var revealDelay: Double = 0.5
    private var revealedAt: Date?
    private var lastOnScreenFrame: CGRect = .zero

    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 1.0 else { return }
        lastRefresh = Date()
        let d = UserDefaults(suiteName: "com.apple.dock")
        orientation = Self.orientation(d?.string(forKey: "orientation"))
        autohide = d?.bool(forKey: "autohide") ?? false
        // Reveal delay plus the slide-in animation (both tunable with `defaults write com.apple.dock …`).
        let delay = d?.object(forKey: "autohide-delay") as? Double ?? 0.5
        let anim = d?.object(forKey: "autohide-time-modifier") as? Double ?? 0.5
        revealDelay = Self.revealDelay(delay: delay, animation: anim)
        if !autohide { revealedAt = nil }
        magnificationReach = Self.magnificationReach(magnification: d?.bool(forKey: "magnification") ?? false,
                                                     tileSize: d?.double(forKey: "tilesize") ?? 0,
                                                     largeSize: d?.double(forKey: "largesize") ?? 0)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        if dockPID != app.processIdentifier || dock == nil {
            dockPID = app.processIdentifier
            let el = AXUIElementCreateApplication(dockPID)
            AXUIElementSetMessagingTimeout(el, 0.25)
            dock = el
        }
        guard let dock else { return }
        if let list = AX.elements(dock, kAXChildrenAttribute).first(where: { AX.string($0, kAXRoleAttribute) == "AXList" }),
           let f = AX.frame(list) {
            listFrame = f
            if Self.isOnScreen(f) { lastOnScreenFrame = f }
        }
    }

    static func magnificationReach(magnification: Bool, tileSize: Double, largeSize: Double) -> CGFloat {
        guard magnification else { return 0 }
        return CGFloat(max((largeSize > 0 ? largeSize : 128) - (tileSize > 0 ? tileSize : 64), 0))
    }

    /// Cheap pre-check so we don't query Accessibility on every poll. With Dock magnification the hovered icon
    /// grows well beyond the Dock strip, so the region reaches out by the magnification amount.
    func isNearDock(_ p: CGPoint) -> Bool {
        refresh()
        guard autohide else {
            return Self.isNear(p, listFrame: listFrame, orientation: orientation, magnificationReach: magnificationReach)
        }
        guard let at = revealedAt else { return false }
        return Date().timeIntervalSince(at) >= revealDelay
            && Self.isNear(p, listFrame: frameForHitTest, orientation: orientation, magnificationReach: magnificationReach)
    }

    /// Called from the pointer poll (12 Hz) whatever the preview setting, so Dock clicks work with an auto-hidden
    /// Dock too. Not called from the event tap, which must stay fast.
    func track(_ p: CGPoint) {
        refresh()
        guard autohide else { return }
        let atEdge = Self.touchesEdge(p, screen: dockScreenBounds, orientation: orientation)
        let inDock = Self.isNear(p, listFrame: frameForHitTest, orientation: orientation, magnificationReach: magnificationReach)
        if revealedAt == nil {
            if atEdge { revealedAt = Date() }
        } else if !atEdge && !inDock {
            revealedAt = nil
        } else if Date().timeIntervalSince(revealedAt!) < revealDelay + 0.5 {
            refresh(force: true)                    // follow the Dock while it slides in
        }
    }

    /// The frame to test against: the hidden Dock may report an off-screen frame, so use the last visible one.
    private var frameForHitTest: CGRect { Self.isOnScreen(listFrame) ? listFrame : lastOnScreenFrame }

    private var dockScreenBounds: CGRect {
        let f = frameForHitTest
        if !f.isEmpty {
            var id: CGDirectDisplayID = 0
            var n: UInt32 = 0
            if CGGetDisplaysWithPoint(CGPoint(x: f.midX, y: f.midY), 1, &id, &n) == .success, n > 0 { return CGDisplayBounds(id) }
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    /// Mostly on a display (a magnified Dock can poke past the screen's sides; a hidden one is entirely off it).
    static func isOnScreen(_ f: CGRect) -> Bool { isOnScreen(f, displays: DisplayGeometry.activeIDs().map(CGDisplayBounds)) }

    static func isOnScreen(_ f: CGRect, displays: [CGRect]) -> Bool {
        guard !f.isEmpty else { return false }
        return displays.contains { d in
            let i = d.intersection(f)
            return !i.isNull && i.width * i.height >= f.width * f.height * 0.85
        }
    }

    static func revealDelay(delay: Double, animation: Double) -> Double {
        let d = delay.isFinite ? min(max(delay, 0), 5) : 0.5
        let a = animation.isFinite ? min(max(animation, 0), 5) : 0.5
        return d + a * 0.5
    }

    /// The pointer is pressed against the edge the Dock hides behind.
    static func touchesEdge(_ p: CGPoint, screen b: CGRect, orientation: Orientation) -> Bool {
        guard p.y >= b.minY - 1, p.y <= b.maxY + 1, p.x >= b.minX - 1, p.x <= b.maxX + 1 else { return false }
        switch orientation {
        case .bottom: return p.y >= b.maxY - 3
        case .left:   return p.x <= b.minX + 2
        case .right:  return p.x >= b.maxX - 3
        }
    }

    static func isNear(_ p: CGPoint, listFrame: CGRect, orientation: Orientation, magnificationReach: CGFloat) -> Bool {
        // Before the Dock's frame is known, an empty rect would turn the screen's top-left corner into a "Dock".
        guard !listFrame.isEmpty else { return false }
        var r = listFrame.insetBy(dx: -8, dy: -8)
        let reach = magnificationReach + 16
        switch orientation {
        case .bottom: r.origin.y -= reach; r.size.height += reach
        case .left:   r.size.width += reach
        case .right:  r.origin.x -= reach; r.size.width += reach
        }
        return r.contains(p)
    }

    func item(at p: CGPoint) -> DockItem? {
        refresh()
        guard let dock else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(p.x), Float(p.y), &hit) == .success, let el = hit,
              AX.string(el, kAXRoleAttribute) == "AXDockItem",
              AX.string(el, kAXSubroleAttribute) == "AXApplicationDockItem",
              AX.bool(el, "AXIsApplicationRunning") ?? false,
              let url = AX.value(el, "AXURL") as? URL,
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0.activationPolicy == .regular }),
              let frame = AX.frame(el) else { return nil }
        return DockItem(app: app, title: AX.string(el, kAXTitleAttribute) ?? app.localizedName ?? "", frame: frame)
    }

    enum Orientation { case bottom, left, right }
    static func orientation(_ value: String?) -> Orientation {
        switch value {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }
}

extension CGRect {
    /// Converts a global top-left-origin rect (CGEvent/AX space) to Cocoa's bottom-left-origin space.
    var cocoaRect: CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: h - maxY, width: width, height: height)
    }
}
