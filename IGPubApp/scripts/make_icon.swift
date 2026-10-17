// Draws the app icon (direction B: safelight over a print) into an .iconset folder.
// usage: swift scripts/make_icon.swift <out.iconset>
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let full = CGFloat(px), body = full * 0.8047          // macOS icon grid: 824 of 1024
    let s = body / 200                                    // design units are the 200-pt canvas
    ctx.translateBy(x: (full - body) / 2, y: (full - body) / 2)
    ctx.translateBy(x: 0, y: body); ctx.scaleBy(x: s, y: -s)  // y-down, like the design board

    let shape = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 200, height: 200), xRadius: 45, yRadius: 45)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    color(0x1B1A18).setFill(); shape.fill()
    ctx.restoreGState()
    shape.addClip()

    color(0xE0652A).setFill()
    let dome = NSBezierPath()
    dome.move(to: NSPoint(x: 70, y: 56)); dome.line(to: NSPoint(x: 70, y: 56))
    dome.appendArc(withCenter: NSPoint(x: 100, y: 56), radius: 30, startAngle: 180, endAngle: 360, clockwise: false)
    dome.close(); dome.fill()
    color(0x3A3732).setFill()
    NSBezierPath(roundedRect: NSRect(x: 62, y: 56, width: 76, height: 6), xRadius: 3, yRadius: 3).fill()

    ctx.saveGState()
    ctx.translateBy(x: 100, y: 127); ctx.rotate(by: -6 * .pi / 180); ctx.translateBy(x: -48, y: -45)
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    color(0xF4F2EE).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 96, height: 90), xRadius: 4, yRadius: 4).fill()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.translateBy(x: 100, y: 127); ctx.rotate(by: -6 * .pi / 180); ctx.translateBy(x: -48, y: -45)
    color(0xC9BFB1).setFill(); NSRect(x: 9, y: 9, width: 78, height: 59).fill()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
