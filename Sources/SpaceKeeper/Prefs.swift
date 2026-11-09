import Foundation

enum Prefs {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "previewsEnabled": true,
            "clickToMinimize": true,
            "followWindow": false,
            "openNewWindowHere": true,
            "debugControl": false,
            "homeDesktopsEnabled": true,
            "showDesktopName": false,
            "autoCheckUpdates": false,
        ])
    }

    static var previewsEnabled: Bool { get { d.bool(forKey: "previewsEnabled") } set { d.set(newValue, forKey: "previewsEnabled") } }
    static var clickToMinimize: Bool { get { d.bool(forKey: "clickToMinimize") } set { d.set(newValue, forKey: "clickToMinimize") } }
    static var followWindow: Bool { get { d.bool(forKey: "followWindow") } set { d.set(newValue, forKey: "followWindow") } }
    static var openNewWindowHere: Bool { get { d.bool(forKey: "openNewWindowHere") } set { d.set(newValue, forKey: "openNewWindowHere") } }
    static var debugControl: Bool { d.bool(forKey: "debugControl") }

    // MARK: Workspaces

    /// Space key (see DesktopNames.key) → custom desktop name.
    static var desktopNames: [String: String] {
        get { d.dictionary(forKey: "desktopNames") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "desktopNames") }
    }
    static var showDesktopName: Bool { get { d.bool(forKey: "showDesktopName") } set { d.set(newValue, forKey: "showDesktopName") } }

    /// Bundle identifier → home desktop number (on the display where the window opens).
    static var homeDesktops: [String: Int] {
        get { d.dictionary(forKey: "homeDesktops") as? [String: Int] ?? [:] }
        set { d.set(newValue, forKey: "homeDesktops") }
    }
    static var homeDesktopsEnabled: Bool { get { d.bool(forKey: "homeDesktopsEnabled") } set { d.set(newValue, forKey: "homeDesktopsEnabled") } }

    /// Action id → "keyCode:carbonModifiers", or "" for "no shortcut". Missing = default.
    static var hotkeys: [String: String] {
        get { d.dictionary(forKey: "hotkeys") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "hotkeys") }
    }

    static var layoutsData: Data? { get { d.data(forKey: "layouts") } set { d.set(newValue, forKey: "layouts") } }
    static var restoreLayoutAtLaunch: String? {
        get { d.string(forKey: "restoreLayoutAtLaunch") }
        set { d.set(newValue, forKey: "restoreLayoutAtLaunch") }
    }

    // MARK: Updates

    static var autoCheckUpdates: Bool { get { d.bool(forKey: "autoCheckUpdates") } set { d.set(newValue, forKey: "autoCheckUpdates") } }
    static var lastUpdateCheck: Date? { get { d.object(forKey: "lastUpdateCheck") as? Date } set { d.set(newValue, forKey: "lastUpdateCheck") } }
    static var skippedVersion: String? { get { d.string(forKey: "skippedVersion") } set { d.set(newValue, forKey: "skippedVersion") } }

    // macOS: "When switching to an application, switch to a Space with open windows for the application"
    static var systemSwitchOnActivate: Bool {
        (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleSpacesSwitchOnActivate"] as? Bool) ?? true
    }

    static func setSystemSwitchOnActivate(_ on: Bool) {
        run("/usr/bin/defaults", ["write", "NSGlobalDomain", "AppleSpacesSwitchOnActivate", "-bool", on ? "true" : "false"])
        run("/usr/bin/killall", ["Dock"])
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
