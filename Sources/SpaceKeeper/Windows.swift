import Cocoa
import ApplicationServices

enum AX {
    static func value(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    static func string(_ el: AXUIElement, _ name: String) -> String? { value(el, name) as? String }
    static func bool(_ el: AXUIElement, _ name: String) -> Bool? { (value(el, name) as? NSNumber)?.boolValue }
    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        (value(el, name) as? [AXUIElement]) ?? []
    }
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv = value(el, kAXPositionAttribute), let sv = value(el, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ v: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, name as CFString, v) == .success
    }
    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }
    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(el, &wid) == .success && wid != 0 ? wid : nil
    }
}

struct Win {
    let id: CGWindowID
    let pid: pid_t
    let ax: AXUIElement
    let title: String
    let minimized: Bool
    let fullScreen: Bool
    let frame: CGRect
    let spaces: [Int]
}

enum Windows {
    /// Standard windows of `app`. With `currentSpaceOnly` (default) only windows that live on a
    /// currently visible Space are returned — including minimized ones.
    static func ofApp(_ app: NSRunningApplication, currentSpaceOnly: Bool = true) -> [Win] {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)
        let current = Spaces.currentIDs()
        var out: [Win] = []
        for w in AX.elements(el, kAXWindowsAttribute) {
            guard AX.string(w, kAXRoleAttribute) == kAXWindowRole,
                  let sub = AX.string(w, kAXSubroleAttribute), sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole,
                  let wid = AX.windowID(w) else { continue }
            let spaces = Spaces.spaces(of: wid)
            if currentSpaceOnly && current.isDisjoint(with: spaces) { continue }
            out.append(Win(
                id: wid, pid: app.processIdentifier, ax: w,
                title: AX.string(w, kAXTitleAttribute) ?? "",
                minimized: AX.bool(w, kAXMinimizedAttribute) ?? false,
                fullScreen: AX.bool(w, "AXFullScreen") ?? false,
                frame: AX.frame(w) ?? .zero,
                spaces: spaces))
        }
        return out
    }

    static func focused(of app: NSRunningApplication) -> AXUIElement? {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)
        return AX.element(el, kAXFocusedWindowAttribute)
            ?? AX.element(el, kAXMainWindowAttribute)
            ?? AX.elements(el, kAXWindowsAttribute).first
    }

    static func focus(_ w: Win, app: NSRunningApplication) {
        if w.minimized { AX.set(w.ax, kAXMinimizedAttribute, kCFBooleanFalse) }
        bringForward(app, [w])
        AX.set(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute, w.ax)
    }

    /// Brings the app to the front using only Accessibility, so macOS never goes looking for the
    /// app's windows on other desktops (which is what makes it jump away).
    static func bringForward(_ app: NSRunningApplication, _ wins: [Win]) {
        if app.isHidden { app.unhide() }
        AX.set(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute, kCFBooleanTrue)
        if let w = wins.first {
            AXUIElementPerformAction(w.ax, kAXRaiseAction as CFString)
            AX.set(w.ax, kAXMainAttribute, kCFBooleanTrue)
        }
    }

    /// True if the window server shows a real, visible window of the app on this desktop. Used as a safety net
    /// when Accessibility returns nothing (a busy app, or one that hides its windows from AX).
    static func hasVisibleWindowHere(_ app: NSRunningApplication) -> Bool {
        let current = Spaces.currentIDs()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: d), b.width >= 120, b.height >= 80 else { continue }
            if !current.isDisjoint(with: Spaces.spaces(of: CGWindowID(id))) { return true }
        }
        return false
    }

    /// True if the app has a real-looking window on a desktop that isn't currently visible.
    static func hasWindowsElsewhere(_ app: NSRunningApplication) -> Bool {
        let current = Spaces.currentIDs()
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: d), b.width >= 200, b.height >= 100 else { continue }
            let sp = Spaces.spaces(of: CGWindowID(id))
            if !sp.isEmpty && current.isDisjoint(with: sp) { return true }
        }
        return false
    }

    static func close(_ w: Win) {
        if let btn = AX.element(w.ax, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(btn, kAXPressAction as CFString)
        }
    }

    static func minimize(_ w: Win) {
        AX.set(w.ax, kAXMinimizedAttribute, kCFBooleanTrue)
    }

    /// The enabled "New Window"-style item in the app's menu bar, if it has one.
    static func newWindowItem(of app: NSRunningApplication) -> AXUIElement? {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.4)
        guard let bar = AX.element(el, kAXMenuBarAttribute) else { return nil }
        var candidates: [(rank: Int, item: AXUIElement)] = []
        for barItem in AX.elements(bar, kAXChildrenAttribute).dropFirst() {          // skip Apple menu
            for menu in AX.elements(barItem, kAXChildrenAttribute) {
                for item in AX.elements(menu, kAXChildrenAttribute) {
                    guard let title = AX.string(item, kAXTitleAttribute),
                          AX.bool(item, kAXEnabledAttribute) ?? true else { continue }
                    if title == "New Window" { candidates.append((0, item)) }
                    else if title.hasPrefix("New") && title.hasSuffix("Window") { candidates.append((1, item)) }
                    else if title == "New" || title == "New Document" { candidates.append((2, item)) }   // document apps, e.g. TextEdit
                }
            }
        }
        return candidates.min(by: { $0.rank < $1.rank })?.item
    }
}
