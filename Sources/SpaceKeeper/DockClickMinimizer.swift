import Cocoa
import ApplicationServices

/// Takes over left-clicks on running apps' Dock icons so they behave per desktop:
///  • frontmost app with windows here  → minimize them
///  • app whose windows here are all minimized → restore them (no jump to another desktop)
///  • app with no window on this desktop → open a new window right here (no jump)
///  • app not frontmost, windows here and elsewhere → raise the ones here (no jump)
/// Everything else (not running, no "New Window" menu, modifier-clicks, drags) is left to the Dock.
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
    private var pending: Action?

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
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil; swallowing = false; pending = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return pass }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .leftMouseDown:
            swallowing = false
            pending = nil
            let plain = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
            let p = event.location
            guard plain, DockInspector.shared.isNearDock(p), let item = DockInspector.shared.item(at: p) else { return pass }
            guard let action = decide(for: item.app) else { return pass }
            swallowing = true
            pressPoint = p
            pending = action
            return nil

        case .leftMouseDragged:
            // The user is dragging the icon (reordering): replay the swallowed press, then this drag, and step aside.
            if swallowing, hypot(event.location.x - pressPoint.x, event.location.y - pressPoint.y) > 5 {
                swallowing = false
                pending = nil
                dbg("drag detected -> replaying press so the Dock can reorder")
                for (t, loc) in [(CGEventType.leftMouseDown, pressPoint), (.leftMouseDragged, event.location)] {
                    let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: t, mouseCursorPosition: loc, mouseButton: .left)
                    e?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                    e?.setIntegerValueField(.mouseEventClickState, value: 1)
                    e?.flags = []
                    e?.post(tap: .cghidEventTap)
                }
                return nil
            }
            return swallowing ? nil : pass

        case .leftMouseUp:
            guard swallowing, let action = pending else { swallowing = false; return pass }
            swallowing = false
            pending = nil
            DispatchQueue.main.async { self.perform(action) }
            return nil

        default:
            return pass
        }
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

    private func perform(_ action: Action) {
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
            Windows.bringForward(app, [])
        }
    }
}
