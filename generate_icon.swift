#!/usr/bin/env swift
import AppKit

// Draws the Ballast icon: a level-meter of uneven bars on the brand-blue
// gradient, all crossed by one bright horizontal line — "many loudnesses,
// brought to a single even level." CG coordinate origin: bottom-left.
func drawIcon(ctx: CGContext, s: CGFloat) {
    let cs = CGColorSpaceCreateDeviceRGB()

    // ── 1. Background: dark-blue gradient rounded rect (#004080 family). ──
    let bgRadius = s * 0.22
    let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                        cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bgGrad = CGGradient(
        colorsSpace: cs,
        colors: [CGColor(red: 0.05, green: 0.32, blue: 0.58, alpha: 1),
                 CGColor(red: 0.00, green: 0.20, blue: 0.42, alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(bgGrad,
                           start: CGPoint(x: s / 2, y: s),
                           end:   CGPoint(x: s / 2, y: 0),
                           options: [])
    ctx.restoreGState()

    // ── 2. Level-meter bars of uneven height. ──
    // Fractional heights (of the usable band) that read as "varied loudness".
    let heights: [CGFloat] = [0.34, 0.62, 0.46, 0.78, 0.42, 0.58, 0.36]
    let count = CGFloat(heights.count)
    let sideInset = s * 0.20
    let bandBottom = s * 0.22
    let bandHeight = s * 0.56
    let usableWidth = s - sideInset * 2
    let gapRatio: CGFloat = 0.45                       // gap width as a fraction of a bar
    let barWidth = usableWidth / (count + (count - 1) * gapRatio)
    let gap = barWidth * gapRatio
    let barRadius = barWidth * 0.32

    for (i, h) in heights.enumerated() {
        let x = sideInset + CGFloat(i) * (barWidth + gap)
        let barH = bandHeight * h
        let rect = CGRect(x: x, y: bandBottom, width: barWidth, height: barH)
        let path = CGPath(roundedRect: rect, cornerWidth: barRadius, cornerHeight: barRadius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let grad = CGGradient(colorsSpace: cs,
                              colors: [CGColor(red: 0.96, green: 0.97, blue: 1.00, alpha: 1),
                                       CGColor(red: 0.72, green: 0.80, blue: 0.92, alpha: 1)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end:   CGPoint(x: rect.midX, y: rect.minY),
                               options: [])
        ctx.restoreGState()
    }

    // ── 3. The single bright "even level" line across every bar. ──
    let lineY = bandBottom + bandHeight * 0.50
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006),
                  blur: s * 0.03,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.setStrokeColor(CGColor(red: 1.00, green: 0.82, blue: 0.32, alpha: 1.0))  // warm accent
    ctx.setLineWidth(s * 0.045)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: sideInset - barWidth * 0.2, y: lineY))
    ctx.addLine(to: CGPoint(x: s - sideInset + barWidth * 0.2, y: lineY))
    ctx.strokePath()
    ctx.restoreGState()
}

// ── Render at a given pixel size. ──
func renderIcon(pixels: Int) -> Data? {
    guard let bmp = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: NSColorSpaceName.deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    guard let ctx = NSGraphicsContext(bitmapImageRep: bmp)?.cgContext else { return nil }
    drawIcon(ctx: ctx, s: CGFloat(pixels))
    return bmp.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
}

// ── Main. ──
let destDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let sizes: [(String, Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",   128),
    ("icon_128x128@2x.png",256),
    ("icon_256x256.png",   256),
    ("icon_256x256@2x.png",512),
    ("icon_512x512.png",   512),
    ("icon_512x512@2x.png",1024),
]

for (filename, pixels) in sizes {
    if let data = renderIcon(pixels: pixels) {
        let url = URL(fileURLWithPath: destDir).appendingPathComponent(filename)
        try! data.write(to: url)
        print("\u{2713}  \(filename)  (\(pixels)px)")
    } else {
        print("\u{2717}  Failed: \(filename)")
    }
}
print("Done.")
