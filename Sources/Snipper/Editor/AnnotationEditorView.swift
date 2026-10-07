import AppKit
import SwiftUI

/// The annotation editor: tools on a glass bar, the image in the middle, actions below.
struct AnnotationEditorView: View {
    @Bindable var document: AnnotationDocument
    var onCopy: @MainActor (CGImage) -> Void
    var onSave: @MainActor (CGImage) -> Void
    var onSaveAs: @MainActor (CGImage) -> Void
    var onClose: @MainActor () -> Void

    @Namespace private var toolNamespace

    var body: some View {
        ZStack {
            Theme.fieldGradient.ignoresSafeArea()
            VStack(spacing: 14) {
                toolBar
                AnnotationCanvas(document: document)
                    .padding(.horizontal, 24)
                actionBar
            }
            .padding(.top, 40)
            .padding(.bottom, 18)
        }
        .environment(\.colorScheme, .dark)
        .background(EditorKeyHandler(document: document, onCopy: { copy() }, onSave: { save() }))
    }

    // MARK: Bars

    private var toolBar: some View {
        HStack(spacing: 12) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 2) {
                    ForEach(AnnotationTool.allCases) { tool in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { document.tool = tool }
                        } label: {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 32)
                                .foregroundStyle(document.tool == tool ? Color.black : Theme.ink)
                                .background {
                                    if document.tool == tool {
                                        Capsule().fill(Theme.accent).matchedGeometryEffect(id: "tool", in: toolNamespace)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("\(tool.title) (\(String(tool.key).uppercased()))")
                    }
                }
                .padding(5)
                .glassEffect(.regular.tint(Theme.panel.opacity(0.45)), in: Capsule())
            }

            HStack(spacing: 6) {
                ForEach(RGBA.palette, id: \.self) { swatch in
                    Button {
                        document.color = swatch
                        if let i = document.index(of: document.selectedID) {
                            document.checkpoint()
                            document.annotations[i].color = swatch
                        }
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.white.opacity(document.color == swatch ? 0.95 : 0.25), lineWidth: document.color == swatch ? 2 : 1))
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(Theme.panel.opacity(0.45)), in: Capsule())

            HStack(spacing: 8) {
                Image(systemName: "lineweight").foregroundStyle(Theme.inkSecondary)
                Slider(value: $document.lineWidth, in: 2...24)
                    .frame(width: 90)
                if document.tool.supportsFill {
                    Toggle(isOn: $document.filled) { Image(systemName: "square.fill") }
                        .toggleStyle(.button)
                        .help("Filled shape")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(Theme.panel.opacity(0.45)), in: Capsule())

            HStack(spacing: 4) {
                Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!document.canUndo)
                    .help("Undo (⌘Z)")
                Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!document.canRedo)
                    .help("Redo (⇧⌘Z)")
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 24)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if document.crop != nil {
                Button("Reset crop", systemImage: "crop.rotate") {
                    document.checkpoint()
                    document.crop = nil
                }
                .buttonStyle(.glass)
            }
            Spacer()
            Button("Cancel", role: .cancel) { onClose() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button("Save As…", systemImage: "square.and.arrow.down.on.square") {
                if let image = document.render() { onSaveAs(image) }
            }
            .buttonStyle(.glass)
            Button("Copy", systemImage: "doc.on.doc") { copy() }
                .buttonStyle(.glass)
            Button("Save to Library", systemImage: "checkmark") { save() }
                .buttonStyle(.glassProminent)
                .tint(Theme.accentStrong)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
    }

    private func copy() {
        if let image = document.render() { onCopy(image) }
    }

    private func save() {
        if let image = document.render() { onSave(image) }
    }
}

/// The interactive drawing surface.
private struct AnnotationCanvas: View {
    @Bindable var document: AnnotationDocument
    @State private var drag: DragState?
    @State private var textDraft = ""
    @FocusState private var textFocused: Bool

