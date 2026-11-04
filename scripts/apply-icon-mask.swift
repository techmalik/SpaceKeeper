// Turns full-bleed square artwork into a macOS-style icon: rounded-square mask, standard margin, soft shadow.
// Usage: apply-icon-mask <input.png> <output.png>
import Cocoa

guard CommandLine.arguments.count == 3, let src = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    print("usage: apply-icon-mask <input.png> <output.png>"); exit(1)
}
let size: CGFloat = 1024, inset: CGFloat = 100
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
src.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("wrote \(CommandLine.arguments[2])")
