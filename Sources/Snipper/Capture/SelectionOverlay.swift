import AppKit
import Carbon.HIToolbox
import SwiftUI

enum CaptureMode: String {
    case region, window, screen, text
}

enum CaptureAction {
    /// Whatever the user chose in Settings › Capture.
    case standard
    case save, copy, annotate, pin, ocr
}

enum SelectionResult {
    /// `rect` is in the screen's top-left-origin points.
    case region(screen: Int, rect: CGRect)
    case window(WindowInfo, screen: Int)
    case screen(Int)
}

/// One capture interaction across all screens: a frozen overlay per display.
@MainActor
final class SelectionSession {
    let frozen: [FrozenScreen]
    let windows: [WindowInfo]
    private(set) var mode: CaptureMode
    private var overlays: [SelectionOverlayWindow] = []
    private var completion: (((SelectionResult, CaptureAction))?) -> Void
    private var finished = false

    init(frozen: [FrozenScreen], windows: [WindowInfo], mode: CaptureMode, completion: @escaping (((SelectionResult, CaptureAction))?) -> Void) {
        self.frozen = frozen
        self.windows = windows
        self.mode = mode
        self.completion = completion
    }

    func begin() {
        for (index, screen) in frozen.enumerated() {
            let window = SelectionOverlayWindow(session: self, index: index, frozen: screen, windows: windows)
            overlays.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        let target = overlays.first { NSMouseInRect(mouse, $0.frame, false) } ?? overlays.first
        target?.makeKeyAndOrderFront(nil)
        if let view = target?.overlayView { _ = target?.makeFirstResponder(view) }
    }

    func setMode(_ mode: CaptureMode, from index: Int) {
        if mode == .screen {
            finish(.screen(index), action: .standard)
            return
        }
        self.mode = mode
        overlays.forEach { $0.overlayView.modeDidChange() }
    }

    func selectionBegan(on index: Int) {
        for overlay in overlays where overlay.overlayView.index != index {
            overlay.overlayView.clearSelection()
        }
    }

    func finish(_ result: SelectionResult, action: CaptureAction) {
        end(with: (result, action))
    }

    func cancel() {
        end(with: nil)
    }

    /// Hides the overlays at once, but releases them (and reports) on the next turn of the
    /// run loop: this is usually called from inside one of their own event handlers.
    private func end(with outcome: (SelectionResult, CaptureAction)?) {
        guard !finished else { return }
        finished = true
        overlays.forEach { $0.orderOut(nil) }
        NSCursor.arrow.set()
        Task { @MainActor in
            for overlay in self.overlays { overlay.close() }
            self.overlays.removeAll()
            self.completion(outcome)
        }
    }
}

final class SelectionOverlayWindow: NSWindow {
    let overlayView: SelectionOverlayView

    init(session: SelectionSession, index: Int, frozen: FrozenScreen, windows: [WindowInfo]) {
        overlayView = SelectionOverlayView(session: session, index: index, frozen: frozen, windows: windows)
        super.init(contentRect: frozen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(frozen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none

        // The frozen screenshot is the window's backdrop; the overlay view draws on top of it.
        let container = NSView(frame: NSRect(origin: .zero, size: frozen.frame.size))
        container.wantsLayer = true
        container.layer?.contents = frozen.image
        container.layer?.contentsGravity = .resize
        overlayView.frame = container.bounds
        overlayView.autoresizingMask = [.width, .height]
        container.addSubview(overlayView)
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draws the dimmed backdrop, the selection with handles, crosshair and magnifier,
/// and handles all mouse and keyboard input during a capture.
final class SelectionOverlayView: NSView {
    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: r.minX, y: r.minY)
            case .top: CGPoint(x: r.midX, y: r.minY)
            case .topRight: CGPoint(x: r.maxX, y: r.minY)
            case .right: CGPoint(x: r.maxX, y: r.midY)
            case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
            case .bottom: CGPoint(x: r.midX, y: r.maxY)
            case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
            case .left: CGPoint(x: r.minX, y: r.midY)
            }
        }

        var cursor: NSCursor {
            switch self {
            case .left, .right: .resizeLeftRight
            case .top, .bottom: .resizeUpDown
            default: .crosshair
            }
        }
    }

    private enum Interaction {
        case idle
        case dragging(origin: CGPoint)
        case selected
        case moving(grab: CGPoint, original: CGRect)
        case resizing(Handle, original: CGRect)
    }