    private enum DragState {
        case creating(UUID)
        case moving(UUID, last: CGPoint)
        case cropping(origin: CGPoint)
        /// The gesture was handled on touch-down (text, counters, empty clicks).
        case consumed
    }

    var body: some View {
        GeometryReader { geo in
            let layout = CanvasLayout(container: geo.size, image: document.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: document.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: layout.rect.width, height: layout.rect.height)
                    .offset(x: layout.rect.minX, y: layout.rect.minY)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)

                Canvas { context, _ in
                    context.withCGContext { cg in
                        cg.saveGState()
                        cg.translateBy(x: layout.rect.minX, y: layout.rect.minY)
                        cg.scaleBy(x: layout.scale, y: layout.scale)
                        cg.clip(to: CGRect(origin: .zero, size: document.size))
                        let visible = document.annotations.filter { $0.id != document.editingTextID }
                        AnnotationRenderer.draw(visible, in: cg, pixelated: document.pixelated, imageSize: document.size)
                        cg.restoreGState()
                    }
                    if let selected = document.annotations.first(where: { $0.id == document.selectedID }) {
                        let r = layout.toView(selected.bounds)
                        context.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                    if let crop = document.crop {
                        let r = layout.toView(crop)
                        var outside = Path(layout.rect)
                        outside.addRect(r)
                        context.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                        context.stroke(Path(r), with: .color(.white), lineWidth: 1.5)
                    }
                }
                .allowsHitTesting(false)

                if let id = document.editingTextID, let a = document.annotations.first(where: { $0.id == id }) {
                    let origin = layout.toView(a.start)
                    TextField("Type text", text: $textDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: max(10, a.fontSize * layout.scale), weight: .bold))
                        .foregroundStyle(a.color.color)
                        .frame(minWidth: 160, alignment: .leading)
                        .fixedSize()
                        .offset(x: origin.x, y: origin.y)
                        .focused($textFocused)
                        .onSubmit { commitText() }
                        .onAppear { textFocused = true }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in changed(value, layout) }
                    .onEnded { value in ended(value, layout) }
            )
            .onChange(of: document.tool) { _, _ in commitText() }
        }
    }

    private func changed(_ value: DragGesture.Value, _ layout: CanvasLayout) {
        let p = layout.toImage(value.location)
        let shift = NSEvent.modifierFlags.contains(.shift)

        guard let drag else {
            begin(at: p, layout: layout)
            return
        }
        switch drag {
        case .creating(let id):
            guard let i = document.index(of: id) else { return }
            var a = document.annotations[i]
            if a.tool == .pen || a.tool == .highlighter {
                if let last = a.points.last, hypot(last.x - p.x, last.y - p.y) < 1.5 { return }
                a.points.append(p)
            } else {
                a.end = shift ? constrained(from: a.start, to: p, tool: a.tool) : p
            }
            document.annotations[i] = a
        case .moving(let id, let last):
            guard let i = document.index(of: id) else { return }
            document.annotations[i].offset(by: CGSize(width: p.x - last.x, height: p.y - last.y))
            self.drag = .moving(id, last: p)
        case .consumed:
            break
        case .cropping(let origin):
            document.crop = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y), width: abs(p.x - origin.x), height: abs(p.y - origin.y))
                .intersection(CGRect(origin: .zero, size: document.size))
        }
    }

    private func begin(at p: CGPoint, layout: CanvasLayout) {
        commitText()
        switch document.tool {
        case .select:
            if let id = document.hitTest(p) {
                document.checkpoint()
                document.selectedID = id
                drag = .moving(id, last: p)
            } else {
                document.selectedID = nil
                drag = .consumed
            }
        case .crop:
            document.checkpoint()
            drag = .cropping(origin: p)
        case .text:
            document.checkpoint()
            let a = Annotation(tool: .text, start: p, end: p, color: document.color, lineWidth: document.lineWidth, fontSize: max(18, document.lineWidth * 5))
            document.annotations.append(a)
            document.editingTextID = a.id
            textDraft = ""
            drag = .consumed
        case .counter:
            document.checkpoint()
            let a = Annotation(tool: .counter, start: p, end: p, color: document.color, lineWidth: document.lineWidth, number: document.nextCounter)
            document.annotations.append(a)
            drag = .consumed
        default:
            document.checkpoint()
            let a = Annotation(
                tool: document.tool, start: p, end: p,
                points: document.tool == .pen || document.tool == .highlighter ? [p] : [],
                color: document.color, lineWidth: document.lineWidth, filled: document.filled
            )
            document.annotations.append(a)
            drag = .creating(a.id)
        }
    }

    private func ended(_ value: DragGesture.Value, _ layout: CanvasLayout) {
        defer { drag = nil }
        guard let drag else { return }
        switch drag {
        case .creating(let id):
            if let i = document.index(of: id), document.annotations[i].isDegenerate {
                document.annotations.remove(at: i)
            }
        case .cropping:
            if let crop = document.crop, crop.width < 8 || crop.height < 8 { document.crop = nil }
        case .moving, .consumed:
            break
        }
    }

    private func commitText() {
        guard let id = document.editingTextID, let i = document.index(of: id) else { return }
        let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            document.annotations.remove(at: i)
        } else {
            document.annotations[i].text = text
        }
        document.editingTextID = nil
        textDraft = ""
    }

    /// Shift-drag: 45° steps for lines and arrows, squares and circles for shapes.
    private func constrained(from s: CGPoint, to p: CGPoint, tool: AnnotationTool) -> CGPoint {
        let dx = p.x - s.x, dy = p.y - s.y
        switch tool {
        case .rectangle, .ellipse, .pixelate:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
        default:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: s.x + cos(angle) * length, y: s.y + sin(angle) * length)
        }
    }
}

