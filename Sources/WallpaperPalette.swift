import AppKit
import CoreGraphics
import ImageIO

enum VisualizerColourSource: String, CaseIterable {
    case builtin, match, complement
    var displayName: String {
        switch self {
        case .builtin:    return "Built-in"
        case .match:      return "Match wallpaper"
        case .complement: return "Complement wallpaper"
        }
    }
}

/// Derives a small colour palette from the desktop wallpaper so the visualiser
/// can tint itself to match or complement the user's desktop.
enum WallpaperPalette {

    /// Three RGB colours (low / mid / accent) from the wallpaper on `screen`,
    /// or nil for the built-in palette / when nothing usable can be extracted
    /// (solid-colour or near-greyscale desktops).
    static func colours(source: VisualizerColourSource, screen: NSScreen?) -> [SIMD3<Float>]? {
        guard source != .builtin, let base = dominantHSB(screen: screen) else { return nil }
        var hue = base.h
        if source == .complement { hue = (hue + 0.5).truncatingRemainder(dividingBy: 1.0) }
        let sat = max(0.45, min(0.95, base.s))
        let bri = max(0.55, min(1.0, base.b + 0.10))
        func rgb(_ h: Double, _ s: Double, _ v: Double) -> SIMD3<Float> {
            var hh = h.truncatingRemainder(dividingBy: 1.0); if hh < 0 { hh += 1 }
            let c = NSColor(calibratedHue: CGFloat(hh), saturation: CGFloat(s), brightness: CGFloat(v), alpha: 1)
            return SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
        }
        return [rgb(hue - 0.06, sat, bri * 0.85), rgb(hue, sat, bri), rgb(hue + 0.06, sat * 0.9, min(1, bri * 1.1))]
    }

    /// Saturation-weighted dominant hue + mean saturation/brightness of the
    /// wallpaper, sampled at low resolution.
    private static func dominantHSB(screen: NSScreen?) -> (h: Double, s: Double, b: Double)? {
        guard let scr = screen ?? NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: scr),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))

        var sumX = 0.0, sumY = 0.0, sumSat = 0.0, sumBri = 0.0, weight = 0.0
        for i in 0..<(n * n) {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            let sat = mx == 0 ? 0 : d / mx
            var h = 0.0
            if d > 0 {
                if mx == r { h = (g - b) / d } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
                h /= 6; if h < 0 { h += 1 }
            }
            let w = sat * sat
            sumX += cos(h * 2 * .pi) * w; sumY += sin(h * 2 * .pi) * w
            sumSat += sat; sumBri += mx; weight += w
        }
        if weight < 0.05 { return nil }                       // essentially greyscale
        var h = atan2(sumY, sumX) / (2 * .pi); if h < 0 { h += 1 }
        let count = Double(n * n)
        return (h, sumSat / count, sumBri / count)
    }
}
