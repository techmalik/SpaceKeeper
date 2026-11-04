import Cocoa
import ApplicationServices

/// Moves a window to another Space.
///
/// macOS 14.5+ silently ignores the private "move window to Space" calls from normal apps, so we
/// do what a person does: grab the window's title bar, press the Mission Control shortcut
/// (Ctrl+←/→) to travel to the target Space while holding the window, then let go.
/// Requires: Accessibility permission, and "Move left/right a space" shortcuts enabled
/// (System Settings → Keyboard → Keyboard Shortcuts → Mission Control; they are on by default).
@MainActor
final class WindowMover {
    static let shared = WindowMover()
    private var busy = false

    enum Failure: String, Error {
        case noAccess = "Accessibility permission is missing"
        case noWindow = "No movable window is in front"
        case busy = "Another move is in progress"
        case badDesktop = "That desktop doesn't exist"
        case notHere = "The window isn't on the current desktop"
        case allDesktops = "That window is set to appear on all desktops"
        case covered = "Another window is covering this window's title bar"
        case notGrabbed = "Couldn't grab the window's title bar"
        case failed = "macOS didn't accept the move"
    }

    /// Target is either an absolute desktop number (1-based) or a relative step (-1 / +1).
    enum Target { case desktop(Int), relative(Int) }

    func moveFocusedWindow(of app: NSRunningApplication?, to target: Target) async -> Failure? {
        guard AXIsProcessTrusted() else { return .noAccess }
        guard let app, let ax = Windows.focused(of: app), let wid = AX.windowID(ax) else { return .noWindow }
        return await move(ax: ax, wid: wid, pid: app.processIdentifier, to: target)
    }

    func move(ax: AXUIElement, wid: CGWindowID, pid: pid_t, to target: Target) async -> Failure? {
        guard AXIsProcessTrusted() else { return .noAccess }
        guard !busy else { return .busy }

        let winSpaces = Spaces.spaces(of: wid)
        guard winSpaces.count == 1 else { return winSpaces.isEmpty ? .notHere : .allDesktops }
        guard let display = Spaces.displays().first(where: { $0.current == winSpaces[0] }),
              let from = display.currentIndex else { return .notHere }

        let to: Int
        switch target {
        case .desktop(let n):
            guard n >= 1, n <= display.userSpaces.count,
                  let idx = display.spaces.firstIndex(where: { $0.id == display.userSpaces[n - 1].id }) else { return .badDesktop }
            to = idx
        case .relative(let delta):
            to = from + delta
            guard to >= 0, to < display.spaces.count else { return .badDesktop }
        }
        let steps = to - from
        if steps == 0 { return nil }
        let targetID = display.spaces[to].id

        busy = true
        defer { busy = false }

        await waitForModifierRelease()
        let grab = grabPoint(window: ax, pid: pid)
        var onTop = false
        for _ in 0..<4 {
            await raise(ax: ax, pid: pid)
            if topmostWindow(at: grab) == wid { onTop = true; break }
        }
        guard onTop else { return .covered }
        let originalMouse = CGEvent(source: nil)?.location ?? grab
        let direction: CGKeyCode = steps > 0 ? 124 : 123          // → / ←
        let back: CGKeyCode = steps > 0 ? 123 : 124

        // 1. Pick the window up by its title bar.
        postMouse(.leftMouseDown, at: grab)
        await sleep(0.06)
        let startFrame = AX.frame(ax)
        for i in 1...6 {
            postMouse(.leftMouseDragged, at: CGPoint(x: grab.x + Double(i) * 10, y: grab.y))
            await sleep(0.03)
        }
        let grabbed = await waitUntil(timeout: 0.6) {
            guard let startFrame, let now = AX.frame(ax) else { return true }
            return abs(now.minX - startFrame.minX) >= 2
        }
        if !grabbed {
            // Window didn't follow the pointer: release and bail out before touching any Spaces.
            postMouse(.leftMouseUp, at: CGPoint(x: grab.x + 60, y: grab.y))
            await sleep(0.1)
            CGWarpMouseCursorPosition(originalMouse)
            return .notGrabbed
        }

        // 2. Carry it across the Spaces.
        for _ in 0..<abs(steps) {
            postKey(direction)
            await sleep(0.95)
            postMouse(.leftMouseDragged, at: CGPoint(x: grab.x + 60, y: grab.y))
        }

        // 3. Put it down.
        for i in stride(from: 5, through: 0, by: -1) {
            postMouse(.leftMouseDragged, at: CGPoint(x: grab.x + Double(i) * 10, y: grab.y))
            await sleep(0.03)
        }
        await sleep(0.1)
        postMouse(.leftMouseUp, at: grab)
        await sleep(0.45)
        CGWarpMouseCursorPosition(originalMouse)

        // 4. Optionally return to where the user was.
        let moved = await waitUntil { Spaces.spaces(of: wid) == [targetID] }
        if moved && !Prefs.followWindow {
            for _ in 0..<abs(steps) {
                postKey(back)
                await sleep(0.95)
            }
        }
        return moved ? nil : .failed
    }