    weak var session: SelectionSession?
    let index: Int
    private let frozen: FrozenScreen
    private let localWindows: [(info: WindowInfo, rect: CGRect)]
    private var interaction: Interaction = .idle
    private var selection: CGRect?
    private var mouse: CGPoint?
    private var mouseDownPoint: CGPoint?
    private var hoveredWindow: (info: WindowInfo, rect: CGRect)?
    private var toolbar: NSHostingView<CaptureToolbar>?
    private var hint: NSHostingView<CaptureHint>?
    private var tracking: NSTrackingArea?

    private let dimColor = NSColor.black.withAlphaComponent(0.42)
    private let accent = NSColor(red: 0.72, green: 0.91, blue: 0.95, alpha: 1)

    init(session: SelectionSession, index: Int, frozen: FrozenScreen, windows: [WindowInfo]) {
        self.session = session
        self.index = index
        self.frozen = frozen
        let bounds = CGRect(origin: .zero, size: frozen.frame.size)
        localWindows = windows.compactMap { info in
            let rect = ScreenCoordinates.local(info.cgFrame, in: frozen.frame).intersection(bounds)
            return rect.width >= 20 && rect.height >= 20 ? (info, rect) : nil
        }
        super.init(frame: bounds)
        installHint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var mode: CaptureMode { session?.mode ?? .region }

    // MARK: Tracking and cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at p: CGPoint) {
        if let toolbar, toolbar.frame.contains(p) { NSCursor.arrow.set(); return }
        if let hint, hint.frame.contains(p) { NSCursor.arrow.set(); return }
        if case .selected = interaction, let selection {
            if let handle = handle(at: p, in: selection) { handle.cursor.set(); return }
            if selection.contains(p) { NSCursor.openHand.set(); return }
        }
        if mode == .window { NSCursor.pointingHand.set() } else { NSCursor.crosshair.set() }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        if mode == .window || (mode == .region && selection == nil) {
            hoveredWindow = localWindows.first { $0.rect.contains(p) }
        }
        updateCursor(at: p)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let p = clamp(convert(event.locationInWindow, from: nil))
        mouseDownPoint = p
        if event.clickCount == 2, case .selected = interaction, let selection, selection.contains(p) {
            confirm(.standard)
            return
        }
        if case .selected = interaction, let selection {
            if let handle = handle(at: p, in: selection) {
                interaction = .resizing(handle, original: selection)
                return
            }
            if selection.contains(p) {
                interaction = .moving(grab: p, original: selection)
                NSCursor.closedHand.set()
                return
            }
        }
        removeToolbar()
        session?.selectionBegan(on: index)
        selection = nil
        interaction = .dragging(origin: p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        mouse = p
        switch interaction {
        case .dragging(let origin):
            var rect = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y), width: abs(p.x - origin.x), height: abs(p.y - origin.y))
            if event.modifierFlags.contains(.shift) {
                let side = max(rect.width, rect.height)
                rect.size = CGSize(width: side, height: side)
                if p.x < origin.x { rect.origin.x = origin.x - side }
                if p.y < origin.y { rect.origin.y = origin.y - side }
                rect = rect.intersection(bounds)
            }
            selection = rect
        case .moving(let grab, let original):
            var rect = original.offsetBy(dx: p.x - grab.x, dy: p.y - grab.y)
            rect.origin.x = min(max(0, rect.origin.x), bounds.width - rect.width)
            rect.origin.y = min(max(0, rect.origin.y), bounds.height - rect.height)
            selection = rect
            positionToolbar()
        case .resizing(let handle, let original):
            selection = resized(original, handle: handle, to: p)
            positionToolbar()
        case .idle, .selected:
            break
        }
        hint?.isHidden = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        defer { needsDisplay = true }
        switch interaction {
        case .dragging:
            let moved = mouseDownPoint.map { hypot($0.x - p.x, $0.y - p.y) } ?? 0
            if moved < 4 {
                // A click: capture or select the window under the pointer.
                selection = nil
                if let hovered = localWindows.first(where: { $0.rect.contains(p) }) {
                    if mode == .window {
                        session?.finish(.window(hovered.info, screen: index), action: .standard)
                        return
                    }
                    selection = hovered.rect
                    interaction = .selected
                    showToolbar()
                } else {
                    interaction = .idle
                    hint?.isHidden = false
                }
                return
            }
            guard let selection, selection.width >= 4, selection.height >= 4 else {
                self.selection = nil
                interaction = .idle
                return
            }
            if mode == .text {
                session?.finish(.region(screen: index, rect: selection), action: .ocr)
                return
            }
            interaction = .selected
            showToolbar()
        case .moving, .resizing:
            interaction = .selected
            if let selection { self.selection = selection.standardized }
            positionToolbar()
        case .idle, .selected:
            break
        }
        updateCursor(at: p)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let code = Int(event.keyCode)
        switch code {
        case kVK_Escape:
            if case .selected = interaction, mode != .window {
                clearSelection()
            } else {
                session?.cancel()
            }
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            confirm(.standard)
            return
        case kVK_Space:
            session?.setMode(mode == .window ? .region : .window, from: index)
            return
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            nudge(code, step: event.modifierFlags.contains(.shift) ? 10 : 1, resize: event.modifierFlags.contains(.option))
            return
        default:
            break
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "s": confirm(.save)
        case "c": confirm(.copy)
        case "a": confirm(.annotate)
        case "p": confirm(.pin)
        case "t": confirm(.ocr)
        default: super.keyDown(with: event)
        }
    }

