import AppKit
import QuartzCore
import SnipperCore
import SwiftUI

/// The library globe: equal 4:3 cards in a brick grid that repeats in every direction, bent
/// onto a large sphere like the EmbeddingGemma 2 WebGPU demo. The best match sits in the
/// center. Drag or scroll to pan, pinch or ⌘-scroll to zoom at the pointer.
///
/// Each card is a `SnipCard` rendered once into an image. A frame only moves Core Animation
/// layers, so panning costs layer transforms, not SwiftUI layout.
struct GlobeField: NSViewRepresentable {
    let items: [DisplayItem]
    let isSearching: Bool
    var onOpen: (Snip) -> Void

    func makeNSView(context: Context) -> GlobeView { GlobeView() }

    func updateNSView(_ view: GlobeView, context: Context) {
        view.onOpen = onOpen
        view.update(items: items, isSearching: isSearching)
    }
}

@MainActor
final class GlobeView: NSView {
    var onOpen: ((Snip) -> Void)?

    private static let card = SnipCard.tileSize
    private static let pitch = CGSize(width: card.width + 22, height: card.height + 22)
    private static let radius: CGFloat = 34
    private static let zoomRange: ClosedRange<CGFloat> = 0.3...2.2
    /// Below this many items one copy of the grid is shown instead of an endless repeat.
    private static let minimumToRepeat = 12
    private static let maxInstances = 1_200
    private static let maxCachedImages = 240
    private static let placeholder = NSColor(Theme.surface).withAlphaComponent(0.72).cgColor

    private struct Key: Hashable {
        let index: Int
        let copyX: Int
        let copyY: Int
    }

    /// A card on screen this frame, kept for hit testing and accessibility.
    private struct Hit {
        let key: Key
        let item: DisplayItem
        let frame: CGRect
        let depth: CGFloat
    }

    private struct CardImage {
        let snip: Snip
        let image: CGImage
        var lastUsed: CFTimeInterval
    }

    // Content
    private var items: [DisplayItem] = []
    private var isSearching = false
    private var grid = GlobeLayout(count: 0, cellAspect: 1)
    private var appearedAt: [UUID: CFTimeInterval] = [:]
    private var images: [UUID: CardImage] = [:]
    private var renderQueue: [UUID] = []
    private var renderTask: Task<Void, Never>?

    // Camera, in world points. The field repeats, so x and y have no bounds.
    private var camera = CGPoint.zero
    private var target = CGPoint.zero
    private var velocity = CGPoint.zero // world points per 60 Hz frame
    private var zoom: CGFloat = 1
    private var targetZoom: CGFloat = 1
    private var zoomAnchor: (world: CGPoint, screen: CGPoint)?
    private var tilt = CGPoint.zero
    private var tiltTarget = CGPoint.zero
    private var shift: CGFloat = 0
    private var lastFrame: CFTimeInterval?

    // Input
    private var dragStart: CGPoint?
    private var dragMoved = false
    private var lastDrag: (point: CGPoint, time: CFTimeInterval)?
    private var hoverKey: Key?

