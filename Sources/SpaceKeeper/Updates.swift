import Cocoa

/// Asks GitHub for the latest release. A plain anonymous GET: nothing about the Mac or its user is sent.
enum Updates {
    struct Release: Equatable {
        let version: String
        let page: URL
        let download: URL?
        let notes: String
    }

    static let api = URL(string: "https://api.github.com/repos/techmalik/SpaceKeeper/releases/latest")!

    static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.compactMap { a -> URL? in
            guard let name = a["name"] as? String, name.hasSuffix(".dmg") else { return nil }
            return (a["browser_download_url"] as? String).flatMap(URL.init(string:))
        }.first
        return Release(version: normalize(tag), page: page, download: dmg, notes: json["body"] as? String ?? "")
    }

    static func normalize(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// Numeric dotted comparison: 1.10.0 > 1.9.3, 1.1 == 1.1.0. Anything after "-" (e.g. "-beta") is ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            normalize(v).split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SpaceKeeper/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    /// Daily background check, only when turned on.
    @MainActor static func checkIfDue() {
        guard Prefs.autoCheckUpdates else { return }
        if let last = Prefs.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        check(userInitiated: false)
    }

    @MainActor private static var checking = false

    @MainActor static func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        Prefs.lastUpdateCheck = Date()
        Task { @MainActor in
            defer { checking = false }
            let release = try? await fetchLatest()
            guard let release else {
                if userInitiated { alert("Couldn't check for updates", "GitHub didn't answer. Check your connection, or look at the releases page.", page: AppInfo.releases) }
                return
            }
            guard isNewer(release.version, than: AppInfo.version) else {
                if userInitiated { alert("SpaceKeeper is up to date", "You have version \(AppInfo.version), the latest release.", page: nil) }
                return
            }
            if !userInitiated && Prefs.skippedVersion == release.version { return }
            offer(release, userInitiated: userInitiated)
        }
    }

    @MainActor private static func offer(_ r: Release, userInitiated: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "SpaceKeeper \(r.version) is available"
        let notes = r.notes.count > 600 ? String(r.notes.prefix(600)) + "…" : r.notes
        a.informativeText = "You have \(AppInfo.version).\n\n\(notes)\n\nDownload the new version, quit SpaceKeeper and drag the new one into Applications. If permissions stop working afterwards, remove SpaceKeeper from Accessibility and add it back."
        a.addButton(withTitle: r.download != nil ? "Download" : "Open Release Page")
        a.addButton(withTitle: "Later")
        if !userInitiated { a.addButton(withTitle: "Skip This Version") }
        switch a.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(r.download ?? r.page)
        case .alertThirdButtonReturn: Prefs.skippedVersion = r.version
        default: break
        }
    }

    @MainActor private static func alert(_ title: String, _ text: String, page: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        if page != nil { a.addButton(withTitle: "Open Releases Page") }
        if a.runModal() == .alertSecondButtonReturn, let page { NSWorkspace.shared.open(page) }
    }
}
