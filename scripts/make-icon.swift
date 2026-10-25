import AppKit
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let s = CGFloat(pixels)
        let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
        let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
        NSColor(calibratedRed: 0.87, green: 0.92, blue: 0.88, alpha: 1).setFill(); path.fill()
        let ink = NSColor(calibratedRed: 0.20, green: 0.39, blue: 0.31, alpha: 1)
        ink.setStroke()
        let leaf = NSBezierPath()
        leaf.move(to: NSPoint(x: s * 0.31, y: s * 0.30))
        leaf.curve(to: NSPoint(x: s * 0.76, y: s * 0.74), controlPoint1: NSPoint(x: s * 0.17, y: s * 0.63), controlPoint2: NSPoint(x: s * 0.59, y: s * 0.80))
        leaf.curve(to: NSPoint(x: s * 0.31, y: s * 0.30), controlPoint1: NSPoint(x: s * 0.82, y: s * 0.36), controlPoint2: NSPoint(x: s * 0.57, y: s * 0.20))
        leaf.lineWidth = s * 0.028; leaf.lineCapStyle = .round; leaf.lineJoinStyle = .round; leaf.stroke()
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: s * 0.26, y: s * 0.22))
        stem.curve(to: NSPoint(x: s * 0.65, y: s * 0.64), controlPoint1: NSPoint(x: s * 0.39, y: s * 0.44), controlPoint2: NSPoint(x: s * 0.53, y: s * 0.53))
        stem.lineWidth = s * 0.025; stem.lineCapStyle = .round; stem.stroke()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon rendering failed") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
