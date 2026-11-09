import Cocoa

/// A snapshot of which app windows were on which desktop, so the arrangement can be rebuilt after a restart.
struct SavedLayout: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var bundleID: String
        var appName: String
        var title: String
        var display: String
        var desktop: Int
    }
    var name: String
    var saved: Date
    var entries: [Entry]
}

/// One window to carry somewhere during a restore.
struct LayoutMove: Equatable {
    let wid: CGWindowID
    let pid: pid_t
    let fromDisplay: String
    let fromDesktop: Int
    let toDisplay: String
    let toDesktop: Int
}

/// A window as it is now, located on a display and desktop.
struct PlacedWindow: Equatable {
    let wid: CGWindowID
    let pid: pid_t
    let bundleID: String
    let title: String
    let display: String
    let desktop: Int
}

enum LayoutPlanner {
    /// Match today's windows to the saved ones (same app; same title first, then in order) and list the moves.
    /// `desktopCounts` is how many desktops each display has now; saved desktops that no longer exist, and saved
    /// displays that aren't connected, fall back to the window's own display or are skipped.
    static func plan(saved: [SavedLayout.Entry], current: [PlacedWindow], desktopCounts: [String: Int]) -> [LayoutMove] {
        var moves: [LayoutMove] = []
        let byApp = Dictionary(grouping: current, by: \.bundleID)
        let savedByApp = Dictionary(grouping: saved, by: \.bundleID)
        for (bundleID, wanted) in savedByApp {
            var remaining = (byApp[bundleID] ?? []).sorted { ($0.display, $0.desktop, $0.wid) < ($1.display, $1.desktop, $1.wid) }
            var pairs: [(PlacedWindow, SavedLayout.Entry)] = []
            var unmatched: [SavedLayout.Entry] = []
            for entry in wanted {
                if !entry.title.isEmpty, let i = remaining.firstIndex(where: { $0.title == entry.title }) {
                    pairs.append((remaining.remove(at: i), entry))
                } else {
                    unmatched.append(entry)
                }
            }
            for entry in unmatched {
                // Prefer a window that's already where this entry wants one, so nothing moves needlessly.
                if let i = remaining.firstIndex(where: { $0.display == entry.display && $0.desktop == entry.desktop }) {
                    pairs.append((remaining.remove(at: i), entry))
                } else if !remaining.isEmpty {
                    pairs.append((remaining.removeFirst(), entry))
                }
            }
            for (w, e) in pairs {
                let display = desktopCounts[e.display] != nil ? e.display : w.display
                guard let count = desktopCounts[display], e.desktop >= 1, e.desktop <= count else { continue }
                if display == w.display && e.desktop == w.desktop { continue }
                moves.append(LayoutMove(wid: w.wid, pid: w.pid, fromDisplay: w.display, fromDesktop: w.desktop,
                                        toDisplay: display, toDesktop: e.desktop))
            }
        }
        return moves.sorted { ($0.fromDisplay, $0.fromDesktop, $0.wid) < ($1.fromDisplay, $1.fromDesktop, $1.wid) }
    }
}

@MainActor
final class Layouts {
    static let shared = Layouts()
    private(set) var restoring = false
    private var task: Task<Void, Never>?
    var onStateChange: () -> Void = {}

    // MARK: Storage

    static var all: [SavedLayout] {
        get { Prefs.layoutsData.flatMap { try? JSONDecoder().decode([SavedLayout].self, from: $0) } ?? [] }
        set { Prefs.layoutsData = try? JSONEncoder().encode(newValue) }
    }

    static func placedWindows() -> [PlacedWindow] {
        let displays = Spaces.displays()
        return WindowCatalog.all().compactMap { w in
            guard let (d, n) = Spaces.locate(space: w.space, in: displays) else { return nil }   // skips full-screen
            return PlacedWindow(wid: w.wid, pid: w.pid, bundleID: w.bundleID, title: w.title, display: d.uuid, desktop: n)
        }
    }

    @discardableResult
    static func saveCurrent(named name: String) -> SavedLayout {
        var names: [String: String] = [:]
        for a in NSWorkspace.shared.runningApplications { if let b = a.bundleIdentifier { names[b] = a.localizedName ?? b } }
        let entries = placedWindows().map {
            SavedLayout.Entry(bundleID: $0.bundleID, appName: names[$0.bundleID] ?? $0.bundleID, title: $0.title,
                              display: $0.display, desktop: $0.desktop)
        }
        let layout = SavedLayout(name: name, saved: Date(), entries: entries)
        var list = all.filter { $0.name != name }
        list.append(layout)
        all = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return layout
    }

    static func delete(named name: String) {
        all = all.filter { $0.name != name }
        if Prefs.restoreLayoutAtLaunch == name { Prefs.restoreLayoutAtLaunch = nil }
    }

    // MARK: Restore

    func cancel() { task?.cancel() }

    /// Launch missing apps, then visit each desktop that has windows in the wrong place and carry them over.
    func restore(_ layout: SavedLayout, completion: @escaping (_ moved: Int, _ failed: Int, _ cancelled: Bool) -> Void) {
        guard !restoring else { return }
        restoring = true
        onStateChange()
        task = Task { @MainActor in
            var moved = 0, failed = 0
            defer {
                self.restoring = false
                self.onStateChange()
                completion(moved, failed, Task.isCancelled)
            }
            await self.launchMissing(layout)
            guard !Task.isCancelled else { return }

            let displays = Spaces.displays()
            let counts = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0.userSpaces.count) })
            let start = displays.compactMap { d in d.currentDesktopNumber.map { (d.uuid, $0) } }
            let plan = LayoutPlanner.plan(saved: layout.entries, current: Self.placedWindows(), desktopCounts: counts)
            dbg("layout \(layout.name): \(plan.count) moves")

            let groups = Dictionary(grouping: plan) { "\($0.fromDisplay)|\($0.fromDesktop)" }
            for key in groups.keys.sorted() {
                guard !Task.isCancelled, let items = groups[key], let first = items.first else { break }
                guard await WindowMover.shared.switchTo(desktop: first.fromDesktop, display: first.fromDisplay) else {
                    failed += items.count; continue
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                for m in items {
                    guard !Task.isCancelled else { break }
                    guard let app = NSRunningApplication(processIdentifier: m.pid),
                          let w = Windows.ofApp(app).first(where: { $0.id == m.wid }) else { failed += 1; continue }
                    HomeDesktops.shared.suppress(m.pid, for: 1)
                    let f = await WindowMover.shared.move(ax: w.ax, wid: w.id, pid: m.pid,
                                                          to: .display(m.toDisplay, m.toDesktop), follow: false)
                    if f == nil { moved += 1 } else { failed += 1 }
                }
            }
            // Back to where the user started.
            for (uuid, n) in start where !Task.isCancelled {
                await WindowMover.shared.switchTo(desktop: n, display: uuid)
            }
        }
    }

    private func launchMissing(_ layout: SavedLayout) async {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let missing = Set(layout.entries.map(\.bundleID)).subtracting(running)
        guard !missing.isEmpty else { return }
        for id in missing {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            if let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: config) {
                HomeDesktops.shared.suppress(app.processIdentifier, for: 30)      // the layout decides where they go
            }
        }
        // Give the apps a moment to open their windows.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !Task.isCancelled {
            let withWindows = Set(WindowCatalog.all().map(\.bundleID))
            if missing.allSatisfy({ withWindows.contains($0) || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil }) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
    }
}
