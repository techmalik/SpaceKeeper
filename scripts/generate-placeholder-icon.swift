// Draws a simple placeholder app icon (1024x1024) so builds always have an icon.
// Replace Resources/AppIcon-source.png with your own artwork and run scripts/make-icon.sh.
import Cocoa

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-source.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS-style rounded square with a margin, like system icons.
let inset: CGFloat = 100
let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSColor.black.setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [NSColor(red: 0.36, green: 0.31, blue: 0.93, alpha: 1), NSColor(red: 0.07, green: 0.55, blue: 0.95, alpha: 1)])!
    .draw(in: squircle, angle: -60)

// Three "desktops": two receding behind, one highlighted in front.
func desktop(_ rect: NSRect, alpha: CGFloat, fill: Bool) {
    let p = NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44)
    NSColor.white.withAlphaComponent(alpha).setFill()
    p.fill()
    if fill {
        let bar = NSBezierPath(roundedRect: NSRect(x: rect.minX + 28, y: rect.maxY - 56, width: 18, height: 18), xRadius: 9, yRadius: 9)
        NSColor(red: 0.36, green: 0.31, blue: 0.93, alpha: 0.9).setFill(); bar.fill()
        let bar2 = NSBezierPath(roundedRect: NSRect(x: rect.minX + 56, y: rect.maxY - 56, width: 18, height: 18), xRadius: 9, yRadius: 9)
        NSColor(red: 0.07, green: 0.55, blue: 0.95, alpha: 0.9).setFill(); bar2.fill()
    }
}
desktop(NSRect(x: 290, y: 470, width: 470, height: 300), alpha: 0.28, fill: false)
desktop(NSRect(x: 250, y: 410, width: 470, height: 300), alpha: 0.5, fill: false)
desktop(NSRect(x: 210, y: 350, width: 470, height: 300), alpha: 0.96, fill: true)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
