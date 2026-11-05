import Cocoa
import ScreenCaptureKit

/// Window thumbnails via ScreenCaptureKit. Falls back to the last good image (useful for
/// minimized windows, which can't be captured live).
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSNumber, NSImage>()

    private init() { cache.countLimit = 128 }

    func cached(_ id: CGWindowID) -> NSImage? {
        guard CGPreflightScreenCaptureAccess() else { cache.removeAllObjects(); return nil }
        return cache.object(forKey: NSNumber(value: id))
    }

    func refresh(_ wins: [Win]) async -> [CGWindowID: NSImage] {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return [:] }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [CGWindowID: NSImage] = [:]
        for w in wins {
            guard !Task.isCancelled else { break }
            guard let sc = byID[w.id], sc.frame.width > 1, sc.frame.height > 1 else { continue }
            let cfg = SCStreamConfiguration()
            let scale = min(480 / sc.frame.width, 300 / sc.frame.height, 2)
            cfg.width = max(Int(sc.frame.width * scale), 1)
            cfg.height = max(Int(sc.frame.height * scale), 1)
            cfg.showsCursor = false
            guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sc),
                                                                       configuration: cfg) else { continue }
            guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { break }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            cache.setObject(img, forKey: NSNumber(value: w.id))
            out[w.id] = img
        }
        return out
    }
}
