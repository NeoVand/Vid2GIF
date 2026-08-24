// Generates AppIcon.icns: dark cloudy slate icon with a soft GIF wordmark.
// Run: swift Resources/make_icon.swift
import AppKit

func drawIcon(size s: CGFloat) {

    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = s * 0.2
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Base: deep slate vertical gradient.
    NSGradient(colors: [
        NSColor(calibratedRed: 0.215, green: 0.245, blue: 0.30, alpha: 1),   // #37404D top
        NSColor(calibratedRed: 0.075, green: 0.086, blue: 0.11, alpha: 1),   // #13161C bottom
    ])!.draw(in: shape, angle: -90)

    shape.setClip()

    // Cloud layers: big soft radial glows in desaturated blue-grays.
    func cloud(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ alpha: CGFloat, light: Bool) {
        let color = light
            ? NSColor(calibratedRed: 0.62, green: 0.68, blue: 0.76, alpha: alpha)
            : NSColor(calibratedRed: 0.32, green: 0.37, blue: 0.45, alpha: alpha)
        let g = NSGradient(starting: color, ending: color.withAlphaComponent(0))!
        g.draw(
            fromCenter: NSPoint(x: rect.minX + rect.width * cx, y: rect.minY + rect.height * cy),
            radius: 0,
            toCenter: NSPoint(x: rect.minX + rect.width * cx, y: rect.minY + rect.height * cy),
            radius: r * rect.width,
            options: []
        )
    }
    cloud(0.22, 0.80, 0.60, 0.50, light: true)
    cloud(0.88, 0.62, 0.55, 0.38, light: true)
    cloud(0.55, 0.25, 0.75, 0.55, light: false)
    cloud(0.12, 0.15, 0.50, 0.45, light: false)
    cloud(0.72, 0.92, 0.45, 0.30, light: true)
    cloud(0.45, 0.55, 0.35, 0.25, light: true)

    // Wordmark with a soft drop shadow.
    let fontSize = s * 0.26
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let text = "V2G" as NSString

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.95, alpha: 1),
        .shadow: shadow,
        .kern: s * 0.01,
    ]
    let tsize = text.size(withAttributes: attrs)
    text.draw(
        at: NSPoint(x: (s - tsize.width) / 2, y: (s - tsize.height) / 2),
        withAttributes: attrs
    )

    // Hairline top highlight for depth.
    let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.004, dy: s * 0.004),
                                 xRadius: radius, yRadius: radius)
    highlight.lineWidth = s * 0.008
    NSColor.white.withAlphaComponent(0.10).setStroke()
    highlight.stroke()

}

let iconset = "Resources/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (name, px) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
print("iconset written")