    private func nudge(_ code: Int, step: CGFloat, resize: Bool) {
        guard case .selected = interaction, var rect = selection else { return }
        let dx: CGFloat = code == kVK_LeftArrow ? -step : (code == kVK_RightArrow ? step : 0)
        let dy: CGFloat = code == kVK_UpArrow ? -step : (code == kVK_DownArrow ? step : 0)
        if resize {
            rect.size.width = max(4, rect.width + dx)
            rect.size.height = max(4, rect.height + dy)
        } else {
            rect = rect.offsetBy(dx: dx, dy: dy)
        }
        selection = rect.intersection(bounds)
        positionToolbar()
        needsDisplay = true
    }

    private func confirm(_ action: CaptureAction) {
        guard case .selected = interaction, let selection else { return }
        session?.finish(.region(screen: index, rect: selection), action: action)
    }

    // MARK: Session callbacks

    func clearSelection() {
        selection = nil
        interaction = .idle
        removeToolbar()
        hint?.isHidden = false
        needsDisplay = true
    }

    func modeDidChange() {
        clearSelection()
        installHint()
        if let mouse { hoveredWindow = localWindows.first { $0.rect.contains(mouse) } }
        needsDisplay = true
    }

    // MARK: Geometry

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }

    private func handle(at p: CGPoint, in rect: CGRect) -> Handle? {
        Handle.allCases.first { hypot($0.point(in: rect).x - p.x, $0.point(in: rect).y - p.y) < 9 }
    }

    private func resized(_ r: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let isDragging: Bool = { if case .dragging = interaction { return true }; return false }()

        if let selection, selection.width > 0, selection.height > 0 {
            dim(except: selection)
            drawSelection(selection, handles: !isDragging)
            drawSizeLabel(for: selection)
        } else if let hovered = hoveredWindow, mode == .window || (mode == .region && !isDragging) {
            dim(except: hovered.rect)
            drawWindowHighlight(hovered)
        } else {
            dimColor.setFill()
            bounds.fill()
        }

        if let mouse, mode != .window, isDragging || selection == nil {
            drawCrosshair(at: mouse)
            drawLoupe(at: mouse)
        }
    }

    private func dim(except hole: CGRect) {
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: hole))
        path.windingRule = .evenOdd
        dimColor.setFill()
        path.fill()
    }

    private func drawSelection(_ r: CGRect, handles: Bool) {
        let glow = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5))
        glow.lineWidth = 3
        accent.withAlphaComponent(0.35).setStroke()
        glow.stroke()
        let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.95).setStroke()
        border.stroke()
        guard handles else { return }
        for handle in Handle.allCases {
            let p = handle.point(in: r)
            let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
            NSColor.white.setFill()
            dot.fill()
            accent.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    private func drawSizeLabel(for r: CGRect) {
        let scale = frozen.pixelScale
        let text = "\(Int((r.width * scale).rounded())) × \(Int((r.height * scale).rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var origin = CGPoint(x: r.minX, y: r.minY - size.height - 12)
        if origin.y < 4 { origin.y = r.minY + 6; origin.x = r.minX + 6 }
        let pill = CGRect(x: origin.x, y: origin.y, width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 3), withAttributes: attributes)
    }

    private func drawWindowHighlight(_ hovered: (info: WindowInfo, rect: CGRect)) {
        let r = hovered.rect
        accent.withAlphaComponent(0.14).setFill()
        r.fill(using: .sourceOver)
        let border = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        border.lineWidth = 2
        accent.setStroke()
        border.stroke()

        let label = hovered.info.appName + (hovered.info.title.isEmpty ? "" : " — \(hovered.info.title)")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = String(label.prefix(80)) as NSString
        let size = text.size(withAttributes: attributes)
        let pill = CGRect(x: r.midX - size.width / 2 - 10, y: r.midY - size.height / 2 - 5, width: size.width + 20, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 10, y: pill.minY + 5), withAttributes: attributes)
    }

    private func drawCrosshair(at p: CGPoint) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: p.y))
        path.line(to: CGPoint(x: bounds.maxX, y: p.y))
        path.move(to: CGPoint(x: p.x, y: 0))
        path.line(to: CGPoint(x: p.x, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.28).setStroke()
        path.stroke()
    }

    /// A circular magnifier showing the pixels around the pointer, with the pixel's color.
    private func drawLoupe(at p: CGPoint) {
        let sample = 15 // pixels across; odd so one pixel sits in the middle
        let zoom: CGFloat = 8
        let diameter = CGFloat(sample) * zoom
        let scale = frozen.pixelScale
        let px = Int(p.x * scale), py = Int(p.y * scale)
        let half = sample / 2
        let source = CGRect(x: px - half, y: py - half, width: sample, height: sample)
        let imageBounds = CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height)
        let clipped = source.intersection(imageBounds)
        guard !clipped.isNull, let crop = frozen.image.cropping(to: clipped) else { return }

        var origin = CGPoint(x: p.x + 26, y: p.y + 26)
        if origin.x + diameter > bounds.maxX - 8 { origin.x = p.x - 26 - diameter }
        if origin.y + diameter + 34 > bounds.maxY - 8 { origin.y = p.y - 26 - diameter - 34 }
        let loupe = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: loupe).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: loupe).addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        let dest = CGRect(
            x: loupe.minX + (clipped.minX - source.minX) * zoom,
            y: loupe.minY + (clipped.minY - source.minY) * zoom,
            width: clipped.width * zoom,
            height: clipped.height * zoom
        )
        NSImage(cgImage: crop, size: clipped.size).draw(in: dest, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        // Pixel grid and the center pixel.
        let grid = NSBezierPath()
        for i in 1..<sample {
            let offset = CGFloat(i) * zoom
            grid.move(to: CGPoint(x: loupe.minX + offset, y: loupe.minY))
            grid.line(to: CGPoint(x: loupe.minX + offset, y: loupe.maxY))
            grid.move(to: CGPoint(x: loupe.minX, y: loupe.minY + offset))
            grid.line(to: CGPoint(x: loupe.maxX, y: loupe.minY + offset))
        }
        grid.lineWidth = 0.5
        NSColor.white.withAlphaComponent(0.12).setStroke()
        grid.stroke()
        let center = CGRect(x: loupe.minX + CGFloat(half) * zoom, y: loupe.minY + CGFloat(half) * zoom, width: zoom, height: zoom)
        let centerPath = NSBezierPath(rect: center)
        centerPath.lineWidth = 1.5
        NSColor.white.setStroke()
        centerPath.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let ring = NSBezierPath(ovalIn: loupe.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.85).setStroke()
        ring.stroke()

        // Coordinates and color under the pointer.
        let hex = pixelHex(x: px, y: py) ?? ""
        let text = "\(px), \(py)   \(hex)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let pill = CGRect(x: loupe.midX - size.width / 2 - 9, y: loupe.maxY + 8, width: size.width + 18, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 9, y: pill.minY + 4), withAttributes: attributes)
    }

    private func pixelHex(x: Int, y: Int) -> String? {
        guard x >= 0, y >= 0, x < frozen.image.width, y < frozen.image.height,
              let pixel = frozen.image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return String(format: "#%02X%02X%02X", rgba[0], rgba[1], rgba[2])
    }

    // MARK: Toolbar and hint

    private func showToolbar() {
        removeToolbar()
        let view = NSHostingView(rootView: CaptureToolbar(
            onAction: { [weak self] action in self?.confirm(action) },
            onCancel: { [weak self] in self?.session?.cancel() }
        ))
        view.frame.size = view.fittingSize
        addSubview(view)
        toolbar = view
        positionToolbar()
        hint?.isHidden = true
    }

    private func positionToolbar() {
        guard let toolbar, let selection else { return }
        let size = toolbar.fittingSize
        var y = selection.maxY + 12
        if y + size.height > bounds.maxY - 12 { y = selection.minY - size.height - 12 }
        if y < 12 { y = selection.maxY - size.height - 12 }
        let x = min(max(12, selection.midX - size.width / 2), bounds.maxX - size.width - 12)
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func removeToolbar() {
        toolbar?.removeFromSuperview()
        toolbar = nil
    }

    private func makeHint() -> CaptureHint {
        CaptureHint(
            mode: mode,
            onMode: { [weak self] mode in
                guard let self else { return }
                self.session?.setMode(mode, from: self.index)
            },
            onCancel: { [weak self] in self?.session?.cancel() }
        )
    }

    private func installHint() {
        // Update in place: this can run from a click on the hint itself.
        if let hint {
            hint.rootView = makeHint()
            positionHint(hint)
            return
        }
        let view = NSHostingView(rootView: makeHint())
        view.autoresizingMask = [.minXMargin, .maxXMargin]
        addSubview(view)
        positionHint(view)
        hint = view
    }

    private func positionHint(_ hint: NSHostingView<CaptureHint>) {
        let size = hint.fittingSize
        hint.frame = CGRect(x: (bounds.width - size.width) / 2, y: 64, width: size.width, height: size.height)
    }
}

