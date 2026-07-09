import AppKit

/// A Core Graphics VU meter pair — real typography (numbered dB scale + "VU"),
/// vector arcs/ticks, a brass bevel and an even backlight. Static artwork is
/// cached to an image; only the ballistic needles redraw each frame. Shown in
/// the visualiser's "VU Meters" mode instead of the Metal view.
final class VUMeterView: NSView {

    private var posL: CGFloat = 0, velL: CGFloat = 0
    private var posR: CGFloat = 0, velR: CGFloat = 0
    private var timer: Timer?
    private var faceCache: NSImage?
    private var faceCacheSize: CGSize = .zero

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    weak var controller: VisualizerController?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: controller?.cycleMode(-1)
        case 124: controller?.cycleMode(1)
        case 53:  controller?.hide()
        case 3:   controller?.toggleFullScreen()
        default:  super.keyDown(with: event)
        }
    }

    func start() {
        stop()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let dt: CGFloat = 1.0 / 60.0, k: CGFloat = 120, c: CGFloat = 16
        let tL = min(1, CGFloat(VisualizerFeed.shared.levelL) * 3.5)
        let tR = min(1, CGFloat(VisualizerFeed.shared.levelR) * 3.5)
        velL += (k * (tL - posL) - c * velL) * dt; posL = max(0, min(1.05, posL + velL * dt))
        velR += (k * (tR - posR) - c * velR) * dt; posR = max(0, min(1.05, posR + velR * dt))
        needsDisplay = true
    }

    // MARK: Layout (proportions of the view; no fixed pixel sizes)

    private struct Meter { let rect: CGRect; let pivot: CGPoint; let arcR: CGFloat; let aStart: CGFloat; let aEnd: CGFloat }
    private let dbMarks: [(String, CGFloat, Bool)] = [
        ("20", -20, false), ("10", -10, false), ("7", -7, false), ("5", -5, false),
        ("3", -3, false), ("2", -2, false), ("1", -1, false), ("0", 0, false),
        ("1", 1, true), ("2", 2, true), ("3", 3, true),
    ]
    private var ampMin: CGFloat { pow(10, -20 / 20) }
    private var ampMax: CGFloat { pow(10, 3 / 20) }
    private func frac(_ db: CGFloat) -> CGFloat { (pow(10, db / 20) - ampMin) / (ampMax - ampMin) }
    private func angle(_ m: Meter, _ f: CGFloat) -> CGFloat { m.aStart + f * (m.aEnd - m.aStart) }

    private func meters() -> [Meter] {
        let b = bounds
        // Fixed landscape aspect, centred; the housing fills the leftover space,
        // so the meters keep their proportions at any window shape.
        let aspect: CGFloat = 1.3          // meter width : height
        let gapF: CGFloat = 0.10           // gap as a fraction of meter height
        let mh = min(b.width * 0.90 / (2 * aspect + gapF), b.height * 0.80)
        let mw = aspect * mh, gap = gapF * mh
        let groupW = 2 * mw + gap
        let x0 = b.midX - groupW / 2, y0 = b.midY - mh / 2
        return [x0, x0 + mw + gap].map { x -> Meter in
            let r = CGRect(x: x, y: y0, width: mw, height: mh)
            let arcR = mh * 0.60
            let pivot = CGPoint(x: r.midX, y: r.minY + mh * 0.07)
            let desiredHalf = asin(min(0.98, (mw * 0.44) / arcR)) * 180 / .pi
            let half = min(42, desiredHalf)
            return Meter(rect: r, pivot: pivot, arcR: arcR, aStart: 90 + half, aEnd: 90 - half)
        }
    }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if faceCache == nil || faceCacheSize != bounds.size { faceCache = renderFace(); faceCacheSize = bounds.size }
        faceCache?.draw(in: bounds)
        let ms = meters()
        drawNeedle(ctx, ms[0], pos: posL)
        drawNeedle(ctx, ms[1], pos: posR)
    }

    private func point(_ m: Meter, _ deg: CGFloat, _ radius: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: m.pivot.x + cos(a) * radius, y: m.pivot.y + sin(a) * radius)
    }

    private func drawNeedle(_ ctx: CGContext, _ m: Meter, pos: CGFloat) {
        let tip = point(m, angle(m, min(max(pos, 0), 1)), m.arcR * 0.97)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.07, alpha: 1).cgColor)
        ctx.setLineCap(.round)
        ctx.setLineWidth(max(1.1, m.rect.height * 0.011))
        ctx.move(to: m.pivot); ctx.addLine(to: tip); ctx.strokePath()
        let hubR = m.rect.height * 0.028
        ctx.setFillColor(NSColor(calibratedWhite: 0.13, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: m.pivot.x - hubR, y: m.pivot.y - hubR, width: hubR * 2, height: hubR * 2))
        ctx.restoreGState()
    }

    private func renderFace() -> NSImage {
        NSImage(size: bounds.size, flipped: false) { [self] _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.15, blue: 0.16, alpha: 1),
                                NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)])?
                .draw(in: NSBezierPath(rect: bounds), angle: -90)
            let red = NSColor(calibratedRed: 0.80, green: 0.13, blue: 0.07, alpha: 1)
            let ink = NSColor(calibratedWhite: 0.11, alpha: 1)

            for m in meters() {
                let mh = m.rect.height
                let bez = m.rect.insetBy(dx: -m.rect.width * 0.03, dy: -mh * 0.035)
                NSGradient(colors: [NSColor(calibratedRed: 0.62, green: 0.48, blue: 0.24, alpha: 1),
                                    NSColor(calibratedRed: 0.24, green: 0.17, blue: 0.08, alpha: 1)])?
                    .draw(in: NSBezierPath(roundedRect: bez, xRadius: mh * 0.10, yRadius: mh * 0.10), angle: 90)
                let facePath = NSBezierPath(roundedRect: m.rect, xRadius: mh * 0.07, yRadius: mh * 0.07)
                NSGradient(colors: [NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.81, alpha: 1),
                                    NSColor(calibratedRed: 0.86, green: 0.76, blue: 0.54, alpha: 1)])?
                    .draw(in: facePath, relativeCenterPosition: NSPoint(x: 0, y: -0.4))
                ctx.saveGState(); facePath.addClip()

                // arcs
                arc(ctx, m, from: angle(m, frac(0)), to: m.aEnd, radius: m.arcR, width: mh * 0.020, color: red)
                arc(ctx, m, from: m.aStart, to: angle(m, frac(0)), radius: m.arcR, width: mh * 0.009, color: ink)

                // minor ticks (even, subtle)
                for i in 0...36 {
                    let a = m.aStart + CGFloat(i) / 36 * (m.aEnd - m.aStart)
                    stroke(ctx, from: point(m, a, m.arcR), to: point(m, a, m.arcR + mh * 0.028),
                           width: mh * 0.004, color: ink.withAlphaComponent(0.55))
                }
                // major ticks + numbers
                let font = NSFont.systemFont(ofSize: mh * 0.072, weight: .semibold)
                for (label, db, isRed) in dbMarks {
                    let a = angle(m, frac(db)), col = isRed ? red : ink
                    stroke(ctx, from: point(m, a, m.arcR), to: point(m, a, m.arcR + mh * 0.05), width: mh * 0.007, color: col)
                    draw(label, at: point(m, a, m.arcR + mh * 0.105), font: font, color: col)
                }
                // "VU" lower-left, modest
                draw("VU", at: CGPoint(x: m.rect.minX + m.rect.width * 0.15, y: m.rect.minY + mh * 0.16),
                     font: NSFont.systemFont(ofSize: mh * 0.11, weight: .heavy), color: ink)
                ctx.restoreGState()
            }
            return true
        }
    }

    private func arc(_ ctx: CGContext, _ m: Meter, from: CGFloat, to: CGFloat, radius: CGFloat, width: CGFloat, color: NSColor) {
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width); ctx.setLineCap(.butt)
        ctx.addArc(center: m.pivot, radius: radius, startAngle: min(from, to) * .pi / 180,
                   endAngle: max(from, to) * .pi / 180, clockwise: false)
        ctx.strokePath()
    }
    private func stroke(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, width: CGFloat, color: NSColor) {
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width); ctx.setLineCap(.round)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
    }
    private func draw(_ s: String, at center: CGPoint, font: NSFont, color: NSColor) {
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = s.size(withAttributes: attr)
        s.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2), withAttributes: attr)
    }
}
