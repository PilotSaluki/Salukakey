// Renders the DMG background banner: 600x400 logical points.
//
//   swift Tools/make_dmg_background.swift <output.png> [scale]
//
// Finder draws a disk background picture at one image pixel per point and
// picks up a "<name>@2x.png" sibling on Retina displays, so the banner is
// rendered twice: at 1x and at 2x.

import AppKit
import CoreGraphics
import ImageIO

let logicalWidth: CGFloat = 600
let logicalHeight: CGFloat = 400

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: make_dmg_background.swift <output.png> [scale]\n".data(using: .utf8)!)
    exit(2)
}
let outPath = CommandLine.arguments[1]
let scale = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 1.0) : 1.0

let pixelWidth = Int(logicalWidth * scale)
let pixelHeight = Int(logicalHeight * scale)

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil,
                          width: pixelWidth,
                          height: pixelHeight,
                          bitsPerComponent: 8,
                          bytesPerRow: 0,
                          space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("unable to create bitmap context")
}

// Work in top-left origin logical points.
ctx.translateBy(x: 0, y: logicalHeight * scale)
ctx.scaleBy(x: scale, y: -scale)
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// ── Background gradient ─────────────────────────────────────────────
let gradientColors = [
    CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
    CGColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1.0),
    CGColor(srgbRed: 0.89, green: 0.91, blue: 0.95, alpha: 1.0),
] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 0.6, 1.0])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: 0),
                       end: CGPoint(x: logicalWidth, y: logicalHeight),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// ── Soft accent glow behind the arrow ───────────────────────────────
let glowCenter = CGPoint(x: 304, y: 190)
let glowRadius: CGFloat = 200
guard let glowGradient = CGGradient(colorsSpace: colorSpace,
                                    colors: [
                                        CGColor(srgbRed: 0.20, green: 0.52, blue: 1.0, alpha: 0.16),
                                        CGColor(srgbRed: 0.20, green: 0.52, blue: 1.0, alpha: 0.0),
                                    ] as CFArray,
                                    locations: [0.0, 1.0]) else {
    fatalError("unable to create glow gradient")
}
ctx.drawRadialGradient(glowGradient,
                       startCenter: glowCenter, startRadius: 0,
                       endCenter: glowCenter, endRadius: glowRadius,
                       options: [.drawsAfterEndLocation])

// ── Arrow (app on the left → Applications on the right) ─────────────
let arrow = CGMutablePath()
arrow.addRoundedRect(in: CGRect(x: 248, y: 183, width: 84, height: 14),
                     cornerWidth: 7, cornerHeight: 7)
arrow.move(to: CGPoint(x: 330, y: 172))
arrow.addLine(to: CGPoint(x: 360, y: 190))
arrow.addLine(to: CGPoint(x: 330, y: 208))
arrow.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 3),
              blur: 12,
              color: CGColor(srgbRed: 0.0, green: 0.24, blue: 0.62, alpha: 0.45))
guard let arrowGradient = CGGradient(colorsSpace: colorSpace,
                                     colors: [
                                         CGColor(srgbRed: 0.22, green: 0.60, blue: 1.0, alpha: 1.0),
                                         CGColor(srgbRed: 0.00, green: 0.38, blue: 0.87, alpha: 1.0),
                                     ] as CFArray,
                                     locations: [0.0, 1.0]) else {
    fatalError("unable to create arrow gradient")
}
ctx.addPath(arrow)
ctx.clip()
ctx.drawLinearGradient(arrowGradient,
                       start: CGPoint(x: 0, y: 172),
                       end: CGPoint(x: 0, y: 208),
                       options: [])
ctx.restoreGState()

// ── Caption ─────────────────────────────────────────────────────────
let caption = "Drag SalukaKey to Applications"
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center

let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -1)
shadow.shadowBlurRadius = 4
shadow.shadowColor = NSColor.white.withAlphaComponent(0.9)

let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
    .foregroundColor: NSColor(red: 0.24, green: 0.25, blue: 0.28, alpha: 1.0),
    .paragraphStyle: paragraph,
    .shadow: shadow,
]

let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsContext
NSAttributedString(string: caption, attributes: attributes)
    .draw(in: NSRect(x: 0, y: logicalHeight - 62, width: logicalWidth, height: 26))
NSGraphicsContext.restoreGraphicsState()

// ── Write PNG ───────────────────────────────────────────────────────
guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: outPath) as CFURL,
        "public.png" as CFString,
        1,
        nil
      ) else {
    fatalError("unable to create PNG destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("unable to write PNG")
}

print("✓ Background written: \(outPath) (\(pixelWidth)x\(pixelHeight) px)")
