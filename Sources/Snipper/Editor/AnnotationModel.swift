import AppKit
import CoreImage
import Observation
import SwiftUI

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, line, pen, highlighter, text, pixelate, counter, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .pixelate: "Pixelate"
        case .counter: "Step counter"
        case .crop: "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .pixelate: "checkerboard.rectangle"
        case .counter: "1.circle"
        case .crop: "crop"
        }
    }

    /// Single-key shortcut.
    var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .pixelate: "b"
        case .counter: "n"
        case .crop: "c"
        }
    }

    var supportsFill: Bool { self == .rectangle || self == .ellipse }
}

struct RGBA: Hashable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    func with(alpha: CGFloat) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    /// Picks black or white text for legibility on this color.
    var contrasting: RGBA {
        (0.299 * r + 0.587 * g + 0.114 * b) > 0.6 ? RGBA(r: 0, g: 0, b: 0) : RGBA(r: 1, g: 1, b: 1)
    }

    static let palette: [RGBA] = [
        RGBA(r: 1.00, g: 0.27, b: 0.33), // red
        RGBA(r: 1.00, g: 0.62, b: 0.04), // orange
        RGBA(r: 1.00, g: 0.84, b: 0.04), // yellow
        RGBA(r: 0.19, g: 0.82, b: 0.35), // green
        RGBA(r: 0.04, g: 0.52, b: 1.00), // blue
        RGBA(r: 0.72, g: 0.91, b: 0.95), // ice
        RGBA(r: 0.75, g: 0.35, b: 0.95), // purple
        RGBA(r: 1.00, g: 1.00, b: 1.00), // white
        RGBA(r: 0.07, g: 0.07, b: 0.09), // black
    ]
}

/// One mark on the image. Coordinates are image pixels, top-left origin.
struct Annotation: Identifiable, Equatable {
    var id = UUID()
    var tool: AnnotationTool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: RGBA
    var lineWidth: CGFloat
    var text = ""
    var fontSize: CGFloat = 32
    var number = 0
    var filled = false

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var counterRadius: CGFloat { max(16, lineWidth * 3.2) }

    /// Approximate bounds for hit testing and selection outlines.
    var bounds: CGRect {
        switch tool {
        case .pen, .highlighter:
            guard let first = points.first else { return .null }
            var r = CGRect(origin: first, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        case .text:
            let size = ((text.isEmpty ? " " : text) as NSString).size(withAttributes: AnnotationRenderer.textAttributes(self))
            return CGRect(origin: start, size: size).insetBy(dx: -6, dy: -4)
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        default:
            return rect.insetBy(dx: -lineWidth - 4, dy: -lineWidth - 4)
        }
    }

    var isDegenerate: Bool {
        switch tool {
        case .pen, .highlighter: points.count < 2
        case .text: text.trimmingCharacters(in: .whitespaces).isEmpty
        case .counter: false
        default: hypot(end.x - start.x, end.y - start.y) < 3
        }
    }

    mutating func offset(by d: CGSize) {
        start.x += d.width; start.y += d.height
        end.x += d.width; end.y += d.height
        points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
    }
}

/// The state of one annotation session, with undo.
@MainActor
@Observable
final class AnnotationDocument {
    let image: CGImage
    /// A pixelated copy used to draw redaction areas.
    let pixelated: CGImage

    var annotations: [Annotation] = []
    var crop: CGRect? = nil
    var tool: AnnotationTool = .arrow {
        didSet { if tool != .select { selectedID = nil } }
    }
    var color: RGBA = RGBA.palette[0]
    var lineWidth: CGFloat
    var filled = false
    var selectedID: UUID? = nil
    var editingTextID: UUID? = nil

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    private struct Snapshot {
        var annotations: [Annotation]
        var crop: CGRect?
    }

    init(image: CGImage) {
        self.image = image
        pixelated = Self.pixelate(image) ?? image
        let longest = CGFloat(max(image.width, image.height))
        lineWidth = min(16, max(3, (longest / 360).rounded()))
    }

    var size: CGSize { CGSize(width: image.width, height: image.height) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var nextCounter: Int { (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1 }

    /// Records the current state before a change.
    func checkpoint() {
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, crop: crop))
        annotations = last.annotations
        crop = last.crop
        selectedID = nil
        editingTextID = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        annotations = next.annotations
        crop = next.crop
    }

    func deleteSelected() {
        guard let selectedID else { return }
        checkpoint()
        annotations.removeAll { $0.id == selectedID }
        self.selectedID = nil
    }

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return annotations.firstIndex { $0.id == id }
    }

    func hitTest(_ p: CGPoint) -> UUID? {
        annotations.last { $0.bounds.contains(p) }?.id
    }

    /// The final image: annotations flattened onto the (cropped) screenshot.
    func render() -> CGImage? {
        AnnotationRenderer.render(base: image, pixelated: pixelated, annotations: annotations, crop: crop)
    }

    private static func pixelate(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let scale = max(8, CGFloat(max(image.width, image.height)) / 70)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: nil).createCGImage(output, from: input.extent)
    }
}
