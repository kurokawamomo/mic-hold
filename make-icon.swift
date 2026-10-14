// Draws the MicHold icon (Big Sur style rounded tile with a microphone) as an iconset.
import AppKit

func draw(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let s = size / 1024
        let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
        shadow.shadowBlurRadius = 24 * s
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [NSColor(red: 0.98, green: 0.36, blue: 0.30, alpha: 1), NSColor(red: 0.78, green: 0.14, blue: 0.40, alpha: 1)])!
            .draw(in: tile, angle: -90)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        let cx = 512 * s
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: cx - 82 * s, y: 450 * s, width: 164 * s, height: 290 * s), xRadius: 82 * s, yRadius: 82 * s).fill()

        NSColor.white.setStroke()
        let arc = NSBezierPath()
        arc.lineWidth = 36 * s
        arc.lineCapStyle = .round
        arc.appendArc(withCenter: NSPoint(x: cx, y: 520 * s), radius: 150 * s, startAngle: 180, endAngle: 360, clockwise: false)
        arc.stroke()
        let stem = NSBezierPath()
        stem.lineWidth = 36 * s
        stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: cx, y: 370 * s)); stem.line(to: NSPoint(x: cx, y: 300 * s))
        stem.move(to: NSPoint(x: cx - 80 * s, y: 300 * s)); stem.line(to: NSPoint(x: cx + 80 * s, y: 300 * s))
        stem.stroke()
        return true
    }
}

let dir = CommandLine.arguments[1]
let sizes: [(String, CGFloat)] = [("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128), ("128@2x", 256), ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024)]
for (name, px) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(size: px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let base = name.hasSuffix("@2x") ? "icon_\(name.dropLast(3))x\(name.dropLast(3))@2x.png" : "icon_\(name)x\(name).png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(base)"))
}