    /// Switch the visible Space by `steps` (negative = left). Used by the debug channel.
    func switchSpaces(by steps: Int) async {
        for _ in 0..<abs(steps) {
            postKey(steps > 0 ? 124 : 123)
            await sleep(0.95)
        }
    }

    // MARK: - Event helpers

    /// ID of the front-most normal window containing `p` (global top-left coordinates).
    func topmostWindow(at p: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d), b.contains(p) {
                return w[kCGWindowNumber as String] as? CGWindowID
            }
        }
        return nil
    }

    /// Make sure nothing covers the title bar before we click it.
    func raise(ax: AXUIElement, pid: pid_t) async {
        AX.set(AXUIElementCreateApplication(pid), kAXFrontmostAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        await sleep(0.3)
    }

    private var lastMouse = CGPoint.zero

    func postMouse(_ type: CGEventType, at p: CGPoint) {
        if type == .leftMouseDown {
            CGWarpMouseCursorPosition(p)
            CGAssociateMouseAndMouseCursorPosition(1)
            let mv = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
            mv?.post(tap: .cghidEventTap)
            lastMouse = p
        }
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                        mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
        e?.flags = []
        if type == .leftMouseDragged {
            e?.setDoubleValueField(.mouseEventDeltaX, value: Double(p.x - lastMouse.x))
            e?.setDoubleValueField(.mouseEventDeltaY, value: Double(p.y - lastMouse.y))
            lastMouse = p
        }
        e?.post(tap: .cghidEventTap)
    }

    /// Ctrl+arrow. Uses a private event source so the synthetic Control/Fn flags never leak into the
    /// system-wide modifier state (which would make your real clicks behave like Ctrl-clicks).
    private func postKey(_ code: CGKeyCode) {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = [.maskControl, .maskSecondaryFn]
            e?.post(tap: .cghidEventTap)
        }
        clearModifierState()
    }

    /// Belt and braces: release any modifier the system may think is still down.
    private func clearModifierState() {
        let src = CGEventSource(stateID: .hidSystemState)
        for key: CGKeyCode in [59, 62, 63] {      // left ctrl, right ctrl, fn
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
            e?.type = .flagsChanged
            e?.flags = []
            e?.post(tap: .cghidEventTap)
        }
    }

    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private func waitUntil(timeout: Double = 1.5, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await sleep(0.1)
        }
        return cond()
    }

    /// Hotkeys are pressed with ⌃⌥⌘ held; synthetic arrows must not inherit those modifiers.
    private func waitForModifierRelease() async {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let end = Date().addingTimeInterval(2)
        while Date() < end,
              !CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty {
            await sleep(0.05)
        }
        await sleep(0.05)
    }

    // MARK: - Finding a safe place to grab the window

    /// A point on the window's title bar that is draggable (not a button, tab, text field…).
    func grabPoint(window: AXUIElement, pid: pid_t) -> CGPoint {
        guard let f = AX.frame(window) else { return .zero }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AX.set(app, "AXManualAccessibility", kCFBooleanTrue)            // wakes up Chromium/Electron trees
        let ys: [CGFloat] = [4, 8, 12, 16, 20, 26, 34, 44]
        let xs: [CGFloat] = [0.5, 0.42, 0.58, 0.34, 0.66, 0.26, 0.74, 0.18, 0.82]
        for y in ys {
            for x in xs {
                let p = CGPoint(x: f.minX + f.width * x, y: f.minY + y)
                if isDraggable(p, app: app) { return p }
            }
        }
        return CGPoint(x: f.midX, y: f.minY + 12)
    }

    private func isDraggable(_ p: CGPoint, app: AXUIElement) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success, let el = hit else { return false }
        let role = AX.string(el, kAXRoleAttribute) ?? ""
        switch role {
        case "AXWindow", "AXStaticText", "AXToolbar", "AXTabGroup": return true
        case "AXGroup", "AXSplitGroup", "AXUnknown", "AXScrollArea": return AX.actions(el).isEmpty
        default: return false      // buttons, tabs, fields, images (document proxy icon), menus…
        }
    }
}
