import Cocoa
import SwiftUI
import Carbon.HIToolbox

// MARK: - Shortcuts

final class ShortcutsModel: ObservableObject {
    @Published var stored: [String: String] = Prefs.hotkeys
    @Published var recording: String?
    @Published var unavailable: Set<String> = HotKeys.shared.unavailable
    var onChange: () -> Void = {}
    var onRecording: (Bool) -> Void = { _ in }

    func reload() { stored = Prefs.hotkeys; unavailable = HotKeys.shared.unavailable }

    func set(_ s: Shortcut?, for a: HotKeyAction) {
        HotKeyBindings.set(s, for: a)
        recording = nil
        onChange()
        reload()
    }

    func resetAll() { HotKeyBindings.resetAll(); recording = nil; onChange(); reload() }
}

struct ShortcutsPane: View {
    @ObservedObject var model: ShortcutsModel
    private var groups: [String] { var seen: [String] = []; for a in HotKeyAction.all where !seen.contains(a.group) { seen.append(a.group) }; return seen }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Click a shortcut, then press the new keys. Delete clears it, Esc cancels. A shortcut needs ⌘, ⌥ or ⌃.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Form {
                ForEach(groups, id: \.self) { g in
                    Section(g) {
                        ForEach(HotKeyAction.all.filter { $0.group == g }) { a in
                            HStack {
                                Text(a.title)
                                Spacer()
                                if model.unavailable.contains(a.id) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                        .help("macOS or another app already uses this shortcut, so it doesn't work.")
                                }
                                recorder(a)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Restore Defaults") { model.resetAll() } }
        }
    }

    private func recorder(_ a: HotKeyAction) -> some View {
        let current = HotKeyBindings.shortcut(for: a, stored: model.stored)
        let isRecording = model.recording == a.id
        return Button {
            model.recording = isRecording ? nil : a.id
            model.onRecording(model.recording != nil)
        } label: {
            Text(isRecording ? "Type shortcut…" : (current?.display ?? "None"))
                .font(.system(size: 12, design: .rounded)).frame(minWidth: 110)
                .foregroundStyle(current == nil && !isRecording ? .secondary : .primary)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
    }
}

// MARK: - Home desktops

final class HomeModel: ObservableObject {
    struct Row: Identifiable { let id: String; let name: String; let icon: NSImage; var desktop: Int }
    @Published var rows: [Row] = []
    @Published var enabled = Prefs.homeDesktopsEnabled
    @Published var desktopCount = 1

    func reload() {
        enabled = Prefs.homeDesktopsEnabled
        desktopCount = max(Spaces.displays().map(\.userSpaces.count).max() ?? 1, 1)
        rows = Prefs.homeDesktops.map { id, n in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
            return Row(id: id, name: name, icon: icon, desktop: n)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Apps that are running now and have no home yet.
    var candidates: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && Prefs.homeDesktops[$0.bundleIdentifier!] == nil
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

struct HomePane: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Send new windows to their app's home desktop", isOn: Binding(
                get: { model.enabled },
                set: { Prefs.homeDesktopsEnabled = $0; HomeDesktops.shared.sync(); model.reload() }))
            Text("When an app with a home desktop opens a window somewhere else, SpaceKeeper carries it home. Clicking the app in the Dock from another desktop takes you there.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                if model.rows.isEmpty {
                    Text("No home desktops yet. Add an app below, or use the menu: Home Desktop for <app>.").foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    HStack {
                        Image(nsImage: row.icon).resizable().frame(width: 18, height: 18)
                        Text(row.name)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { row.desktop },
                            set: { HomeDesktops.setHome($0, for: row.id); model.reload() })) {
                            ForEach(1...max(model.desktopCount, row.desktop), id: \.self) { Text("Desktop \($0)").tag($0) }
                        }.labelsHidden().frame(width: 130)
                        Button { HomeDesktops.setHome(nil, for: row.id); model.reload() } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove")
                    }
                }
            }.formStyle(.grouped)
            HStack {
                Menu("Add App…") {
                    ForEach(model.candidates, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier!) {
                            HomeDesktops.setHome(1, for: app.bundleIdentifier!); model.reload()
                        }
                    }
                }.frame(width: 140)
                Spacer()
            }
        }
    }
}

// MARK: - Desktop names

final class NamesModel: ObservableObject {
    struct Row: Identifiable { let id: String; let display: String; let number: Int; var name: String }
    @Published var rows: [Row] = []
    @Published var multiDisplay = false

