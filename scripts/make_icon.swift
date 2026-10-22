import AppKit

// Usage: swift make_icon.swift <output.iconset dir>
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: s * 0.07, y: s * 0.07, width: s * 0.86, height: s * 0.86)
    let tile = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.05, green: 0.06, blue: 0.16, alpha: 1), NSColor(red: 0.17, green: 0.10, blue: 0.36, alpha: 1)])!.draw(in: tile, angle: -60)

    // gradient ring: draw gradient clipped to an annulus
    let c = NSPoint(x: s / 2, y: s / 2)
    let ringR = s * 0.27, w = s * 0.07
    NSGraphicsContext.saveGraphicsState()
    let annulus = NSBezierPath()
    annulus.appendOval(in: NSRect(x: c.x - ringR - w / 2, y: c.y - ringR - w / 2, width: (ringR + w / 2) * 2, height: (ringR + w / 2) * 2))
    annulus.appendOval(in: NSRect(x: c.x - ringR + w / 2, y: c.y - ringR + w / 2, width: (ringR - w / 2) * 2, height: (ringR - w / 2) * 2))
    annulus.windingRule = .evenOdd
    annulus.addClip()
    NSGradient(colors: [NSColor(red: 0.24, green: 0.84, blue: 1, alpha: 1), NSColor(red: 0.64, green: 0.42, blue: 1, alpha: 1), NSColor(red: 1, green: 0.42, blue: 0.72, alpha: 1)])!
        .draw(in: rect, angle: -45)
    NSGraphicsContext.restoreGraphicsState()

    // ascending bars inside the ring
    let heights: [CGFloat] = [0.10, 0.17, 0.25]
    let bw = s * 0.055, gap = s * 0.03
    let total = bw * 3 + gap * 2
    for (i, h) in heights.enumerated() {
        let x = c.x - total / 2 + CGFloat(i) * (bw + gap)
        let r = NSRect(x: x, y: c.y - s * 0.12, width: bw, height: s * h)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: r, xRadius: bw / 2, yRadius: bw / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                              ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes { try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png")) }
