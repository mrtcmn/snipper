import AppKit
import SnipperCore
import SwiftUI

/// The spatial "atlas": cards arranged in rings around the center, best match in the middle.
/// Cards shrink and fade toward the edges like a lens. Drag or two-finger scroll to pan,
/// pinch or ⌘-scroll to zoom.
struct AtlasField: View {
    let items: [DisplayItem]
    let isSearching: Bool
    var onOpen: (Snip) -> Void

    @State private var camera: CGPoint = .zero
    @State private var dragStart: CGPoint?
    @State private var zoom: CGFloat = 1
    @State private var pinchStart: CGFloat?
    @State private var hoverInside = false
    @State private var scrollMonitor: Any?
    /// Mirrors `items.count` for the scroll monitor, which outlives a single body evaluation.
    @State private var itemCount = 0

    private let tileSize: CGFloat = 232
    private let pitch: CGFloat = 252

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + 6)
            let cells = AtlasLayout.cells(count: items.count)
            let placed = place(cells: cells, viewport: size, center: center)

            ZStack {
                Color.clear.contentShape(Rectangle())
                ForEach(placed, id: \.item.id) { entry in
                    SnipCard(item: entry.item, style: .tile, showMatch: isSearching)
                        .frame(width: tileSize, height: tileSize)
                        .scaleEffect(entry.scale * zoom)
                        .opacity(entry.opacity)
                        .position(entry.point)
                        .zIndex(Double(entry.scale))
                        .onTapGesture { onOpen(entry.item.snip) }
                        .contextMenu { SnipContextMenu(snip: entry.item.snip) }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .gesture(panGesture)
            .simultaneousGesture(pinchGesture)
            .onContinuousHover { phase in
                if case .active = phase { hoverInside = true } else { hoverInside = false }
            }
            .onAppear {
                itemCount = items.count
                installScrollMonitor()
            }
            .onChange(of: items.count) { _, count in itemCount = count }
            .onDisappear(perform: removeScrollMonitor)
            .onChange(of: items.first?.id) { _, _ in
                // A new search result order: bring the best match back to the center.
                withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { camera = .zero }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.84), value: items.map(\.id))
        }
    }

    // MARK: Layout

    private struct Placed {
        let item: DisplayItem
        let point: CGPoint
        let scale: CGFloat
        let opacity: Double
    }

    private func place(cells: [CGPoint], viewport: CGSize, center: CGPoint) -> [Placed] {
        let radius = max(240, min(viewport.width, viewport.height) * 0.56)
        let effectivePitch = pitch * zoom
        let margin = tileSize * zoom
        var result: [Placed] = []
        result.reserveCapacity(min(items.count, 160))
        let topScore = items.first?.score ?? 0

        for (i, item) in items.enumerated() where i < cells.count {
            let world = CGPoint(x: cells[i].x * effectivePitch, y: cells[i].y * effectivePitch)
            let raw = CGPoint(x: center.x + world.x - camera.x * zoom, y: center.y + world.y - camera.y * zoom)
            guard raw.x > -margin, raw.x < viewport.width + margin, raw.y > -margin, raw.y < viewport.height + margin else { continue }

            let dx = raw.x - center.x, dy = raw.y - center.y
            let d = hypot(dx, dy) / radius
            let lens = smoothstep(0.28, 1.45, d)
            let scale = 1 - 0.36 * lens
            // Pull outer cards slightly inward so the shrinking doesn't open gaps.
            let pull = 1 - 0.12 * smoothstep(0.3, 1.7, d)
            let point = CGPoint(x: center.x + dx * pull, y: center.y + dy * pull)
            var opacity = Double(1 - 0.6 * smoothstep(1.05, 2.0, d))
            if isSearching, let score = item.score, topScore > 0 {
                // Weaker matches recede.
                let relative = max(0, min(1, (score - (topScore - 0.35)) / 0.35))
                opacity *= 0.35 + 0.65 * Double(relative)
            }
            result.append(Placed(item: item, point: point, scale: scale, opacity: opacity))
        }
        return result
    }

    private func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil { dragStart = camera }
                guard let start = dragStart else { return }
                camera = CGPoint(x: start.x - value.translation.width / zoom, y: start.y - value.translation.height / zoom)
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                dragStart = nil
                let predicted = CGPoint(
                    x: start.x - value.predictedEndTranslation.width / zoom,
                    y: start.y - value.predictedEndTranslation.height / zoom
                )
                withAnimation(.smooth(duration: 0.6)) { camera = clampCamera(predicted) }
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = zoom }
                zoom = max(0.55, min(1.6, (pinchStart ?? 1) * value.magnification))
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Keeps the camera within the populated area.
    private func clampCamera(_ p: CGPoint) -> CGPoint {
        let extent = AtlasLayout.extent(count: itemCount) * pitch
        return CGPoint(x: max(-extent, min(extent, p.x)), y: max(-extent, min(extent, p.y)))
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            guard hoverInside, event.window?.isKeyWindow == true else { return event }
            if event.modifierFlags.contains(.command) {
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300 : event.scrollingDeltaY / 30
                zoom = max(0.55, min(1.6, zoom * (1 + delta)))
            } else {
                let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                camera = clampCamera(CGPoint(
                    x: camera.x - event.scrollingDeltaX * factor / zoom,
                    y: camera.y - event.scrollingDeltaY * factor / zoom
                ))
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}

/// Positions for the atlas: a honeycomb of cells ordered by distance from the center,
/// so index 0 is in the middle and later items form rings around it.
@MainActor
enum AtlasLayout {
    private static var cache: [Int: [CGPoint]] = [:]

    static func cells(count: Int) -> [CGPoint] {
        let needed = max(1, count)
        // Reuse a larger layout when possible: prefixes are stable.
        if let hit = cache.first(where: { $0.key >= needed })?.value { return Array(hit.prefix(needed)) }
        let rings = Int((Double(needed) / 3).squareRoot().rounded(.up)) + 2
        var points: [CGPoint] = []
        for row in -rings...rings {
            for col in -rings...rings {
                let x = CGFloat(col) + (row % 2 == 0 ? 0 : 0.5)
                let y = CGFloat(row) * 0.9
                points.append(CGPoint(x: x, y: y))
            }
        }
        points.sort { a, b in
            let da = a.x * a.x + a.y * a.y, db = b.x * b.x + b.y * b.y
            if abs(da - db) > 0.0001 { return da < db }
            return atan2(a.y, a.x) < atan2(b.y, b.x)
        }
        let size = max(needed, 64)
        let result = Array(points.prefix(size))
        if cache.count > 8 { cache.removeAll() }
        cache[size] = result
        return Array(result.prefix(needed))
    }

    /// How far (in cells) the layout reaches from the center.
    static func extent(count: Int) -> CGFloat {
        CGFloat((Double(max(1, count)) / 3).squareRoot()) + 1
    }
}

/// Actions available on every card.
struct SnipContextMenu: View {
    let snip: Snip
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { model.viewerID = snip.id }
        Button("Copy", systemImage: "doc.on.doc") { model.copy(snip) }
        Button("Copy as Markdown", systemImage: "doc.richtext") { model.copyMarkdown(snip) }
        if snip.url != nil {
            Button("Open Original", systemImage: "safari") { model.openOriginal(snip) }
        }
        Divider()
        Button(snip.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: snip.isFavorite ? "star.slash" : "star") {
            model.toggleFavorite(snip.id)
        }
        Button("Find Similar", systemImage: "sparkles") { model.showSimilar(to: snip.id) }
            .disabled(!model.index.hasVector(snip.id))
        if snip.kind == .screenshot || snip.kind == .image {
            Button("Annotate", systemImage: "pencil.and.outline") { model.annotate(snip) }
            Button("Pin to Screen", systemImage: "pin") { model.pin(snip) }
        }
        if !snip.media.compactMap(\.localFile).isEmpty {
            Button("Show in Finder", systemImage: "folder") { model.revealInFinder(snip) }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { model.delete([snip.id]) }
    }
}
