import Cocoa
import SwiftUI

// MARK: - Model & view

struct PreviewItem: Identifiable {
    let id: CGWindowID
    var title: String
    var minimized: Bool
    var image: NSImage?
}

final class PreviewModel: ObservableObject {
    @Published var appName = ""
    @Published var icon = NSImage()
    @Published var items: [PreviewItem] = []
    @Published var hovered: CGWindowID?
    var onSelect: (CGWindowID) -> Void = { _ in }
    var onClose: (CGWindowID) -> Void = { _ in }
    var onMinimize: (CGWindowID) -> Void = { _ in }
}

private let cardWidth: CGFloat = 200
private let cardHeight: CGFloat = 125

struct PreviewView: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: model.icon).resizable().frame(width: 16, height: 16)
                Text(model.appName).font(.system(size: 12, weight: .semibold))
                Text("· this desktop").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            HStack(spacing: 10) {
                ForEach(model.items) { item in
                    Card(item: item, icon: model.icon, hover: model.hovered == item.id,
                         onHover: { model.hovered = $0 ? item.id : (model.hovered == item.id ? nil : model.hovered) },
                         onSelect: { model.onSelect(item.id) }, onClose: { model.onClose(item.id) },
                         onMinimize: { model.onMinimize(item.id) })
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    struct Card: View {
        let item: PreviewItem
        let icon: NSImage
        let hover: Bool
        let onHover: (Bool) -> Void
        let onSelect: () -> Void
        let onClose: () -> Void
        let onMinimize: () -> Void

        var body: some View {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.18))
                    if let img = item.image {
                        Image(nsImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).padding(4)
                    } else {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 48, height: 48).opacity(0.85)
                    }
                    if item.minimized {
                        VStack { Spacer(); Text("Minimized").font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white).padding(6) }
                    }
                    if hover {
                        VStack {
                            HStack(spacing: 6) {
                                Button(action: onClose) {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white, Color(red: 1, green: 0.37, blue: 0.34))
                                }.buttonStyle(.plain).help("Close window")
                                if !item.minimized {
                                    Button(action: onMinimize) {
                                        Image(systemName: "minus.circle.fill").font(.system(size: 16)).foregroundStyle(.white, Color(red: 1, green: 0.74, blue: 0.18))
                                    }.buttonStyle(.plain).help("Minimize window")
                                }
                                Spacer()
                            }
                            Spacer()
                        }.padding(6)
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hover ? Color.accentColor : .clear, lineWidth: 2))
                Text(item.title).font(.system(size: 11)).lineLimit(1).truncationMode(.tail).frame(width: cardWidth)
            }
            .contentShape(Rectangle())
            .onHover(perform: onHover)
            .onTapGesture(perform: onSelect)
        }
    }
}

// MARK: - Controller

/// Shows a thumbnail card above a Dock icon, listing only that app's windows on the current desktop.
final class DockPreviewController {
    private let model = PreviewModel()
    private var panel: NSPanel?
    private var monitor: Any?
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var watchTimer: Timer?
    private var hovered: DockItem?
    private var lastMove = Date.distantPast
    private var shownPID: pid_t = 0
    private var shownApp: NSRunningApplication?
    var debugPinned = false

    func start() {
        guard monitor == nil else { return }
        model.onSelect = { [weak self] id in self?.select(id) }
        model.onClose = { [weak self] id in self?.close(id) }
        model.onMinimize = { [weak self] id in self?.minimize(id) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] e in
            self?.mouse(e)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hide()
    }