    func reload() {
        let displays = Spaces.displays()
        multiDisplay = displays.count > 1
        rows = displays.flatMap { d in
            (1...max(d.userSpaces.count, 1)).compactMap { n -> Row? in
                guard n <= d.userSpaces.count else { return nil }
                return Row(id: "\(d.uuid)#\(n)", display: d.uuid, number: n, name: DesktopNames.custom(display: d, desktop: n) ?? "")
            }
        }
    }

    func save(_ row: Row, _ name: String) {
        guard let d = Spaces.displays().first(where: { $0.uuid == row.display }) else { return }
        DesktopNames.set(name, display: d, desktop: row.number)
        NotificationCenter.default.post(name: .desktopNamesChanged, object: nil)
    }
}

extension Notification.Name { static let desktopNamesChanged = Notification.Name("SpaceKeeperDesktopNamesChanged") }

struct NamesPane: View {
    @ObservedObject var model: NamesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Names show in the menu, the desktop switcher and (if turned on) the menu bar. They follow the desktop even if you reorder desktops in Mission Control.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                ForEach(model.rows) { row in
                    HStack {
                        Text(model.multiDisplay ? "\(DisplayGeometry.name(forUUID: row.display)) · Desktop \(row.number)" : "Desktop \(row.number)")
                            .frame(minWidth: 90, alignment: .leading)
                        TextField("", text: Binding(
                            get: { model.rows.first(where: { $0.id == row.id })?.name ?? "" },
                            set: { v in
                                if let i = model.rows.firstIndex(where: { $0.id == row.id }) { model.rows[i].name = v }
                                model.save(row, v)
                            }), prompt: Text("Name"))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }.formStyle(.grouped)
        }
    }
}

// MARK: - Window

struct SettingsView: View {
    @ObservedObject var shortcuts: ShortcutsModel
    @ObservedObject var home: HomeModel
    @ObservedObject var names: NamesModel
    @Binding var tab: Int

    var body: some View {
        TabView(selection: $tab) {
            ShortcutsPane(model: shortcuts).padding(14).tabItem { Text("Shortcuts") }.tag(0)
            HomePane(model: home).padding(14).tabItem { Text("Home Desktops") }.tag(1)
            NamesPane(model: names).padding(14).tabItem { Text("Desktop Names") }.tag(2)
        }
        .frame(width: 560, height: 560)
        .padding(.top, 6)
    }
}

final class SettingsTab: ObservableObject { @Published var tab = 0 }

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    let shortcuts = ShortcutsModel()
    let home = HomeModel()
    let names = NamesModel()
    private let tab = SettingsTab()
    private var window: NSWindow?
    private var keyMonitor: Any?
    /// Re-register global hotkeys (or suspend them while a shortcut is being recorded).
    var applyHotkeys: (_ suspended: Bool) -> Void = { _ in }

    enum Tab: Int { case shortcuts = 0, home = 1, names = 2 }

    func show(_ t: Tab = .shortcuts) {
        shortcuts.reload(); home.reload(); names.reload()
        tab.tab = t.rawValue
        shortcuts.onChange = { [weak self] in self?.applyHotkeys(false) }
        shortcuts.onRecording = { [weak self] on in self?.applyHotkeys(on) }
        if window == nil {
            let root = SettingsRoot(tab: tab, shortcuts: shortcuts, home: home, names: names)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "SpaceKeeper Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: root)
            w.delegate = self
            w.center()
            window = w
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self else { return e }
                return MainActor.assumeIsolated { self.record(e) } ? nil : e
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Captures the next key press while a shortcut field is recording.
    private func record(_ e: NSEvent) -> Bool {
        guard let id = shortcuts.recording, let action = HotKeyAction.find(id), e.window === window else { return false }
        let code = Int(e.keyCode)
        let plain = e.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if code == kVK_Escape {
            shortcuts.recording = nil
            applyHotkeys(false)
        } else if plain && (code == kVK_Delete || code == kVK_ForwardDelete) {
            shortcuts.set(nil, for: action)
        } else {
            let s = Shortcut(event: e)
            guard s.isAcceptable else { NSSound.beep(); return true }
            shortcuts.set(s, for: action)
        }
        return true
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if shortcuts.recording != nil { shortcuts.recording = nil; applyHotkeys(false) }
        }
    }
}

private struct SettingsRoot: View {
    @ObservedObject var tab: SettingsTab
    let shortcuts: ShortcutsModel
    let home: HomeModel
    let names: NamesModel
    var body: some View { SettingsView(shortcuts: shortcuts, home: home, names: names, tab: $tab.tab) }
}
