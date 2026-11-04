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

    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 1.0 else { return }
        lastRefresh = Date()
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

    /// Cheap pre-check so we don't query Accessibility on every mouse move.
    func isNearDock(_ p: CGPoint) -> Bool {
        refresh()
        return listFrame.insetBy(dx: -8, dy: -8).contains(p)
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
    var orientation: Orientation {
        switch UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") {
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
