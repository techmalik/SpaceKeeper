import Cocoa

/// Optional local control channel used for testing. Disabled unless
/// `defaults write com.malikkabir.SpaceKeeper debugControl -bool true`.
///
///   echo "status" > ~/Library/Logs/SpaceKeeper/cmd.txt && notifyutil -p com.malikkabir.spacekeeper.cmd
///   → result in ~/Library/Logs/SpaceKeeper/result.txt
func dbg(_ s: String) {
    guard Prefs.debugControl else { return }
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SpaceKeeper/tap.log")
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

final class DebugControl {
    static let shared = DebugControl()
    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SpaceKeeper")

    func startIfEnabled() {
        guard Prefs.debugControl else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        { _, obs, _, _, _ in
                                            guard let obs else { return }
                                            let me = Unmanaged<DebugControl>.fromOpaque(obs).takeUnretainedValue()
                                            DispatchQueue.main.async { Task { @MainActor in await me.run() } }
                                        },
                                        "com.malikkabir.spacekeeper.cmd" as CFString, nil, .deliverImmediately)
    }

    @MainActor
    private func run() async {
        let cmd = ((try? String(contentsOf: dir.appendingPathComponent("cmd.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cmd.split(separator: " ").map(String.init)
        var out = ""
        switch parts.first ?? "" {
        case "status":
            out += "AX trusted: \(AXIsProcessTrusted())  ScreenRecording: \(CGPreflightScreenCaptureAccess())\n"
            out += "left button down? hid=\(CGEventSource.buttonState(.hidSystemState, button: .left)) combined=\(CGEventSource.buttonState(.combinedSessionState, button: .left)) mouse=\(CGEvent(source: nil)?.location ?? .zero)\n"
            out += "tap running: \((NSApp.delegate as? AppDelegate)?.clicker.isRunning ?? false)\n"
            for d in Spaces.displays() {
                out += "display \(d.uuid) current=\(d.current) spaces=\(d.spaces.map { "\($0.id)/t\($0.type)" })\n"
            }
            out += "front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")\n"
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                for w in Windows.ofApp(app, currentSpaceOnly: false) {
                    out += "  [\(app.localizedName ?? "?")] wid=\(w.id) spaces=\(w.spaces) min=\(w.minimized) \"\(w.title)\"\n"
                }
            }
        case "move":      // move <windowID> <desktopN>
            guard parts.count == 3, let wid = UInt32(parts[1]), let n = Int(parts[2]) else { out = "usage: move <wid> <desktop>"; break }
            var found: (Win, NSRunningApplication)?
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                if let w = Windows.ofApp(app).first(where: { $0.id == wid }) { found = (w, app) }
            }
            guard let (w, app) = found else { out = "window not found on current desktop"; break }
            let r = await WindowMover.shared.move(ax: w.ax, wid: w.id, pid: app.processIdentifier, to: .desktop(n))
            out = r.map { "FAILED: \($0.rawValue)" } ?? "OK"
            out += "\nwindow spaces now: \(Spaces.spaces(of: wid))"
        case "drag":      // drag <wid>: grab, drag 120px right, release; report frame before/after
            guard parts.count >= 2, let wid = UInt32(parts[1]) else { out = "usage: drag <wid> [settleSeconds]"; break }
            let settle = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
            var found: (Win, NSRunningApplication)?
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                if let w = Windows.ofApp(app).first(where: { $0.id == wid }) { found = (w, app) }
            }
            guard let (w, app) = found else { out = "window not found"; break }
            let m = WindowMover.shared
            await m.raise(ax: w.ax, pid: app.processIdentifier)
            await m.sleep(settle)
            let before = AX.frame(w.ax) ?? .zero
            let g = m.grabPoint(window: w.ax, pid: app.processIdentifier)
            var hit: AXUIElement?
            AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(app.processIdentifier), Float(g.x), Float(g.y), &hit)
            out = "front after raise: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")\n"
            out += "frame before: \(before)\ngrab: \(g) role: \(hit.flatMap { AX.string($0, kAXRoleAttribute) } ?? "nil")\n"
            if let wl = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
                let tops = wl.filter { w in
                    guard (w[kCGWindowLayer as String] as? Int) == 0, let d = w[kCGWindowBounds as String] as? NSDictionary,
                          let b = CGRect(dictionaryRepresentation: d) else { return false }
                    return b.contains(g)
                }.prefix(3).map { "\($0[kCGWindowOwnerName as String] ?? "?")#\($0[kCGWindowNumber as String] ?? 0)" }
                out += "windows at grab (front first): \(tops)\n"
            }
            m.postMouse(.leftMouseDown, at: g); await m.sleep(0.1)
            for i in 1...10 { m.postMouse(.leftMouseDragged, at: CGPoint(x: g.x + Double(i) * 12, y: g.y)); await m.sleep(0.03) }
            m.postMouse(.leftMouseUp, at: CGPoint(x: g.x + 120, y: g.y)); await m.sleep(0.3)
            out += "frame after: \(AX.frame(w.ax) ?? .zero)"
        case "tap":       // tap on|off
            let c = (NSApp.delegate as? AppDelegate)?.clicker
            if parts.dropFirst().first == "off" { c?.stop() } else { c?.start() }
            out = "tap running: \(c?.isRunning ?? false)"
        case "dockscan":  // list app icons currently in the Dock with their frames
            DockInspector.shared.refresh(force: true)
            let f = DockInspector.shared.listFrame
            out = "dock list frame: \(f)\n"
            var seen = Set<String>()
            var x = f.minX
            while x < f.maxX {
                if let i = DockInspector.shared.item(at: CGPoint(x: x, y: f.midY)), seen.insert(i.app.bundleIdentifier ?? "").inserted {
                    out += "  \(i.app.localizedName ?? "?") center=(\(Int(i.frame.midX)),\(Int(i.frame.midY)))\n"
                }
                x += 10
            }
        case "hover":     // hover <x> <y>
            if parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) {
                let p = CGPoint(x: x, y: y)
                CGWarpMouseCursorPosition(p)
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                out = "hovering \(p)"
            }
        case "click":     // click <x> <y>
            if parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) {
                let p = CGPoint(x: x, y: y)
                CGWarpMouseCursorPosition(p)
                for t in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                    let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: t, mouseCursorPosition: p, mouseButton: .left)
                    e?.setIntegerValueField(.mouseEventClickState, value: 1)
                    e?.post(tap: .cghidEventTap)
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
                out = "clicked \(p)"
            }
        case "showpreview":   // showpreview <x> <y>  (dock icon position)
            if parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) {
                (NSApp.delegate as? AppDelegate)?.preview.debugPinned = true
                out = (NSApp.delegate as? AppDelegate)?.preview.debugShow(at: CGPoint(x: x, y: y)) ?? "no delegate"
            }
        case "cardminimize":  // cardminimize <wid>: same code path as the card's minimize button
            if parts.count == 2, let wid = UInt32(parts[1]) { (NSApp.delegate as? AppDelegate)?.preview.minimize(wid); out = "ok" }
        case "hidepreview":
            (NSApp.delegate as? AppDelegate)?.preview.debugPinned = false
            (NSApp.delegate as? AppDelegate)?.preview.hide(); out = "hidden"
        case "axdump":    // axdump <pid>: every AX window of the process, unfiltered
            if parts.count == 2, let pid = pid_t(parts[1]) {
                let el = AXUIElementCreateApplication(pid)
                for w in AX.elements(el, kAXWindowsAttribute) {
                    let wid = AX.windowID(w).map { "\($0)" } ?? "nil"
                    out += "wid=\(wid) role=\(AX.string(w, kAXRoleAttribute) ?? "-") sub=\(AX.string(w, kAXSubroleAttribute) ?? "-") min=\(AX.bool(w, kAXMinimizedAttribute) ?? false) title=\"\(AX.string(w, kAXTitleAttribute) ?? "")\" spaces=\(AX.windowID(w).map { Spaces.spaces(of: $0) } ?? [])\n"
                }
                if out.isEmpty { out = "no AX windows" }
            }
        case "closewin":  // closewin <wid>: close a window on the current desktop via its close button
            if parts.count == 2, let wid = UInt32(parts[1]) {
                var n = 0
                for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                    if let w = Windows.ofApp(app).first(where: { $0.id == wid }) {
                        Windows.close(w); n += 1
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        for sheet in AX.elements(w.ax, kAXChildrenAttribute) where AX.string(sheet, kAXRoleAttribute) == "AXSheet" {
                            for b in AX.elements(sheet, kAXChildrenAttribute) where ["Delete", "Don\u{2019}t Save", "Don't Save"].contains(AX.string(b, kAXTitleAttribute) ?? "") {
                                AXUIElementPerformAction(b, kAXPressAction as CFString)
                            }
                        }
                    }
                }
                out = "closed \(n)"
            }
        case "flags":
            out = "hid=\(String(CGEventSource.flagsState(.hidSystemState).rawValue, radix: 16)) combined=\(String(CGEventSource.flagsState(.combinedSessionState).rawValue, radix: 16)) session=\(String(CGEventSource.flagsState(.combinedSessionState).rawValue, radix: 16))"
        case "unmin":     // unmin <bundleID>: un-minimize all standard windows of the app on this desktop
            if let id = parts.dropFirst().first, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                let ws = Windows.ofApp(app)
                ws.forEach { AX.set($0.ax, kAXMinimizedAttribute, kCFBooleanFalse) }
                out = "unminimized \(ws.count)"
            }
        case "feedback":
            FeedbackWindowController.shared.show(); out = "feedback window shown"
        case "feedbacksend":   // feedbacksend <text...>: send through the real code path (with a generated screenshot)
            let img = NSImage(size: NSSize(width: 2400, height: 1400), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
            do {
                try await FeedbackSender.send(kind: .bug, message: parts.dropFirst().joined(separator: " "), replyTo: "tester@example.com",
                                              includeSystemInfo: true, screenshot: FeedbackSender.jpegData(from: img))
                out = "sent OK"
            } catch { out = "FAILED: \(error.localizedDescription)" }
        case "about":
            AboutWindowController.shared.show(); out = "about shown"
        case "dockdrag":  // dockdrag <x> <y> <dx>: press on a Dock icon, drag dx px horizontally, release
            if parts.count == 4, let x = Double(parts[1]), let y = Double(parts[2]), let dx = Double(parts[3]),
               x.isFinite, y.isFinite, dx.isFinite, abs(dx) <= 10_000 {
                func post(_ t: CGEventType, _ px: Double) {
                    let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: t, mouseCursorPosition: CGPoint(x: px, y: y), mouseButton: .left)
                    e?.flags = []
                    e?.post(tap: .cghidEventTap)
                }
                CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
                post(.mouseMoved, x); try? await Task.sleep(nanoseconds: 100_000_000)
                post(.leftMouseDown, x); try? await Task.sleep(nanoseconds: 150_000_000)
                for i in 1...20 { post(.leftMouseDragged, x + dx * Double(i) / 20); try? await Task.sleep(nanoseconds: 40_000_000) }
                try? await Task.sleep(nanoseconds: 300_000_000)
                post(.leftMouseUp, x + dx)
                out = "dragged \(dx)px"
            }
        case "glide":     // glide <x> <y> <seconds>: move the pointer smoothly (for demos)
            if parts.count == 4, let x = Double(parts[1]), let y = Double(parts[2]), let secs = Double(parts[3]),
               x.isFinite, y.isFinite, secs.isFinite, secs > 0, secs <= 60 {
                let start = CGEvent(source: nil)?.location ?? .zero
                let steps = max(20, Int(secs * 60))
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                    let p = CGPoint(x: start.x + (x - start.x) * e, y: start.y + (y - start.y) * e)
                    CGWarpMouseCursorPosition(p)
                    let ev = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
                    ev?.flags = []
                    ev?.post(tap: .cghidEventTap)
                    try? await Task.sleep(nanoseconds: UInt64(secs / Double(steps) * 1_000_000_000))
                }
                out = "glided"
            }
        case "settext":   // settext <text...>: set the text of the front app's focused window (demo only)
            if let app = NSWorkspace.shared.frontmostApplication, let win = Windows.focused(of: app) {
                func area(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
                    if AX.string(el, kAXRoleAttribute) == "AXTextArea" { return el }
                    guard depth > 0 else { return nil }
                    for c in AX.elements(el, kAXChildrenAttribute) { if let f = area(c, depth - 1) { return f } }
                    return nil
                }
                let text = parts.dropFirst().joined(separator: " ")
                out = area(win, 5).map { AX.set($0, kAXValueAttribute, text as CFString) ? "set" : "failed" } ?? "no text area"
            }
        case "audit":     // compare Accessibility's window list with the window server's, per app, on this desktop
            let cur = Spaces.currentIDs()
            guard let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { break }
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let cg = all.filter { w in
                    guard (w[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier), (w[kCGWindowLayer as String] as? Int) == 0,
                          let id = w[kCGWindowNumber as String] as? Int,
                          let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d), b.width >= 120, b.height >= 80 else { return false }
                    return !cur.isDisjoint(with: Spaces.spaces(of: CGWindowID(id)))
                }
                let el = AXUIElementCreateApplication(app.processIdentifier)
                let axAll = AX.elements(el, kAXWindowsAttribute)
                let subs = axAll.map { "\(AX.string($0, kAXSubroleAttribute) ?? "nil")" }
                let mine = Windows.ofApp(app).count
                let flag = (cg.count != mine) ? "  <-- MISMATCH" : ""
                if cg.count != mine {
                    for w in cg {
                        let id = w[kCGWindowNumber as String] as? Int ?? 0
                        let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
                        let inAX = axAll.contains { AX.windowID($0) == CGWindowID(id) }
                        out += "    cg wid=\(id) \(Int(b.width))x\(Int(b.height)) onscreen=\(w[kCGWindowIsOnscreen as String] ?? false) alpha=\(w[kCGWindowAlpha as String] ?? "?") inAX=\(inAX) title=\"\((w[kCGWindowName as String] as? String) ?? "")\"\n"
                    }
                }
                if !cg.isEmpty || mine > 0 { out += "\(app.localizedName ?? "?"): windowServer=\(cg.count) ours=\(mine) ax=\(axAll.count) subroles=\(subs)\(flag)\n" }
            }
        case "switch":    // switch <steps>
            await WindowMover.shared.switchSpaces(by: Int(parts.dropFirst().first ?? "0") ?? 0)
            out = "current: \(Spaces.currentIDs())"
        case "dockhit":   // dockhit <x> <y>
            if parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) {
                let i = DockInspector.shared.item(at: CGPoint(x: x, y: y))
                out = i.map { "dock item: \($0.app.localizedName ?? "?") frame=\($0.frame)" } ?? "no app item at point; dock list frame=\(DockInspector.shared.listFrame)"
            }
        default:
            out = "unknown command: \(cmd)"
        }
        try? out.write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }
}
