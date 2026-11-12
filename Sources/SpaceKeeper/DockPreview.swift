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
    @Published var panelWidth: CGFloat = 300
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
            if model.items.isEmpty {
                Text("No windows on this desktop")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.bottom, 2)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(model.items) { item in
                        Card(item: item, icon: model.icon, hover: model.hovered == item.id,
                             onHover: { model.hovered = $0 ? item.id : (model.hovered == item.id ? nil : model.hovered) },
                             onSelect: { model.onSelect(item.id) }, onClose: { model.onClose(item.id) },
                             onMinimize: { model.onMinimize(item.id) })
                    }
                }
            }
            .frame(height: model.items.isEmpty ? 0 : cardHeight + 30)
        }
        .padding(12)
        .frame(width: model.panelWidth)
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
///
/// Driven by a 12 Hz poll of the pointer rather than by mouse-moved events: events can be dropped or arrive
/// just before the pointer settles, a single failed Dock lookup must not cancel a pending card, and a poll
/// makes "pointer rests on an icon for 0.3 s" trivial to express.
@MainActor
final class DockPreviewController {
    private let model = PreviewModel()
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var pollTimer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var captureTask: Task<Void, Never>?
    private var captureGeneration = UUID()

    private var hovered: DockItem?                 // item the visible card belongs to (geometry for hit-testing)
    private var shownPID: pid_t = 0
    private var shownApp: NSRunningApplication?

    private var pendingPID: pid_t = 0              // icon the pointer is resting on, waiting for the delay
    private var pendingSince = Date.distantPast
    private var misses = 0                         // consecutive failed Dock lookups while "near" the Dock
    private var hideSince: Date?
    private var suppressFrom: CGPoint?             // after a click, stay quiet until the pointer moves
    var debugPinned = false

