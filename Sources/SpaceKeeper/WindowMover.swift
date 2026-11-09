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
    private(set) var busy = false

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
        case interrupted = "Move cancelled or modifier keys are still held"
        case fullScreen = "Full-screen windows can't be sent to another desktop"
        case minimized = "Minimized windows can't be moved; restore it first"
        case targetFullScreen = "The other display is showing a full-screen app"
    }

    /// An absolute desktop number (1-based) or a relative step (-1 / +1) on the window's display; a desktop on a
    /// given display (desktop 0 = whatever that display shows now); or the next display's current desktop.
    enum Target: Equatable { case desktop(Int), relative(Int), display(String, Int), nextDisplay }

    func moveFocusedWindow(of app: NSRunningApplication?, to target: Target) async -> Failure? {
        guard AXIsProcessTrusted() else { return .noAccess }
        guard let app, let ax = Windows.focused(of: app), let wid = AX.windowID(ax) else { return .noWindow }
        return await move(ax: ax, wid: wid, pid: app.processIdentifier, to: target)
    }

    /// Move several windows one after another. Each trip returns to this desktop so the next window can be picked
    /// up; only the last one honours "Follow window".
    func moveAll(_ wins: [Win], to target: Target) async -> (moved: Int, failures: [Failure]) {
        var moved = 0
        var failures: [Failure] = []
        for (i, w) in wins.enumerated() {
            guard !Task.isCancelled else { break }
            let last = i == wins.count - 1
            if let f = await move(ax: w.ax, wid: w.id, pid: w.pid, to: target, follow: last ? nil : false) {
                failures.append(f)
                if f == .badDesktop || f == .noAccess || f == .interrupted { break }
            } else {
                moved += 1
            }
        }
        return (moved, failures)
    }

    /// Where a target lands: the destination display, its index in Mission Control, and that display's index now.
    struct Plan: Equatable { let display: String; let to: Int; let from: Int; var crossDisplay: Bool }

    static func plan(source: DisplaySpaces, displays: [DisplaySpaces], target: Target) -> Result<Plan, Failure> {
        guard let from = source.currentIndex else { return .failure(.notHere) }
        func same(_ to: Int?) -> Result<Plan, Failure> {
            to.map { .success(Plan(display: source.uuid, to: $0, from: from, crossDisplay: false)) } ?? .failure(.badDesktop)
        }
        let other: DisplaySpaces
        let desktop: Int
        switch target {
        case .desktop(let n): return same(source.destinationIndex(desktop: n))
        case .relative(let delta): return same(source.destinationIndex(relative: delta))
        case .display(let uuid, let n):
            if uuid == source.uuid { return n == 0 ? same(from) : same(source.destinationIndex(desktop: n)) }
            guard let d = displays.first(where: { $0.uuid == uuid }) else { return .failure(.badDesktop) }
            other = d; desktop = n
        case .nextDisplay:
            guard displays.count > 1, let i = displays.firstIndex(where: { $0.uuid == source.uuid }) else { return .failure(.badDesktop) }
            other = displays[(i + 1) % displays.count]; desktop = 0
        }
        // The window is dropped onto whatever the other display shows, so that must be a regular desktop.
        guard other.currentDesktopNumber != nil, let otherFrom = other.currentIndex else { return .failure(.targetFullScreen) }
        guard let to = desktop == 0 ? otherFrom : other.index(ofDesktop: desktop) else { return .failure(.badDesktop) }
        return .success(Plan(display: other.uuid, to: to, from: otherFrom, crossDisplay: true))
    }

    /// `follow` overrides the "Follow window to its new desktop" setting for this move.
    func move(ax: AXUIElement, wid: CGWindowID, pid: pid_t, to target: Target, follow: Bool? = nil) async -> Failure? {
        guard AXIsProcessTrusted() else { return .noAccess }
        guard !busy else { return .busy }

        let winSpaces = Spaces.spaces(of: wid)
        guard winSpaces.count == 1 else { return winSpaces.isEmpty ? .notHere : .allDesktops }
        let displays = Spaces.displays()
        guard let display = displays.first(where: { $0.current == winSpaces[0] }) else { return .notHere }
        // A full-screen window lives on its own Space; it has no title bar to carry across.
        guard display.currentDesktopNumber != nil, AX.bool(ax, "AXFullScreen") != true else { return .fullScreen }
        guard AX.bool(ax, kAXMinimizedAttribute) != true else { return .minimized }

        let plan: Plan
        switch Self.plan(source: display, displays: displays, target: target) {
        case .failure(let f): return f
        case .success(let p): plan = p
        }
        let steps = plan.to - plan.from
        if steps == 0 && !plan.crossDisplay { return nil }
        guard let destDisplay = displays.first(where: { $0.uuid == plan.display }) else { return .badDesktop }
        let targetID = destDisplay.spaces[plan.to].id
        let dropBounds = plan.crossDisplay ? DisplayGeometry.bounds(forUUID: plan.display) : nil
        if plan.crossDisplay && dropBounds == nil { return .badDesktop }

        busy = true
        defer { busy = false }

        guard await waitForModifierRelease(), !Task.isCancelled else { return .interrupted }
        guard Spaces.spaces(of: wid) == winSpaces,
              Spaces.displays().first(where: { $0.uuid == display.uuid })?.current == display.current else { return .notHere }
        guard let startFrame = AX.frame(ax), startFrame.width > 0, startFrame.height > 0 else { return .notGrabbed }
        let grab = grabPoint(window: ax, pid: pid)
        var onTop = false
        for _ in 0..<4 {
            await raise(ax: ax, pid: pid)
            if topmostWindow(at: grab) == wid { onTop = true; break }
        }
        guard !Task.isCancelled else { return .interrupted }
        guard onTop else { return .covered }
        let originalMouse = CGEvent(source: nil)?.location ?? grab
        let direction: CGKeyCode = steps > 0 ? 124 : 123          // → / ←

        var holdingMouse = false
        defer {
            if holdingMouse {
                postMouse(.leftMouseUp, at: lastMouse)
                CGWarpMouseCursorPosition(originalMouse)
            }
        }

        // 1. Pick the window up by its title bar.
        postMouse(.leftMouseDown, at: grab)
        holdingMouse = true
        await sleep(0.06)
        for i in 1...6 {
            guard !Task.isCancelled else { return .interrupted }
            postMouse(.leftMouseDragged, at: CGPoint(x: grab.x + Double(i) * 10, y: grab.y))
            await sleep(0.03)
        }
        let grabbed = await waitUntil(timeout: 0.6) {
            Self.didFollowDrag(from: startFrame, to: AX.frame(ax))
        }
        if !grabbed {
            // Window didn't follow the pointer: release and bail out before touching any Spaces.
            postMouse(.leftMouseUp, at: CGPoint(x: grab.x + 60, y: grab.y))
            holdingMouse = false
            await sleep(0.1)
            CGWarpMouseCursorPosition(originalMouse)
            return .notGrabbed
        }

        // 2. To another display: carry it across the screen edge onto that display's current desktop.
        var hold = CGPoint(x: grab.x + 60, y: grab.y)
        if let b = dropBounds {
            let drop = CGPoint(x: b.midX, y: b.minY + 60)
            let n = 24
            for i in 1...n {
                guard !Task.isCancelled else { return .interrupted }
                let t = Double(i) / Double(n)
                postMouse(.leftMouseDragged, at: CGPoint(x: hold.x + (drop.x - hold.x) * t, y: hold.y + (drop.y - hold.y) * t))
                await sleep(0.02)
            }
            hold = drop
            await sleep(0.25)
        }

        // 3. Carry it across the Spaces (Ctrl+arrow acts on the display under the pointer).
        for _ in 0..<abs(steps) {
            guard !Task.isCancelled else { return .interrupted }
            postKey(direction)
            await sleep(0.95)
            postMouse(.leftMouseDragged, at: hold)
        }

        // 4. Put it down.
        for i in stride(from: 5, through: 0, by: -1) {
            postMouse(.leftMouseDragged, at: CGPoint(x: hold.x - 60 + Double(i) * 10 + 10, y: hold.y))
            await sleep(0.03)
        }
        await sleep(0.1)
        postMouse(.leftMouseUp, at: lastMouse)
        holdingMouse = false
        await sleep(0.45)

        // 5. Return to where the user was — always after a failed move (otherwise the user is left on a desktop
        //    without the window), and after a successful one unless "Follow window" is on. The pointer stays on the
        //    destination display until then: Ctrl+arrow switches the display under the pointer.
        let moved = await waitUntil { Spaces.spaces(of: wid) == [targetID] }
        if !moved || !(follow ?? Prefs.followWindow) {
            // Count from where the display actually is, not from `steps`: a dropped key press or an interrupted
            // transition would otherwise overshoot.
            let now = Spaces.displays().first(where: { $0.uuid == plan.display })?.currentIndex
            let backSteps = Self.returnSteps(currentIndex: now, origin: plan.from, expected: steps)
            for _ in 0..<abs(backSteps) {
                guard !Task.isCancelled else { CGWarpMouseCursorPosition(originalMouse); return .interrupted }
                postKey(backSteps > 0 ? 123 : 124)
                await sleep(0.95)
            }
        }
        CGWarpMouseCursorPosition(originalMouse)
        return moved ? nil : .failed
    }

    /// Show "Desktop N" on a display (the pointer is parked on that display while switching, then put back).
    @discardableResult
    func switchTo(desktop n: Int, display uuid: String) async -> Bool {
        guard let d = Spaces.displays().first(where: { $0.uuid == uuid }),
              let to = d.index(ofDesktop: n), let from = d.currentIndex else { return false }
        if to == from { return true }
        guard !busy, await waitForModifierRelease() else { return false }
        let original = CGEvent(source: nil)?.location
        if let b = DisplayGeometry.bounds(forUUID: uuid), let p = original, !b.contains(p) {
            CGWarpMouseCursorPosition(CGPoint(x: b.midX, y: b.midY))
        }
        await switchSpaces(by: to - from)
        if let p = original { CGWarpMouseCursorPosition(p) }
        return Spaces.displays().first(where: { $0.uuid == uuid })?.current == d.spaces[to].id
    }

    /// Switch the visible Space by `steps` (negative = left). Used by the debug channel.
    func switchSpaces(by steps: Int) async {
        guard !busy, (-100...100).contains(steps) else { return }
        busy = true
        defer { busy = false }
        for _ in 0..<abs(steps) {
            guard !Task.isCancelled else { return }
            postKey(steps > 0 ? 124 : 123)
            await sleep(0.95)
        }
    }

    // MARK: - Event helpers

    /// Arrow presses needed to get back to `origin` (positive = press ←). Falls back to the planned step count
    /// when the display can't be read.
    static func returnSteps(currentIndex: Int?, origin: Int, expected: Int) -> Int {
        guard let currentIndex else { return expected }
        return currentIndex - origin
    }

    static func didFollowDrag(from start: CGRect?, to current: CGRect?) -> Bool {
        guard let start, let current else { return false }
        return abs(current.minX - start.minX) >= 2
    }

    /// ID of the front-most normal window containing `p` (global top-left coordinates).
    func topmostWindow(at p: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 && ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0 {
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

    func sleep(_ s: Double) async {
        guard s.isFinite, s > 0, s <= 60 else { return }
        try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }

    private func waitUntil(timeout: Double = 1.5, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            guard !Task.isCancelled else { return false }
            if cond() { return true }
            await sleep(0.1)
        }
        return cond()
    }

    /// Hotkeys are pressed with ⌃⌥⌘ held; synthetic arrows must not inherit those modifiers.
    private func waitForModifierRelease() async -> Bool {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let end = Date().addingTimeInterval(2)
        while Date() < end,
              !CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty {
            guard !Task.isCancelled else { return false }
            await sleep(0.05)
        }
        await sleep(0.05)
        return CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty
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
