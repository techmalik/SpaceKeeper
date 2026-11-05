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
        ])
    }

    static var previewsEnabled: Bool { get { d.bool(forKey: "previewsEnabled") } set { d.set(newValue, forKey: "previewsEnabled") } }
    static var clickToMinimize: Bool { get { d.bool(forKey: "clickToMinimize") } set { d.set(newValue, forKey: "clickToMinimize") } }
    static var followWindow: Bool { get { d.bool(forKey: "followWindow") } set { d.set(newValue, forKey: "followWindow") } }
    static var openNewWindowHere: Bool { get { d.bool(forKey: "openNewWindowHere") } set { d.set(newValue, forKey: "openNewWindowHere") } }
    static var debugControl: Bool { d.bool(forKey: "debugControl") }

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
