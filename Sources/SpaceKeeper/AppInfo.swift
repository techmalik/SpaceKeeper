import Foundation

/// Everything that identifies the app and its author. Change the URLs here if you fork it.
enum AppInfo {
    static let name = "SpaceKeeper"
    static let tagline = "Make every macOS desktop its own workspace."
    static let summary = "SpaceKeeper keeps each desktop (Space) separate: send windows to other desktops and keep them there, see Dock previews of only the windows on your current desktop, and click a Dock icon to minimize, restore or open a window right where you are."
    static let author = "Malik Kabir"
    static let email = "techmaleek@gmail.com"
    static let license = "MIT License"
    static let year = "2026"

    static let repo = URL(string: "https://github.com/techmalik/SpaceKeeper")!
    static let issues = URL(string: "https://github.com/techmalik/SpaceKeeper/issues")!
    static let releases = URL(string: "https://github.com/techmalik/SpaceKeeper/releases")!

    /// Where in-app feedback is delivered (an email-forwarding form service; no account or server needed).
    /// The first message sent to this address makes the service email the owner a one-time activation link.
    static var feedbackEndpoint: URL {
        // Test hook: only honored when the debug channel is enabled.
        if Prefs.debugControl, let o = UserDefaults.standard.string(forKey: "feedbackEndpointOverride"), let u = URL(string: o) { return u }
        return URL(string: "https://formsubmit.co/\(email)")!
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    /// A pre-filled email draft (nothing is sent until the user presses Send in their mail app).
    static var feedbackURL: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let body = "\n\n—\nSpaceKeeper \(version) (\(build)) · macOS \(os)"
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = email
        c.queryItems = [
            URLQueryItem(name: "subject", value: "SpaceKeeper feedback"),
            URLQueryItem(name: "body", value: body),
        ]
        return c.url ?? URL(string: "mailto:\(email)")!
    }
}
