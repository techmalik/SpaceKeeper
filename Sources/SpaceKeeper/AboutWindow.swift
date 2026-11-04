import Cocoa
import SwiftUI

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
            Text(AppInfo.name).font(.system(size: 24, weight: .bold))
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(AppInfo.tagline)
                .font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
                .padding(.top, 2)
            Text(AppInfo.summary)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            Divider().padding(.vertical, 6)

            VStack(spacing: 4) {
                Text("Created by \(AppInfo.author)").font(.system(size: 13, weight: .semibold))
                Text("Questions, ideas or bugs? I'd love to hear from you.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Link(AppInfo.email, destination: URL(string: "mailto:\(AppInfo.email)")!)
                    .font(.system(size: 12))
            }

            HStack(spacing: 8) {
                Button("Send Feedback") { NSWorkspace.shared.open(AppInfo.feedbackURL) }
                Button("GitHub") { NSWorkspace.shared.open(AppInfo.repo) }
                Button("Report an Issue") { NSWorkspace.shared.open(AppInfo.issues) }
            }
            .padding(.top, 6)

            Text("© \(AppInfo.year) \(AppInfo.author) · \(AppInfo.license) · Free and open source")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 380)
    }
}

final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: AboutView())
            let w = NSWindow(contentViewController: host)
            w.title = "About \(AppInfo.name)"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
