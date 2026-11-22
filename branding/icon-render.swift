// Renders the Dora the Explorer app icon (1024×1024 PNG).
// Usage: swift icon-render.swift <output.png>
import AppKit
import CoreGraphics

let size = CGFloat(1024)
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// ---------- squircle background ----------
let margin = CGFloat(100)
let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let bg = CGPath(
    roundedRect: rect, cornerWidth: 232, cornerHeight: 232,
    transform: nil
)
ctx.addPath(bg)
ctx.clip()

// Deep-sea vertical gradient.
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(srgbRed: 0.043, green: 0.149, blue: 0.220, alpha: 1),   // #0b2638
        CGColor(srgbRed: 0.075, green: 0.310, blue: 0.373, alpha: 1),   // #134f5f
        CGColor(srgbRed: 0.106, green: 0.427, blue: 0.529, alpha: 1),   // #1b6d87
    ] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: size / 2, y: size),
    end: CGPoint(x: size / 2, y: 0),
    options: []
)

// Faint nautical map contours.
func strokeMapLines() {
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.95, blue: 0.85, alpha: 0.10))
    ctx.setLineWidth(6)
    for i in 0..<7 {
        let y = CGFloat(180 + i * 110)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 120, y: y + 40))
        path.addCurve(
            to: CGPoint(x: size - 120, y: y),
            control1: CGPoint(x: 340, y: y + 130),
            control2: CGPoint(x: 660, y: y - 130)
        )
        ctx.addPath(path)
    }
    ctx.strokePath()
    ctx.restoreGState()
}
strokeMapLines()

// ---------- helper: glassy rounded rect path ----------
func folderPath(back: Bool) -> CGPath {
    let folderRect = CGRect(x: 232, y: 280, width: 560, height: 420)
    let tabHeight = CGFloat(74)
    let tab = CGRect(x: 232, y: 280 + 420 - tabHeight, width: 210, height: tabHeight)
    let radius = CGFloat(56)

    let path = CGMutablePath()
    // Tab with rounded top corners.
    path.addRoundedRect(
        in: CGRect(x: tab.minX, y: tab.minY, width: tab.width, height: tab.height + radius),
        cornerWidth: radius, cornerHeight: radius
    )
    // Body.
    path.addRoundedRect(
        in: folderRect,
        cornerWidth: radius, cornerHeight: radius
    )
    return path
}

// Back panel (slightly lighter, offset up).
ctx.saveGState()
ctx.translateBy(x: 0, y: 26)
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 60,
              color: CGColor(srgbRed: 0, green: 0.05, blue: 0.10, alpha: 0.55))
ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.75, blue: 0.82, alpha: 0.35))
ctx.addPath(folderPath(back: true))
ctx.fillPath()
ctx.restoreGState()

// Front panel: glass gradient fill.
let glass = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(srgbRed: 0.62, green: 0.80, blue: 0.88, alpha: 0.55),
        CGColor(srgbRed: 0.30, green: 0.56, blue: 0.70, alpha: 0.45),
        CGColor(srgbRed: 0.10, green: 0.35, blue: 0.50, alpha: 0.55),
    ] as CFArray,
    locations: [0.0, 0.45, 1.0]
)!
// The glass fill must respect the union silhouette: draw into a mask.
let mask = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
mask.addPath(folderPath(back: true))
mask.setFillColor(CGColor(gray: 1, alpha: 1))
mask.fillPath()
let maskImage = mask.makeImage()!

ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 0, width: size, height: size), mask: maskImage)
ctx.drawLinearGradient(
    glass,
    start: CGPoint(x: 512, y: 740),
    end: CGPoint(x: 512, y: 250),
    options: []
)
// Glass top-light band.
let sheen = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.50),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    sheen,
    start: CGPoint(x: 512, y: 740),
    end: CGPoint(x: 512, y: 560),
    options: []
)
ctx.restoreGState()

// Crisp glass rim.
ctx.saveGState()
ctx.addPath(folderPath(back: false))
ctx.setStrokeColor(CGColor(srgbRed: 0.85, green: 0.94, blue: 0.98, alpha: 0.5))
ctx.setLineWidth(8)
ctx.strokePath()
ctx.restoreGState()

// ---------- compass rose (embossed brass) ----------
func drawCompassRose() {
    let center = CGPoint(x: 512, y: 460)
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)

    // Soft emboss shadow.
    for (dx, dy) in [(0, -5), (0, 5)] {
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(dx), y: CGFloat(-dy))

        // 4 long points + 4 short diamonds.
        let gold = CGColor(srgbRed: 0.914, green: 0.741, blue: 0.404, alpha: 1)   // #EABD67
        let cream = CGColor(srgbRed: 0.988, green: 0.949, blue: 0.855, alpha: 1)   // #FCF2DA
        let outline = CGColor(srgbRed: 0.45, green: 0.32, blue: 0.12, alpha: 1)

        func point(_ angle: CGFloat, _ long: CGFloat, _ short: CGFloat, fill: CGColor) {
            let path = CGMutablePath()
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: short * cos(angle + .pi / 2), y: short * sin(angle + .pi / 2)))
            path.addLine(to: CGPoint(x: long * cos(angle), y: long * sin(angle)))
            path.addLine(to: CGPoint(x: short * cos(angle - .pi / 2), y: short * sin(angle - .pi / 2)))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(4)
            ctx.strokePath()
        }

        for i in 0..<4 {
            let angle = CGFloat(i) * .pi / 2
            point(angle, 150, 34, fill: i == 0 ? cream : gold)          // long, cardinal
            point(angle + .pi / 4, 88, 22, fill: gold)                    // short, intercardinal
        }

        // Hub.
        ctx.saveGState()
        let hub = CGPath(
            ellipseIn: CGRect(x: -26, y: -26, width: 52, height: 52), transform: nil
        )
        ctx.addPath(hub)
        ctx.setFillColor(CGColor(srgbRed: 0.988, green: 0.949, blue: 0.855, alpha: 1))
        ctx.fillPath()
        ctx.addPath(hub)
        ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.32, blue: 0.12, alpha: 1))
        ctx.setLineWidth(6)
        ctx.strokePath()
        let needle = CGMutablePath()
        needle.move(to: CGPoint(x: 0, y: 14))
        needle.addLine(to: CGPoint(x: -9, y: -14))
        needle.addLine(to: CGPoint(x: 9, y: -14))
        needle.closeSubpath()
        ctx.addPath(needle)
        ctx.setFillColor(CGColor(srgbRed: 0.75, green: 0.11, blue: 0.10, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.restoreGState()
    }
    ctx.restoreGState()
}
drawCompassRose()

// ---------- finish: soft top light + vignette ----------
let topLight = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    topLight,
    start: CGPoint(x: 512, y: size - margin), end: CGPoint(x: 512, y: size * 0.6),
    options: []
)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