    private func mouse(_ e: NSEvent) {
        guard Prefs.previewsEnabled else { hide(); return }
        if e.type != .mouseMoved { hide(); return }                    // any click dismisses
        let now = Date()
        guard now.timeIntervalSince(lastMove) > 0.04 else { return }
        lastMove = now
        let p = CGEvent(source: nil)?.location ?? .zero
        if DockInspector.shared.isNearDock(p), let item = DockInspector.shared.item(at: p) {
            hovered = item
            hideTimer?.invalidate(); hideTimer = nil
            if item.app.processIdentifier == shownPID && panel?.isVisible == true { return }
            showTimer?.invalidate()
            let delay = panel?.isVisible == true ? 0.05 : 0.3
            showTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.show(item) }
        } else {
            showTimer?.invalidate(); showTimer = nil
            if panel?.isVisible != true { hovered = nil }
        }
    }

    func debugShow(at p: CGPoint) -> String {
        guard let item = DockInspector.shared.item(at: p) else { return "no dock item at point" }
        show(item)
        return "show(\(item.app.localizedName ?? "?")): windows=\(Windows.ofApp(item.app).count) panelVisible=\(panel?.isVisible ?? false) frame=\(panel?.frame ?? .zero)"
    }

    private func show(_ item: DockItem) {
        let wins = Windows.ofApp(item.app)
        guard !wins.isEmpty else { hide(); return }
        shownPID = item.app.processIdentifier
        shownApp = item.app
        hovered = item
        let name = item.app.localizedName ?? item.title
        model.appName = name
        model.icon = item.app.icon ?? NSImage()
        model.items = wins.map {
            PreviewItem(id: $0.id, title: $0.title.isEmpty ? name : $0.title, minimized: $0.minimized, image: Thumbnails.shared.cached($0.id))
        }
        let panel = ensurePanel()
        position(panel, for: item)
        panel.orderFrontRegardless()
        startWatching()

        Task { @MainActor in
            let fresh = await Thumbnails.shared.refresh(wins)
            guard self.shownPID == item.app.processIdentifier else { return }
            self.model.items = self.model.items.map { var i = $0; if let img = fresh[i.id] { i.image = img }; return i }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: PreviewView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        panel = p
        return p
    }

    private func position(_ panel: NSPanel, for item: DockItem) {
        let host = panel.contentView as! NSHostingView<PreviewView>
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(item.frame.cocoaRect) } ?? NSScreen.main ?? NSScreen.screens[0]
        size.width = min(size.width, screen.visibleFrame.width - 24)
        let icon = item.frame.cocoaRect
        var origin: CGPoint
        switch DockInspector.shared.orientation {
        case .bottom: origin = CGPoint(x: icon.midX - size.width / 2, y: icon.maxY + 8)
        case .left:   origin = CGPoint(x: icon.maxX + 8, y: icon.midY - size.height / 2)
        case .right:  origin = CGPoint(x: icon.minX - size.width - 8, y: icon.midY - size.height / 2)
        }
        let vf = screen.frame
        origin.x = max(vf.minX + 8, min(origin.x, vf.maxX - size.width - 8))
        origin.y = max(vf.minY + 8, min(origin.y, vf.maxY - size.height - 8))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Hide shortly after the mouse leaves both the Dock icon and the card (and the gap between).
    private func startWatching() {
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, !self.debugPinned, let panel = self.panel, panel.isVisible, let item = self.hovered else { return }
            let region = panel.frame.union(item.frame.cocoaRect).insetBy(dx: -4, dy: -4)
            if region.contains(NSEvent.mouseLocation) {
                self.hideTimer?.invalidate(); self.hideTimer = nil
            } else if self.hideTimer == nil {
                self.hideTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.hide() }
            }
        }
    }

    func hide() {
        showTimer?.invalidate(); hideTimer?.invalidate(); watchTimer?.invalidate()
        showTimer = nil; hideTimer = nil; watchTimer = nil
        panel?.orderOut(nil)
        shownPID = 0
        shownApp = nil
        hovered = nil
    }

    // MARK: Actions

    private func window(_ id: CGWindowID) -> (Win, NSRunningApplication)? {
        guard let app = shownApp, let w = Windows.ofApp(app).first(where: { $0.id == id }) else { return nil }
        return (w, app)
    }

    private func select(_ id: CGWindowID) {
        guard let (w, app) = window(id) else { return }
        hide()
        Windows.focus(w, app: app)
    }

    func minimize(_ id: CGWindowID) {
        guard let (w, _) = window(id) else { dbg("minimize(\(id)): window lookup failed"); return }
        dbg("minimize(\(id)): ok")
        Windows.minimize(w)
        if let i = model.items.firstIndex(where: { $0.id == id }) { model.items[i].minimized = true }
    }

    private func close(_ id: CGWindowID) {
        guard let (w, _) = window(id) else { return }
        Windows.close(w)
        model.items.removeAll { $0.id == id }
        if model.items.isEmpty { hide() } else if let panel, let item = hovered { position(panel, for: item) }
    }
}
