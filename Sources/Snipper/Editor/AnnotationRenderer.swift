import AppKit
import CoreGraphics

/// Draws annotations with Core Graphics. The same code renders the live canvas and the
/// exported image, so what you see is what you get.
///
/// Every function expects a context whose user space has a top-left origin with y pointing
/// down, measured in image pixels.
enum AnnotationRenderer {
    static func textAttributes(_ a: Annotation) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = a.fontSize * 0.12
        shadow.shadowOffset = .zero
        return [
            .font: NSFont.systemFont(ofSize: a.fontSize, weight: .bold),
            .foregroundColor: a.color.nsColor,
            .shadow: shadow,
        ]
    }

    static func draw(_ annotations: [Annotation], in ctx: CGContext, pixelated: CGImage, imageSize: CGSize) {
        // Redactions go first so later marks stay visible on top of them.
        for a in annotations where a.tool == .pixelate { drawPixelate(a, ctx, pixelated, imageSize) }
        for a in annotations where a.tool != .pixelate { draw(a, in: ctx) }
    }

    static func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(a.lineWidth)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)

        switch a.tool {
        case .arrow:
            ctx.setShadow(offset: .zero, blur: a.lineWidth * 1.4, color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(arrowPath(from: a.start, to: a.end, width: a.lineWidth))
            ctx.fillPath()

        case .line:
            ctx.setShadow(offset: .zero, blur: a.lineWidth, color: CGColor(gray: 0, alpha: 0.3))
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()

        case .rectangle:
            let r = a.rect
            let path = CGPath(roundedRect: r, cornerWidth: min(a.lineWidth * 1.5, r.width / 2), cornerHeight: min(a.lineWidth * 1.5, r.height / 2), transform: nil)
            ctx.addPath(path)
            if a.filled { ctx.fillPath() } else {
                ctx.setShadow(offset: .zero, blur: a.lineWidth, color: CGColor(gray: 0, alpha: 0.3))
                ctx.strokePath()
            }

        case .ellipse:
            ctx.addEllipse(in: a.rect)
            if a.filled { ctx.fillPath() } else {
                ctx.setShadow(offset: .zero, blur: a.lineWidth, color: CGColor(gray: 0, alpha: 0.3))
                ctx.strokePath()
            }

        case .pen:
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()

        case .highlighter:
            ctx.setLineCap(.square)
            ctx.setLineWidth(a.lineWidth * 5)
            ctx.setStrokeColor(a.color.with(alpha: 0.38).cgColor)
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()

        case .text:
            drawText(a.text, at: a.start, attributes: textAttributes(a), in: ctx)

        case .counter:
            let r = a.counterRadius
            let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
            ctx.setShadow(offset: .zero, blur: r * 0.4, color: CGColor(gray: 0, alpha: 0.4))
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(max(2, r * 0.12))
            ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.15, weight: .heavy),
                .foregroundColor: a.color.contrasting.nsColor,
            ]
            let label = "\(a.number)" as NSString
            let size = label.size(withAttributes: attributes)
            drawText(label as String, at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2), attributes: attributes, in: ctx)

        case .pixelate, .select, .crop:
            break
        }
    }

    private static func drawPixelate(_ a: Annotation, _ ctx: CGContext, _ pixelated: CGImage, _ imageSize: CGSize) {
        let r = a.rect
        guard r.width > 1, r.height > 1 else { return }
        ctx.saveGState()
        ctx.clip(to: r)
        drawImage(pixelated, in: CGRect(origin: .zero, size: imageSize), ctx: ctx)
        ctx.restoreGState()
    }

    /// Draws a CGImage upright in a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func drawText(_ text: String, at point: CGPoint, attributes: [NSAttributedString.Key: Any], in ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (text as NSString).draw(at: point, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A tapered arrow: a shaft that widens toward a solid head.
    static func arrowPath(from s: CGPoint, to e: CGPoint, width w: CGFloat) -> CGPath {
        let dx = e.x - s.x, dy = e.y - s.y
        let length = hypot(dx, dy)
        let path = CGMutablePath()
        guard length > 1 else { return path }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let headLength = min(length * 0.5, max(w * 4.2, 18))
        let headHalf = headLength * 0.55
        let base = CGPoint(x: e.x - ux * headLength, y: e.y - uy * headLength)
        func p(_ origin: CGPoint, _ along: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + nx * side + ux * along, y: origin.y + ny * side + uy * along)
        }
        path.move(to: p(s, 0, w * 0.22))
        path.addLine(to: p(base, headLength * 0.12, w * 0.55))
        path.addLine(to: p(base, 0, headHalf))
        path.addLine(to: e)
        path.addLine(to: p(base, 0, -headHalf))
        path.addLine(to: p(base, headLength * 0.12, -w * 0.55))
        path.addLine(to: p(s, 0, -w * 0.22))
        path.closeSubpath()
        return path
    }

    /// A freehand stroke smoothed with quadratic curves through segment midpoints.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Flattens everything into a new image, optionally cropped.
    static func render(base: CGImage, pixelated: CGImage, annotations: [Annotation], crop: CGRect?) -> CGImage? {
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let area = (crop?.intersection(full)).flatMap { $0.width >= 1 && $0.height >= 1 ? $0.integral : nil } ?? full
        let space = base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: Int(area.width),
            height: Int(area.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Switch to a top-left origin and move the crop area to (0, 0).
        ctx.translateBy(x: 0, y: area.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        ctx.interpolationQuality = .high
        drawImage(base, in: full, ctx: ctx)
        draw(annotations, in: ctx, pixelated: pixelated, imageSize: full.size)
        return ctx.makeImage()
    }
}
