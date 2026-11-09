import Cocoa

struct SpaceInfo {
    let id: Int
    let type: Int            // 0 = regular desktop, 4 = full-screen app
    var uuid: String = ""    // persistent across restarts; empty for a display's original desktop
    var isUser: Bool { type == 0 }
}

struct DisplaySpaces {
    let uuid: String
    let current: Int
    let spaces: [SpaceInfo]

    var userSpaces: [SpaceInfo] { spaces.filter(\.isUser) }
    var currentIndex: Int? { spaces.firstIndex { $0.id == current } }
    /// 1-based "Desktop N" number of the current space, if it is a regular desktop.
    var currentDesktopNumber: Int? { desktopNumber(ofSpace: current) }

    func desktopNumber(ofSpace id: Int) -> Int? { userSpaces.firstIndex { $0.id == id }.map { $0 + 1 } }

    /// Position in Mission Control of "Desktop N", regardless of what is showing now.
    func index(ofDesktop n: Int) -> Int? {
        guard n > 0, n <= userSpaces.count else { return nil }
        return spaces.firstIndex { $0.id == userSpaces[n - 1].id }
    }

    /// Resolve a desktop target to its position in Mission Control, counting full-screen Spaces
    /// only when calculating the number of arrow presses, never as a destination.
    func destinationIndex(desktop: Int? = nil, relative: Int = 0) -> Int? {
        guard let currentUser = userSpaces.firstIndex(where: { $0.id == current }) else { return nil }
        let index: Int
        if let desktop {
            guard desktop > 0, desktop <= userSpaces.count else { return nil }
            index = desktop - 1
        } else {
            let (next, overflow) = currentUser.addingReportingOverflow(relative)
            guard !overflow, userSpaces.indices.contains(next) else { return nil }
            index = next
        }
        return spaces.firstIndex { $0.id == userSpaces[index].id }
    }
}

enum Spaces {
    static let cid = CGSMainConnectionID()

    static func displays() -> [DisplaySpaces] {
        guard let arr = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let uuid = d["Display Identifier"] as? String,
                  let cur = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int,
                  let list = d["Spaces"] as? [[String: Any]] else { return nil }
            let spaces = list.compactMap { s -> SpaceInfo? in
                guard let id = s["ManagedSpaceID"] as? Int else { return nil }
                return SpaceInfo(id: id, type: s["type"] as? Int ?? 0, uuid: s["uuid"] as? String ?? "")
            }
            return DisplaySpaces(uuid: uuid, current: cur, spaces: spaces)
        }
    }

    static func currentIDs() -> Set<Int> { Set(displays().map(\.current)) }

    static func spaces(of wid: CGWindowID) -> [Int] {
        (CGSCopySpacesForWindows(cid, 7, [Int(wid)] as CFArray) as? [Int]) ?? []
    }

    /// The display (and its 1-based desktop number) that owns a space.
    static func locate(space: Int, in displays: [DisplaySpaces]) -> (display: DisplaySpaces, desktop: Int)? {
        for d in displays { if let n = d.desktopNumber(ofSpace: space) { return (d, n) } }
        return nil
    }
}

// MARK: - Displays

/// Maps the Spaces "Display Identifier" (a UUID, or "Main" when displays share Spaces) to screens.
enum DisplayGeometry {
    static func activeIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return [CGMainDisplayID()] }
        return Array(ids.prefix(Int(n)))
    }

    static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String?
    }

    static func displayID(forUUID uuid: String) -> CGDirectDisplayID? {
        if uuid == "Main" { return CGMainDisplayID() }
        return activeIDs().first { self.uuid(of: $0)?.caseInsensitiveCompare(uuid) == .orderedSame }
    }

    /// Global top-left-origin bounds (the CGEvent coordinate space).
    static func bounds(forUUID uuid: String) -> CGRect? { displayID(forUUID: uuid).map(CGDisplayBounds) }

    static func uuid(containing p: CGPoint, in displays: [DisplaySpaces]) -> String? {
        if displays.count == 1 { return displays[0].uuid }
        return displays.first { bounds(forUUID: $0.uuid)?.contains(p) == true }?.uuid
    }

    static func screen(forUUID uuid: String) -> NSScreen? {
        guard let id = displayID(forUUID: uuid) else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    static func name(forUUID uuid: String) -> String { screen(forUUID: uuid)?.localizedName ?? "Display" }
}

// MARK: - Desktop names

enum DesktopNames {
    static func key(display: String, space: SpaceInfo) -> String {
        space.uuid.isEmpty ? "\(display)#main" : space.uuid
    }

    static func custom(display: DisplaySpaces, desktop n: Int) -> String? {
        guard n > 0, n <= display.userSpaces.count else { return nil }
        let name = Prefs.desktopNames[key(display: display.uuid, space: display.userSpaces[n - 1])]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty ?? true) ? nil : name
    }

    /// "Desktop 2 — Work", or "Desktop 2" when it has no name.
    static func label(display: DisplaySpaces, desktop n: Int) -> String {
        custom(display: display, desktop: n).map { "Desktop \(n) — \($0)" } ?? "Desktop \(n)"
    }

    /// Just the name if there is one, else "Desktop N" (for the menu bar).
    static func short(display: DisplaySpaces, desktop n: Int) -> String {
        custom(display: display, desktop: n) ?? "Desktop \(n)"
    }

    static func set(_ name: String?, display: DisplaySpaces, desktop n: Int) {
        guard n > 0, n <= display.userSpaces.count else { return }
        var all = Prefs.desktopNames
        let k = key(display: display.uuid, space: display.userSpaces[n - 1])
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { all.removeValue(forKey: k) } else { all[k] = String(trimmed.prefix(40)) }
        Prefs.desktopNames = all
    }
}

// MARK: - Every window on every desktop

/// A window as the window server sees it, on any desktop (Accessibility only sees the current desktop's windows).
struct WindowRef {
    let wid: CGWindowID
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let space: Int
    let bounds: CGRect
}

enum WindowCatalog {
    static func all() -> [WindowRef] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var apps: [pid_t: NSRunningApplication] = [:]
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular { apps[a.processIdentifier] = a }
        var out: [WindowRef] = []
        for w in list {
            guard let pidInt = w[kCGWindowOwnerPID as String] as? Int, pid_t(pidInt) != me, let app = apps[pid_t(pidInt)],
                  let bundleID = app.bundleIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: d), b.width >= 160, b.height >= 100 else { continue }
            let sp = Spaces.spaces(of: CGWindowID(id))
            guard sp.count == 1 else { continue }            // skip "all desktops" and space-less helper windows
            out.append(WindowRef(wid: CGWindowID(id), pid: pid_t(pidInt), bundleID: bundleID,
                                 appName: app.localizedName ?? bundleID,
                                 title: (w[kCGWindowName as String] as? String) ?? "",
                                 space: sp[0], bounds: b))
        }
        return out
    }
}
