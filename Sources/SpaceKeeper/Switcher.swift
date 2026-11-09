import Cocoa
import SwiftUI
import Carbon.HIToolbox

// MARK: - Model

struct SwitcherApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let titles: [String]
}

struct SwitcherDesktop: Identifiable {
    let id: Int                // desktop number, 1-based
    let name: String?
    let isCurrent: Bool
    let apps: [SwitcherApp]
}

final class SwitcherModel: ObservableObject {
    @Published var displayName = ""
    @Published var desktops: [SwitcherDesktop] = []
    @Published var selected = 1
    @Published var frontAppName: String?
    var onGo: (Int) -> Void = { _ in }
    var onSend: (Int) -> Void = { _ in }
    var onSendApp: (Int) -> Void = { _ in }
}

// MARK: - View

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 230), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Desktops").font(.system(size: 15, weight: .semibold))
                Text(model.displayName).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(model.desktops) { d in
                    Tile(desktop: d, selected: model.selected == d.id, canSend: model.frontAppName != nil,
                         onHover: { if $0 { model.selected = d.id } },
                         onGo: { model.onGo(d.id) }, onSend: { model.onSend(d.id) })
                }
            }
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private var width: CGFloat {
        let n = CGFloat(min(max(model.desktops.count, 1), 4))
        return n * 222 + (n - 1) * 12 + 32
    }

    private var hint: String {
        var s = "1–9 or click: go there · ←→ ↩ select and go"
        if let app = model.frontAppName { s += " · ⇧1–9: move \(app)'s window · ⌥1–9: move all \(app) windows" }
        return s + " · esc: close"
    }

    struct Tile: View {
        let desktop: SwitcherDesktop
        let selected: Bool
        let canSend: Bool
        let onHover: (Bool) -> Void
        let onGo: () -> Void
        let onSend: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(desktop.id)").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(desktop.name ?? "Desktop \(desktop.id)").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    if desktop.isCurrent {
                        Text("Here").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.25), in: Capsule())
                    }
                }
                if desktop.apps.isEmpty {
                    Text("Empty").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(desktop.apps.prefix(5)) { app in
                            HStack(spacing: 5) {
                                Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                                Text(label(app)).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                            }
                        }
                        if desktop.apps.count > 5 {
                            Text("+\(desktop.apps.count - 5) more").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if selected && !desktop.isCurrent {
                    HStack(spacing: 6) {
                        Button("Go", action: onGo).controlSize(.small)
                        if canSend { Button("Move window here", action: onSend).controlSize(.small) }
                    }
                }
            }
            .padding(10)
            .frame(width: 222, height: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(selected ? 0.22 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onHover(perform: onHover)
            .onTapGesture(perform: onGo)
        }

        private func label(_ app: SwitcherApp) -> String {
            if app.titles.count == 1, let t = app.titles.first, !t.isEmpty { return "\(app.name) — \(t)" }
            return app.titles.count > 1 ? "\(app.name) · \(app.titles.count) windows" : app.name
        }
    }
}