    // Layers
    private let scene = CALayer()
    private var live: [Key: CALayer] = [:]
    private var spare: [CALayer] = []
    private var hits: [Hit] = []
    private var link: CADisplayLink?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        root.addSublayer(scene)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Library")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            link?.invalidate()
            link = nil
            return
        }
        if link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        wake()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.frame = bounds
        CATransaction.commit()
        wake()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Content

    func update(items newItems: [DisplayItem], isSearching searching: Bool) {
        let oldIDs = items.map(\.id)
        let newIDs = newItems.map(\.id)
        let restart = newIDs.first != oldIDs.first || searching != isSearching
        items = newItems
        isSearching = searching
        if oldIDs != newIDs {
            grid = GlobeLayout(count: newItems.count, cellAspect: Self.pitch.width / Self.pitch.height)
            let now = CACurrentMediaTime()
            let old = Set(oldIDs)
            var appeared: [UUID: CFTimeInterval] = [:]
            // A new search brings every card in; otherwise only new cards fade in and the rest stay put.
            for id in newIDs { appeared[id] = restart || !old.contains(id) ? now : (appearedAt[id] ?? 0) }
            appearedAt = appeared
            if restart {
                target = .zero
                velocity = .zero
                zoomAnchor = nil
            }
        }
        wake()
    }

    // MARK: Frame loop

    private func wake() {
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastFrame.map { now - $0 } ?? 1.0 / 60
        lastFrame = now
        let moving = step(dt: dt)
        let animating = render(now: now)
        if !moving, !animating, renderQueue.isEmpty, dragStart == nil {
            link.isPaused = true
            lastFrame = nil
        }
    }

    /// Advances the camera. Returns whether it is still moving.
    private func step(dt: CFTimeInterval) -> Bool {
        let r = CGFloat(min(2, max(0.2, dt * 60)))
        let previous = camera
        if dragStart == nil, hypot(velocity.x, velocity.y) > 0.05 {
            target.x += velocity.x * r
            target.y += velocity.y * r
            velocity.x *= pow(0.88, r)
            velocity.y *= pow(0.88, r)
            zoomAnchor = nil
        }
        let ease = reduceMotion ? 1 : 1 - pow(0.84, r)
        zoom = exp(log(zoom) + (log(targetZoom) - log(zoom)) * ease)
        if let anchor = zoomAnchor {
            camera = CGPoint(x: anchor.world.x - anchor.screen.x / zoom, y: anchor.world.y - anchor.screen.y / zoom)
            if abs(zoom - targetZoom) < targetZoom * 0.0005 { zoomAnchor = nil }
        } else {
            camera.x += (target.x - camera.x) * ease
            camera.y += (target.y - camera.y) * ease
        }

        // Fast moves pull the camera back a little; the pointer tilts the globe a little.
        let p = perspective
        let speed = hypot(camera.x - previous.x, camera.y - previous.y) * zoom / r
        let shiftTarget = reduceMotion ? 0 : -p * 0.095 * tanh(speed / (p * 0.065))
        let follow = reduceMotion ? 1 : 1 - pow(0.89, r)
        shift += (shiftTarget - shift) * follow
        let wantedTilt = reduceMotion ? .zero : tiltTarget
        tilt.x += (wantedTilt.x - tilt.x) * follow
        tilt.y += (wantedTilt.y - tilt.y) * follow

        return hypot(target.x - camera.x, target.y - camera.y) * zoom > 0.05
            || abs(zoom - targetZoom) > targetZoom * 0.0005
            || hypot(velocity.x, velocity.y) > 0.05
            || abs(shift - shiftTarget) > 0.1
            || hypot(wantedTilt.x - tilt.x, wantedTilt.y - tilt.y) > 0.0002
    }

    /// The demo's sphere and perspective scale with the window.
    private var unit: CGFloat { max(bounds.width, bounds.height, 1) / 1728 }
    private var perspective: CGFloat { 1200 * unit }
    private var sphereRadius: CGFloat { 5000 * unit }

    /// Places every visible card. Returns whether an entrance animation is still running.
    private func render(now: CFTimeInterval) -> Bool {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let p = perspective
        let radius = sphereRadius
        var sublayer = CATransform3DIdentity
        sublayer.m34 = -1 / p
        scene.sublayerTransform = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeRotation(tilt.y, 1, 0, 0), CATransform3DMakeRotation(tilt.x, 0, 1, 0)),
            sublayer
        )

        let size = bounds.size
        let card = Self.card
        let repeats = items.count >= Self.minimumToRepeat
        let periodX = CGFloat(grid.columns) * Self.pitch.width
        let periodY = CGFloat(grid.rows) * Self.pitch.height
        let halfW = size.width / 2 / zoom + card.width
        let halfH = size.height / 2 / zoom + card.height
        let topScore = items.first?.score ?? 0
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        var used: [Key: CALayer] = [:]
        var newHits: [Hit] = []
        var animating = false

        outer: for (index, cell) in grid.cells.enumerated() where index < items.count {
            let item = items[index]
            let wx = CGFloat(cell.x) * Self.pitch.width
            let wy = CGFloat(cell.y) * Self.pitch.height
            // Copies of this cell inside the view. A stride, because a range would trap when none fits.
            let xs = repeats ? stride(from: Int(((camera.x - halfW - wx) / periodX).rounded(.up)), through: Int(((camera.x + halfW - wx) / periodX).rounded(.down)), by: 1) : stride(from: 0, through: 0, by: 1)
            let ys = repeats ? stride(from: Int(((camera.y - halfH - wy) / periodY).rounded(.up)), through: Int(((camera.y + halfH - wy) / periodY).rounded(.down)), by: 1) : stride(from: 0, through: 0, by: 1)
            for copyY in ys {
                for copyX in xs {
                    if used.count >= Self.maxInstances { break outer }
                    let dx = (wx + CGFloat(copyX) * periodX - camera.x) * zoom
                    let dy = (wy + CGFloat(copyY) * periodY - camera.y) * zoom
                    guard abs(dx) < size.width / 2 + card.width * zoom, abs(dy) < size.height / 2 + card.height * zoom else { continue }

                    let key = Key(index: index, copyX: copyX, copyY: copyY)
                    let layer = live.removeValue(forKey: key) ?? makeLayer()
                    used[key] = layer
                    let entrance = appear(item.id, rank: index, now: now)
                    if entrance < 1 { animating = true }

                    // Bend the flat offset onto the sphere and face the card outward.
                    let theta = dx / radius, phi = dy / radius
                    let a = (x: sin(theta) * cos(phi), y: sin(phi), z: cos(theta) * cos(phi))
                    let position = (x: a.x * radius, y: a.y * radius, z: (a.z - 1) * radius + shift)
                    let hovered = key == hoverKey
                    let scale = zoom * (0.92 + 0.08 * entrance) * (hovered ? 1.035 : 1)
                    var transform = CATransform3DMakeScale(scale, scale, 1)
                    let axis = hypot(a.y, a.x)
                    if axis > 1e-9 {
                        transform = CATransform3DConcat(transform, CATransform3DMakeRotation(acos(min(1, a.z)), -a.y / axis, a.x / axis, 0))
                    }
                    transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(position.x, position.y, position.z))
                    layer.transform = transform
                    layer.zPosition = hovered ? 1 : 0

                    var opacity = Float(entrance)
                    if isSearching, let score = item.score, topScore > 0 {
                        // Weaker matches recede.
                        opacity *= 0.35 + 0.65 * Float(max(0, min(1, (score - (topScore - 0.35)) / 0.35)))
                    }
                    layer.opacity = opacity
                    show(item, in: layer, now: now)

                    let f = p / (p - position.z)
                    let w = card.width * scale * f, h = card.height * scale * f
                    let screen = CGPoint(x: center.x + position.x * f, y: center.y + position.y * f)
                    newHits.append(Hit(key: key, item: item, frame: CGRect(x: screen.x - w / 2, y: screen.y - h / 2, width: w, height: h), depth: position.z))
                }
            }
        }

        for (_, layer) in live {
            layer.isHidden = true
            spare.append(layer)
        }
        live = used
        hits = newHits.sorted { $0.depth > $1.depth }
        return animating
    }

    private func makeLayer() -> CALayer {
        if let layer = spare.popLast() {
            layer.isHidden = false
            return layer
        }
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: Self.card)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.cornerRadius = Self.radius
        layer.cornerCurve = .continuous
        layer.contentsGravity = .resize
        layer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: Self.card), cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.38
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 10)
        scene.addSublayer(layer)
        return layer
    }

    /// 0 → 1 as a card fades in; new cards start from the center outward.
    private func appear(_ id: UUID, rank: Int, now: CFTimeInterval) -> CGFloat {
        guard !reduceMotion, let start = appearedAt[id], start > 0 else { return 1 }
        let delay = min(0.3, Double(rank).squareRoot() * 0.03)
        let t = max(0, min(1, (now - start - delay) / 0.35))
        if t >= 1 { appearedAt[id] = 0 }
        return CGFloat(t * t * (3 - 2 * t))
    }

    // MARK: Card images

    private func show(_ item: DisplayItem, in layer: CALayer, now: CFTimeInterval) {
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        if var cached = images[item.id] {
            cached.lastUsed = now
            images[item.id] = cached
            if (layer.contents as AnyObject?) !== cached.image { layer.contents = cached.image }
            layer.backgroundColor = nil
            if cached.snip == item.snip { return }
        } else {
            layer.contents = nil
            layer.backgroundColor = Self.placeholder
        }
        if !renderQueue.contains(item.id) { renderQueue.append(item.id) }
        if renderTask == nil { renderTask = Task { [weak self] in await self?.drainRenderQueue() } }
    }

    /// Loads each queued card's images, then renders it. One card at a time, so frames keep coming.
    private func drainRenderQueue() async {
        defer { renderTask = nil }
        while !renderQueue.isEmpty {
            let id = renderQueue.removeFirst()
            guard let snip = items.first(where: { $0.id == id })?.snip else { continue }
            for image in SnipCard.tileImages(snip) {
                _ = await ImageLoader.shared.image(for: image.source, maxPixels: image.maxPixels)
            }
            guard let current = items.first(where: { $0.id == id })?.snip, let image = renderCard(current) else { continue }
            images[id] = CardImage(snip: current, image: image, lastUsed: CACurrentMediaTime())
            evictImages()
            wake()
            await Task.yield()
        }
    }

    private func renderCard(_ snip: Snip) -> CGImage? {
        let renderer = ImageRenderer(content:
            SnipCard(item: DisplayItem(snip: snip), style: .tile)
                .frame(width: Self.card.width, height: Self.card.height)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = window?.backingScaleFactor ?? 2
        renderer.isOpaque = false
        return renderer.cgImage
    }

    /// ponytail: least-recently-shown eviction at a fixed count; size it by memory if libraries get huge.
    private func evictImages() {
        guard images.count > Self.maxCachedImages else { return }
        let onScreen = Set(live.keys.map { items[$0.index].id })
        let old = images.filter { !onScreen.contains($0.key) }.sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (id, _) in old.prefix(images.count - Self.maxCachedImages) { images[id] = nil }
    }

    // MARK: Input

    private func offsetFromCenter(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
    }

    private func zoom(by factor: CGFloat, at point: CGPoint) {
        let screen = offsetFromCenter(point)
        let world = CGPoint(x: target.x + screen.x / targetZoom, y: target.y + screen.y / targetZoom)
        targetZoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, targetZoom * factor))
        target = CGPoint(x: world.x - screen.x / targetZoom, y: world.y - screen.y / targetZoom)
        zoomAnchor = (world, screen)
        velocity = .zero
        wake()
    }

    private func hit(at point: CGPoint) -> Hit? {
        hits.first { $0.frame.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragMoved = false
        lastDrag = (point, event.timestamp)
        velocity = .zero
        zoomAnchor = nil
        wake()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let last = lastDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - start.x, point.y - start.y) > 4 { dragMoved = true }
        let dx = (point.x - last.point.x) / targetZoom, dy = (point.y - last.point.y) / targetZoom
        target.x -= dx
        target.y -= dy
        let frames = max(1, (event.timestamp - last.time) * 60)
        velocity = CGPoint(x: -dx / frames, y: -dy / frames)
        lastDrag = (point, event.timestamp)
        hoverKey = nil
        wake()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            lastDrag = nil
            wake()
        }
        // A pause before letting go means no throw.
        if let last = lastDrag, event.timestamp - last.time > 0.08 { velocity = .zero }
        guard !dragMoved, let hit = hit(at: convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(hit.item.snip)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300 : event.scrollingDeltaY / 30
            zoom(by: 1 + delta, at: point)
            return
        }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        target.x -= event.scrollingDeltaX * factor / targetZoom
        target.y -= event.scrollingDeltaY * factor / targetZoom
        velocity = .zero
        zoomAnchor = nil
        wake()
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        tiltTarget = CGPoint(x: -(point.x / max(1, bounds.width) * 2 - 1) * 0.05, y: (point.y / max(1, bounds.height) * 2 - 1) * 0.05)
        let key = hit(at: point)?.key
        if key != hoverKey {
            hoverKey = key
            (key == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        }
        wake()
    }

    override func mouseExited(with event: NSEvent) {
        hoverKey = nil
        tiltTarget = .zero
        NSCursor.arrow.set()
        wake()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let hit = hit(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return SnipMenu.make(for: hit.item.snip, model: AppModel.shared)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        var seen = Set<UUID>()
        return hits.compactMap { hit -> NSAccessibilityElement? in
            guard seen.insert(hit.item.id).inserted, let window else { return nil }
            let element = CardElement(open: { [weak self] in self?.onOpen?(hit.item.snip) })
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(hit.item.snip.displayTitle)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrame(window.convertToScreen(convert(hit.frame, to: nil)))
            return element
        }
    }
}