/// Glass action bar shown under a finished selection.
struct CaptureToolbar: View {
    var onAction: @MainActor (CaptureAction) -> Void
    var onCancel: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ToolbarIconButton(symbol: "square.and.arrow.down", help: "Save to library (S)") { onAction(.save) }
            ToolbarIconButton(symbol: "doc.on.doc", help: "Copy (C)") { onAction(.copy) }
            ToolbarIconButton(symbol: "pencil.and.outline", help: "Annotate (A)") { onAction(.annotate) }
            ToolbarIconButton(symbol: "text.viewfinder", help: "Copy text (T)") { onAction(.ocr) }
            ToolbarIconButton(symbol: "pin", help: "Pin to screen (P)") { onAction(.pin) }
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 20).padding(.horizontal, 4)
            ToolbarIconButton(symbol: "checkmark", help: "Done (Return)", prominent: true) { onAction(.standard) }
            ToolbarIconButton(symbol: "xmark", help: "Cancel (Esc)") { onCancel() }
        }
        .padding(6)
        .glassEffect(.regular.tint(Theme.panel.opacity(0.55)), in: Capsule())
        .padding(10)
        .environment(\.colorScheme, .dark)
    }
}

/// Mode switcher and instructions shown while nothing is selected.
struct CaptureHint: View {
    var mode: CaptureMode
    var onMode: @MainActor (CaptureMode) -> Void
    var onCancel: @MainActor () -> Void