// MARK: - Controller

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class SwitcherController: NSObject, NSWindowDelegate {
    static let shared = SwitcherController()
    private let model = SwitcherModel()
    private var panel: KeyPanel?
    private var keyMonitor: Any?
    private var displayUUID = ""
    private var frontApp: NSRunningApplication?

    /// Go to a desktop, or carry the previously frontmost app's window(s) there.
    var onGo: (_ desktop: Int, _ display: String) -> Void = { _, _ in }
    var onSend: (_ desktop: Int, _ display: String, _ app: NSRunningApplication, _ allWindows: Bool) -> Void = { _, _, _, _ in }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? close(restoreFocus: true) : show() }

    func show() {
        let displays = Spaces.displays()
        let pointer = CGEvent(source: nil)?.location ?? .zero
        guard let uuid = DisplayGeometry.uuid(containing: pointer, in: displays) ?? displays.first?.uuid,
              let display = displays.first(where: { $0.uuid == uuid }) else { NSSound.beep(); return }
        displayUUID = uuid
        let front = NSWorkspace.shared.frontmostApplication
        frontApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        model.displayName = displays.count > 1 ? DisplayGeometry.name(forUUID: uuid) : ""
        model.desktops = Self.desktops(of: display)
        model.selected = display.currentDesktopNumber ?? 1
        model.frontAppName = frontApp.flatMap { Windows.focused(of: $0) != nil ? $0.localizedName : nil }
        model.onGo = { [weak self] n in self?.go(n) }
        model.onSend = { [weak self] n in self?.send(n, all: false) }

        let p = ensurePanel()
        let host = p.contentView as! NSHostingView<SwitcherView>
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = DisplayGeometry.screen(forUUID: uuid) ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        p.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + vf.height * 0.08,
                          width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, self.isVisible else { return e }
                return MainActor.assumeIsolated { self.handleKey(e) } ? nil : e
            }
        }
    }

    static func desktops(of display: DisplaySpaces) -> [SwitcherDesktop] {
        let spaceToDesktop = Dictionary(uniqueKeysWithValues: display.userSpaces.enumerated().map { ($1.id, $0 + 1) })
        var byDesktop: [Int: [WindowRef]] = [:]
        for w in WindowCatalog.all() { if let n = spaceToDesktop[w.space] { byDesktop[n, default: []].append(w) } }
        return (1...max(display.userSpaces.count, 1)).map { n in
            let wins = byDesktop[n] ?? []
            var order: [String] = []
            var grouped: [String: [WindowRef]] = [:]
            for w in wins.sorted(by: { $0.wid < $1.wid }) {
                if grouped[w.bundleID] == nil { order.append(w.bundleID) }
                grouped[w.bundleID, default: []].append(w)
            }
            let apps = order.map { id -> SwitcherApp in
                let ws = grouped[id]!
                let icon = NSRunningApplication(processIdentifier: ws[0].pid)?.icon ?? NSImage()
                return SwitcherApp(id: id, name: ws[0].appName, icon: icon, titles: ws.map(\.title))
            }
            return SwitcherDesktop(id: n, name: DesktopNames.custom(display: display, desktop: n),
                                   isCurrent: display.currentDesktopNumber == n, apps: apps)
        }
    }

    private func ensurePanel() -> KeyPanel {
        if let panel { return panel }
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        p.level = .modalPanel
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        p.delegate = self
        let host = NSHostingView(rootView: SwitcherView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        panel = p
        return p
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { if isVisible { close(restoreFocus: false) } }
    }

    private func close(restoreFocus: Bool) {
        panel?.orderOut(nil)
        if restoreFocus, let app = frontApp { Windows.bringForward(app, []) }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let code = Int(e.keyCode)
        let count = model.desktops.count
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        if let i = digits.firstIndex(of: code) {
            let n = i + 1
            guard n <= count else { NSSound.beep(); return true }
            if e.modifierFlags.contains(.option) { send(n, all: true) }
            else if e.modifierFlags.contains(.shift) { send(n, all: false) }
            else { go(n) }
            return true
        }
        switch code {
        case kVK_Escape: close(restoreFocus: true)
        case kVK_LeftArrow: model.selected = max(1, model.selected - 1)
        case kVK_RightArrow: model.selected = min(count, model.selected + 1)
        case kVK_UpArrow: model.selected = max(1, model.selected - 4)
        case kVK_DownArrow: model.selected = min(count, model.selected + 4)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            e.modifierFlags.contains(.shift) ? send(model.selected, all: false) : go(model.selected)
        default: return false
        }
        return true
    }

    private func go(_ n: Int) {
        close(restoreFocus: true)
        onGo(n, displayUUID)
    }

    private func send(_ n: Int, all: Bool) {
        guard let app = frontApp else { NSSound.beep(); return }
        close(restoreFocus: true)
        onSend(n, displayUUID, app, all)
    }
}
