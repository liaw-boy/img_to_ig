// Draws the disk image window background: a compact window with the app on the left, Applications on the right
// and an arrow between them. Writes 1x and 2x PNGs; make_dmg.sh merges them into one HiDPI TIFF.
// The icon centers here must match the positions make_dmg.sh gives Finder.
// usage: swift scripts/make_dmg_background.swift <out-dir>
import AppKit

let width = 520, height = 300
let appCenter = CGPoint(x: 130, y: 138), appsCenter = CGPoint(x: 390, y: 138)   // y from the top, like Finder

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

func render(scale: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)           // points, so the 2x copy is marked HiDPI
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)   // y-down

    // Warm paper, like the print in the app icon; dark enough at the bottom for the hint to sit on.
    let bg = NSGradient(starting: color(0xF4F2EE), ending: color(0xE6E1D8))!
    bg.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

    // Arrow from the app toward Applications, in the icon's safelight orange.
    let y = appCenter.y, x0 = appCenter.x + 78, x1 = appsCenter.x - 78
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: x0, y: y)); shaft.line(to: NSPoint(x: x1 - 6, y: y))
    shaft.lineWidth = 4; shaft.lineCapStyle = .round
    color(0xE0652A).setStroke(); shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: x1 - 16, y: y - 12)); head.line(to: NSPoint(x: x1, y: y)); head.line(to: NSPoint(x: x1 - 16, y: y + 12))
    head.lineWidth = 4; head.lineCapStyle = .round; head.lineJoinStyle = .round
    head.stroke()

    // Hint under the icons and their labels. NSString draws upside down in a flipped context, so flip back for it.
    let hint = "把 img_to_ig 拖到「應用程式」完成安裝" as NSString
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                .foregroundColor: color(0x1B1A18, 0.62), .paragraphStyle: para]
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    hint.draw(in: NSRect(x: 0, y: CGFloat(height) - 52, width: CGFloat(width), height: 20), withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.dropFirst().first ?? "."
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
try render(scale: 1).write(to: URL(fileURLWithPath: "\(out)/background.png"))
try render(scale: 2).write(to: URL(fileURLWithPath: "\(out)/background@2x.png"))
