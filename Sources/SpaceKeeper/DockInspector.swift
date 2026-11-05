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

    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 1.0 else { return }
        lastRefresh = Date()
        let d = UserDefaults(suiteName: "com.apple.dock")
        orientation = Self.orientation(d?.string(forKey: "orientation"))
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
        return Self.isNear(p, listFrame: listFrame, orientation: orientation, magnificationReach: magnificationReach)
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