private final class CardElement: NSAccessibilityElement {
    private let open: () -> Void

    init(open: @escaping () -> Void) {
        self.open = open
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        open()
        return true
    }
}

/// The card context menu for AppKit, matching `SnipContextMenu`.
@MainActor
enum SnipMenu {
    static func make(for snip: Snip, model: AppModel) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ActionMenuItem(title: title, action: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Open", "arrow.up.left.and.arrow.down.right") { model.viewerID = snip.id }
        add("Copy", "doc.on.doc") { model.copy(snip) }
        add("Copy as Markdown", "doc.richtext") { model.copyMarkdown(snip) }
        if snip.url != nil { add("Open Original", "safari") { model.openOriginal(snip) } }
        menu.addItem(.separator())
        add(snip.isFavorite ? "Remove from Favorites" : "Add to Favorites", snip.isFavorite ? "star.slash" : "star") { model.toggleFavorite(snip.id) }
        add("Find Similar", "sparkles", enabled: model.index.hasVector(snip.id)) { model.showSimilar(to: snip.id) }
        if snip.kind == .screenshot || snip.kind == .image {
            add("Annotate", "pencil.and.outline") { model.annotate(snip) }
            add("Pin to Screen", "pin") { model.pin(snip) }
        }
        if !snip.media.compactMap(\.localFile).isEmpty { add("Show in Finder", "folder") { model.revealInFinder(snip) } }
        menu.addItem(.separator())
        add("Delete", "trash") { model.delete([snip.id]) }
        menu.autoenablesItems = false
        return menu
    }
}

private final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
