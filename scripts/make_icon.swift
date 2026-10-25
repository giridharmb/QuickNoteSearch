// Draws the 1024px app icon: warm squircle, ruled note card, magnifier with a "#" in the lens.
// Usage: swift scripts/make_icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func withShadow(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(alpha)
    sh.shadowBlurRadius = blur
    sh.shadowOffset = NSSize(width: 0, height: -dy)
    sh.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

// 1. Background squircle (macOS grid: 824pt body, 100pt margin).
let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
withShadow(28, 14, 0.30) { rgb(255, 160, 40).setFill(); bg.fill() }
NSGradient(colors: [rgb(255, 214, 74), rgb(255, 150, 28), rgb(240, 96, 30)], atLocations: [0, 0.6, 1],
           colorSpace: .sRGB)!.draw(in: bg, angle: -90)
// Soft top highlight.
NSGraphicsContext.saveGraphicsState()
bg.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// 2. Note card, tilted.
ctx.saveGState()
ctx.translateBy(x: 440, y: 560)
ctx.rotate(by: 7 * .pi / 180)
let card = NSRect(x: -215, y: -270, width: 430, height: 540)
let cardPath = NSBezierPath(roundedRect: card, xRadius: 46, yRadius: 46)
withShadow(30, 16, 0.28) { NSColor.white.setFill(); cardPath.fill() }
NSGradient(colors: [NSColor.white, rgb(250, 246, 236)])!.draw(in: cardPath, angle: -90)
// Title bar line + ruled lines.
rgb(255, 170, 40).setFill()
NSBezierPath(roundedRect: NSRect(x: -160, y: 165, width: 230, height: 34), xRadius: 17, yRadius: 17).fill()
for (i, w) in [320.0, 280, 310, 220, 290].enumerated() {
    rgb(210, 200, 185).setFill()
    NSBezierPath(roundedRect: NSRect(x: -160, y: 95 - CGFloat(i) * 62, width: w, height: 20), xRadius: 10, yRadius: 10).fill()
}
ctx.restoreGState()

// 3. Magnifier.
let c = NSPoint(x: 610, y: 420), r: CGFloat = 175
let handle = NSBezierPath()
handle.lineWidth = 78
handle.lineCapStyle = .round
handle.move(to: NSPoint(x: c.x + r * 0.78, y: c.y - r * 0.78))
handle.line(to: NSPoint(x: 838, y: 192))
withShadow(24, 12, 0.35) { rgb(44, 40, 60).setStroke(); handle.stroke() }

let lens = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
withShadow(26, 12, 0.35) { rgb(44, 40, 60).setFill(); lens.fill() }
let glass = NSBezierPath(ovalIn: NSRect(x: c.x - r + 36, y: c.y - r + 36, width: 2 * r - 72, height: 2 * r - 72))
NSGradient(colors: [rgb(255, 255, 255, 0.97), rgb(225, 238, 255, 0.95)])!.draw(in: glass, angle: -60)

// "#" inside the lens.
let hashFont = NSFont.systemFont(ofSize: 210, weight: .black)
let hash = NSAttributedString(string: "#", attributes: [.font: hashFont, .foregroundColor: rgb(240, 110, 25)])
let hs = hash.size()
hash.draw(at: NSPoint(x: c.x - hs.width / 2, y: c.y - hs.height / 2 + 4))

// Glass glint.
let glint = NSBezierPath()
glint.lineWidth = 16
glint.lineCapStyle = .round
glint.appendArc(withCenter: c, radius: r - 62, startAngle: 105, endAngle: 150)
NSColor.white.withAlphaComponent(0.9).setStroke()
glint.stroke()

// 4. Speed sparkle (top right).
func sparkle(_ p: NSPoint, _ s: CGFloat) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: p.x, y: p.y + s))
    path.curve(to: NSPoint(x: p.x + s, y: p.y), controlPoint1: NSPoint(x: p.x + s * 0.12, y: p.y + s * 0.12), controlPoint2: NSPoint(x: p.x + s * 0.12, y: p.y + s * 0.12))
    path.curve(to: NSPoint(x: p.x, y: p.y - s), controlPoint1: NSPoint(x: p.x + s * 0.12, y: p.y - s * 0.12), controlPoint2: NSPoint(x: p.x + s * 0.12, y: p.y - s * 0.12))
    path.curve(to: NSPoint(x: p.x - s, y: p.y), controlPoint1: NSPoint(x: p.x - s * 0.12, y: p.y - s * 0.12), controlPoint2: NSPoint(x: p.x - s * 0.12, y: p.y - s * 0.12))
    path.curve(to: NSPoint(x: p.x, y: p.y + s), controlPoint1: NSPoint(x: p.x - s * 0.12, y: p.y + s * 0.12), controlPoint2: NSPoint(x: p.x - s * 0.12, y: p.y + s * 0.12))
    withShadow(10, 3, 0.18) { NSColor.white.setFill(); path.fill() }
}
sparkle(NSPoint(x: 790, y: 790), 62)
sparkle(NSPoint(x: 718, y: 860), 26)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