/// Maps between view points and image pixels for an aspect-fit image.
struct CanvasLayout {
    let rect: CGRect
    let scale: CGFloat

    init(container: CGSize, image: CGSize) {
        // Fit the window, but never enlarge beyond one point per pixel.
        let fit = min(container.width / max(image.width, 1), container.height / max(image.height, 1))
        scale = min(fit, 1)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        rect = CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - rect.minX) / scale, y: (p.y - rect.minY) / scale)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale)
    }

    func toView(_ r: CGRect) -> CGRect {
        CGRect(x: rect.minX + r.minX * scale, y: rect.minY + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }
}

/// Tool shortcuts, Delete, undo/redo, ⌘C and ⌘S while the editor window is key.
private struct EditorKeyHandler: NSViewRepresentable {
    let document: AnnotationDocument
    var onCopy: @MainActor () -> Void
    var onSave: @MainActor () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.handler = { event in handle(event) }
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.handler = { event in handle(event) }
    }

    @MainActor
    private func handle(_ event: NSEvent) -> Bool {
        // Leave keys to the text field while typing a label.
        if document.editingTextID != nil { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command) {
            switch key {
            case "z":
                flags.contains(.shift) ? document.redo() : document.undo()
                return true
            case "c":
                onCopy()
                return true
            case "s":
                onSave()
                return true
            default:
                return false
            }
        }
        guard flags.isDisjoint(with: [.control, .option]) else { return false }
        if event.keyCode == 51 || event.keyCode == 117 { // delete, forward delete
            document.deleteSelected()
            return true
        }
        if event.keyCode == 53 { // escape
            document.selectedID = nil
            return document.crop != nil
        }
        if let ch = key.first, let tool = AnnotationTool.allCases.first(where: { $0.key == ch }) {
            document.tool = tool
            return true
        }
        return false
    }
}

final class KeyCatcherView: NSView {
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, let handler = self.handler else { return event }
            return handler(event) ? nil : event
        }
    }

    override func removeFromSuperview() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.removeFromSuperview()
    }
}
