// Draws the app icon from logo.svg and writes PNGs into an iconset (run via build.sh).
import AppKit

let logo = NSImage(contentsOf: URL(fileURLWithPath: "logo.svg"))!

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSColor(red: 0x14 / 255.0, green: 0x2b / 255.0, blue: 0x43 / 255.0, alpha: 1).setFill()
    bg.fill()

    let w = 600 * s
    let h = w * logo.size.height / logo.size.width
    logo.draw(in: NSRect(x: (size - w) / 2, y: 540 * s, width: w, height: h))

    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 200 * s, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
    ]
    NSString(string: "webm").draw(in: NSRect(x: 0, y: 230 * s, width: size, height: 260 * s), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
