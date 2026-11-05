import Cocoa
import ApplicationServices

/// Takes over left-clicks on running apps' Dock icons so they behave per desktop:
///  • frontmost app with windows here  → minimize them
///  • app whose windows here are all minimized → restore them (no jump to another desktop)
///  • app with no window on this desktop → open a new window right here (no jump)
///  • app not frontmost, windows here and elsewhere → raise the ones here (no jump)
/// Anything else is handed back to the Dock by re-sending the click.
///
/// Design note: the event-tap callback must return quickly or macOS disables the tap (and the click then falls
/// through to the stock behavior, including the jump to another desktop). So the callback only does a cheap
/// Dock hit-test and swallows the click; all the slow Accessibility work happens afterwards, on mouse-up.
final class DockClickMinimizer {
    private enum Action {
        case minimize([Win])
        case restore(NSRunningApplication, [Win])
        case raise(NSRunningApplication, [Win])
        case newWindow(NSRunningApplication, AXUIElement)
    }

    /// Tags the events we re-post ourselves so the tap lets them through untouched.
    private static let marker: Int64 = 0x5350414B

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowing = false
    private var pressPoint = CGPoint.zero
    private var pressedApp: NSRunningApplication?
    private var requestID = UUID()

    /// Called whenever we handle a click ourselves (the preview card should disappear).
    var onHandled: () -> Void = {}

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<DockClickMinimizer>.fromOpaque(info).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func stop() {
        requestID = UUID()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil; swallowing = false; pressedApp = nil
    }

    // MARK: Event tap (must stay fast)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return pass }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if swallowing { swallowing = false; pressedApp = nil; replayClick(at: pressPoint, up: true) }  // never leave a half-click
            return pass

        case .leftMouseDown:
            requestID = UUID()
            swallowing = false
            pressedApp = nil
            let plain = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
            let p = event.location
            guard plain, DockInspector.shared.isNearDock(p), let item = DockInspector.shared.item(at: p) else { return pass }
            swallowing = true
            pressPoint = p
            pressedApp = item.app
            return nil

        case .leftMouseDragged:
            // The user is dragging the icon (reordering): replay the swallowed press, then this drag, and step aside.
            if swallowing, hypot(event.location.x - pressPoint.x, event.location.y - pressPoint.y) > 5 {
                swallowing = false
                pressedApp = nil
                post(.leftMouseDown, at: pressPoint)
                post(.leftMouseDragged, at: event.location)
                return nil
            }
            return swallowing ? nil : pass

        case .leftMouseUp:
            guard swallowing, let app = pressedApp else { swallowing = false; return pass }
            swallowing = false
            pressedApp = nil
            let p = pressPoint
            let request = requestID
            let spaces = Spaces.currentIDs()
            DispatchQueue.main.async {
                guard self.isCurrent(request, spaces: spaces, app: app) else { return }
                self.resolve(app, at: p, request: request, spaces: spaces)
            }
            return nil

        default:
            return pass
        }
    }

    // MARK: Decision (slow work is fine here)

    private func isCurrent(_ request: UUID, spaces: Set<Int>, app: NSRunningApplication) -> Bool {
        requestID == request && tap != nil && !app.isTerminated && Spaces.currentIDs() == spaces
    }

    private func resolve(_ app: NSRunningApplication, at point: CGPoint, request: UUID, spaces: Set<Int>) {
        let action = decide(for: app)
        guard isCurrent(request, spaces: spaces, app: app) else { return }
        guard let action else {
            dbg("\(app.localizedName ?? "?"): not handled -> click handed back to the Dock")
            replayClick(at: point, up: true)
            return
        }
        onHandled()
        perform(action, app: app, point: point, request: request, spaces: spaces)
    }

    private func decide(for app: NSRunningApplication) -> Action? {
        let here = Windows.ofApp(app)                                   // this desktop, incl. minimized
        let visible = here.filter { !$0.minimized }
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        let name = app.localizedName ?? "?"

        let minimizable = visible.filter { !$0.fullScreen }
        if isFront, Prefs.clickToMinimize, !minimizable.isEmpty {
            dbg("\(name): minimize \(minimizable.count)")
            return .minimize(minimizable)
        }
        if visible.isEmpty && !here.isEmpty {
            dbg("\(name): restore \(here.count) minimized")
            return .restore(app, here)
        }
        if here.isEmpty {
            // Accessibility says "no windows" — double-check with the window server before opening another one.
            if Windows.hasVisibleWindowHere(app) { dbg("\(name): AX empty but window server sees a window -> native"); return nil }
            guard Prefs.openNewWindowHere, let item = Windows.newWindowItem(of: app) else {
                dbg("\(name): nothing here, no New Window item -> native")
                return nil
            }
            dbg("\(name): nothing here -> New Window")
            return .newWindow(app, item)
        }
        if !isFront, Windows.hasWindowsElsewhere(app) {
            dbg("\(name): raise \(visible.count) here")
            return .raise(app, visible)
        }
        return nil
    }

    private func perform(_ action: Action, app: NSRunningApplication, point: CGPoint, request: UUID, spaces: Set<Int>) {
        switch action {
        case .minimize(let ws):
            ws.forEach(Windows.minimize)
        case .restore(let app, let ws):
            ws.forEach { AX.set($0.ax, kAXMinimizedAttribute, kCFBooleanFalse) }
            Windows.bringForward(app, ws)
        case .raise(let app, let ws):
            Windows.bringForward(app, ws)
        case .newWindow(let app, let item):
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            // Activate only once the new window exists on this desktop. Activating earlier lets macOS pick one of
            // the app's windows on another desktop and jump there.
            waitForWindow(of: app, tries: 25, request: request, spaces: spaces) { wins in
                if let wins { Windows.bringForward(app, wins) }
                else { dbg("\(app.localizedName ?? "?"): no window appeared -> click handed back to the Dock"); self.replayClick(at: point, up: true) }
            }
        }
    }

    private func waitForWindow(of app: NSRunningApplication, tries: Int, request: UUID, spaces: Set<Int>, _ done: @escaping ([Win]?) -> Void) {
        // Never replay an old click or activate a window after the user has changed desktop or clicked again.
        guard isCurrent(request, spaces: spaces, app: app) else { return }
        let wins = Windows.ofApp(app).filter { !$0.minimized }
        if !wins.isEmpty { done(wins); return }
        guard tries > 0 else { done(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.waitForWindow(of: app, tries: tries - 1, request: request, spaces: spaces, done) }
    }

    // MARK: Synthetic events (tagged so the tap ignores them)

    private func post(_ type: CGEventType, at p: CGPoint) {
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        e?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
        e?.flags = []
        e?.post(tap: .cghidEventTap)
    }

    /// Hand a click back to the Dock exactly as the user made it.
    private func replayClick(at p: CGPoint, up: Bool) {
        post(.leftMouseDown, at: p)
        if up { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.post(.leftMouseUp, at: p) } }
    }
}