    private var instructions: String {
        switch mode {
        case .region: "Drag to select · click a window · Space for window mode · Esc to cancel"
        case .window: "Click a window to capture it · Space for area mode"
        case .text: "Drag over text to copy it"
        case .screen: ""
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                modeButton(.region, "rectangle.dashed", "Area")
                modeButton(.window, "macwindow", "Window")
                modeButton(.screen, "display", "Screen")
                modeButton(.text, "text.viewfinder", "Text")
            }
            .padding(5)
            .glassEffect(.regular.tint(Theme.panel.opacity(0.5)), in: Capsule())

            Text(instructions)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.45)))
        }
        .padding(10)
        .environment(\.colorScheme, .dark)
    }

    private func modeButton(_ m: CaptureMode, _ symbol: String, _ title: String) -> some View {
        Button {
            onMode(m)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(m == mode ? Color.black : Color.white)
                .background(Capsule().fill(m == mode ? Theme.accent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A round icon button with a hover highlight, used on glass bars.
struct ToolbarIconButton: View {
    let symbol: String
    var help: String
    var prominent = false
    let action: @MainActor () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(prominent ? Color.black : Theme.ink)
                .background(
                    Circle().fill(prominent ? Theme.accent : Color.white.opacity(hovering ? 0.14 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