    func start() {
        guard pollTimer == nil else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } }
        model.onSelect = { [weak self] id in self?.select(id) }
        model.onClose = { [weak self] id in self?.close(id) }
        model.onMinimize = { [weak self] id in self?.minimize(id) }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        let t = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)       // .common: keeps firing while menus or drags are tracking
        pollTimer = t
    }

    func stop() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        pollTimer?.invalidate(); pollTimer = nil
        hide()
    }

    /// Hide the card and stay quiet until the pointer actually moves (used after any click on the Dock).
    func dismiss() {
        suppressFrom = CGEvent(source: nil)?.location
        hide()
    }

    // MARK: Polling

    private func poll() {
        let p = CGEvent(source: nil)?.location ?? .zero
        DockInspector.shared.track(p)                  // auto-hidden Dock state, also needed for Dock clicks
        guard Prefs.previewsEnabled else { if panel?.isVisible == true { hide() }; return }
        if let from = suppressFrom {
            if hypot(p.x - from.x, p.y - from.y) < 4 { return }
            suppressFrom = nil
        }

        let near = DockInspector.shared.isNearDock(p)
        let item = near ? DockInspector.shared.item(at: p) : nil
        let visible = panel?.isVisible == true

        if visible {
            if let item, item.app.processIdentifier != shownPID {
                consider(item, delay: 0.08)                      // moved to another icon: switch quickly
            } else {
                pendingPID = 0
            }
            keepOrHide(over: item)
            return
        }

        if let item {
            misses = 0
            consider(item, delay: 0.3)
        } else {
            misses += 1
            if !near || misses >= 3 { pendingPID = 0 }          // one flaky lookup must not cancel a pending card
        }
    }

    private func consider(_ item: DockItem, delay: TimeInterval) {
        let pid = item.app.processIdentifier
        if pendingPID != pid {
            pendingPID = pid
            pendingSince = Date()
        } else if Date().timeIntervalSince(pendingSince) >= delay {
            pendingPID = 0
            show(item)
        }
    }

    /// Keep the card while the pointer is on its icon, on the card, or in the gap between them.
    private func keepOrHide(over item: DockItem?) {
        guard !debugPinned, let panel, let shown = hovered else { return }
        let onIcon = item?.app.processIdentifier == shownPID
        let region = panel.frame.union(shown.frame.cocoaRect).insetBy(dx: -4, dy: -4)
        if onIcon || region.contains(NSEvent.mouseLocation) {
            hideSince = nil
        } else if let since = hideSince {
            if Date().timeIntervalSince(since) > 0.25 { hide() }
        } else {
            hideSince = Date()
        }
    }

    func debugShow(at p: CGPoint) -> String {
        guard let item = DockInspector.shared.item(at: p) else { return "no dock item at point" }
        show(item)
        return "show(\(item.app.localizedName ?? "?")): windows=\(Windows.ofApp(item.app).count) panelVisible=\(panel?.isVisible ?? false) frame=\(panel?.frame ?? .zero)"
    }

    // MARK: Showing

    private func show(_ item: DockItem) {
        captureTask?.cancel()
        captureGeneration = UUID()
        let generation = captureGeneration
        model.hovered = nil
        let wins = Windows.ofApp(item.app)
        shownPID = item.app.processIdentifier
        shownApp = item.app
        hovered = item
        hideSince = nil
        let name = item.app.localizedName ?? item.title
        model.appName = name
        model.icon = item.app.icon ?? NSImage()
        model.items = wins.map {
            PreviewItem(id: $0.id, title: $0.title.isEmpty ? name : $0.title, minimized: $0.minimized, image: Thumbnails.shared.cached($0.id))
        }
        var panel = ensurePanel()
        position(panel, for: item)
        panel.orderFrontRegardless()
        if !panel.isOnActiveSpace {
            // The window server sometimes drops a long-lived panel's "all Spaces" tag (seen after sleep/wake) and keeps
            // it on one desktop, while AppKit still reports it visible: the card then opens on a desktop you can't see.
            dbg("preview panel stranded on Spaces \(Spaces.spaces(of: CGWindowID(panel.windowNumber))) - rebuilding it")
            panel.orderOut(nil)
            self.panel = nil
            panel = ensurePanel()
            position(panel, for: item)
            panel.orderFrontRegardless()
        }
        guard !wins.isEmpty else { return }

        captureTask = Task { @MainActor in
            let fresh = await Thumbnails.shared.refresh(wins)
            guard !Task.isCancelled, self.captureGeneration == generation else { return }
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
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(item.frame.cocoaRect) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        model.panelWidth = Self.previewWidth(count: model.items.count, availableWidth: screen.visibleFrame.width)
        let host = panel.contentView as! NSHostingView<PreviewView>
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: model.panelWidth, height: host.fittingSize.height)
        let icon = item.frame.cocoaRect
        var origin: CGPoint
        switch DockInspector.shared.orientation {
        case .bottom: origin = CGPoint(x: icon.midX - size.width / 2, y: icon.maxY + 8)
        case .left:   origin = CGPoint(x: icon.maxX + 8, y: icon.midY - size.height / 2)
        case .right:  origin = CGPoint(x: icon.minX - size.width - 8, y: icon.midY - size.height / 2)
        }
        let vf = screen.visibleFrame                 // keep the card off the menu bar
        origin.x = max(vf.minX + 8, min(origin.x, vf.maxX - size.width - 8))
        origin.y = max(vf.minY + 8, min(origin.y, vf.maxY - size.height - 8))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    static func previewWidth(count: Int, availableWidth: CGFloat) -> CGFloat {
        min(max(240, CGFloat(count) * (cardWidth + 10) + 14), max(1, availableWidth - 24))
    }

    func hide() {
        captureTask?.cancel()
        captureTask = nil
        captureGeneration = UUID()
        panel?.orderOut(nil)
        shownPID = 0
        shownApp = nil
        hovered = nil
        pendingPID = 0
        hideSince = nil
    }

    // MARK: Actions

    private func window(_ id: CGWindowID) -> (Win, NSRunningApplication)? {
        guard let app = shownApp, let w = Windows.ofApp(app).first(where: { $0.id == id }) else { return nil }
        return (w, app)
    }

    private func select(_ id: CGWindowID) {
        guard let (w, app) = window(id) else { return }
        dismiss()
        Windows.focus(w, app: app)
    }

    func minimize(_ id: CGWindowID) {
        guard let (w, _) = window(id) else { dbg("minimize(\(id)): window lookup failed"); return }
        dbg("minimize(\(id)): ok")
        Windows.minimize(w)
        if let i = model.items.firstIndex(where: { $0.id == id }) { model.items[i].minimized = true }
    }

    private func close(_ id: CGWindowID) {
        guard let (w, app) = window(id) else { return }
        Windows.close(w)
        // Apps can take a moment to close a window. Refresh the card a few times, but only while it still shows
        // the same app, and stop as soon as the window is gone.
        let pid = app.processIdentifier
        for delay in [0.2, 0.6, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let item = self.hovered, self.shownPID == pid, self.panel?.isVisible == true,
                      self.model.items.contains(where: { $0.id == id }) else { return }
                self.show(item)
            }
        }
    }
}
