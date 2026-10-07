import AppKit
import SnipperCore
import SwiftUI
import UniformTypeIdentifiers

/// Screenshots pinned above all windows, for reference while working.
@MainActor
final class PinnedImageController {
    static let shared = PinnedImageController()
    private var panels: [NSPanel] = []

    private init() {}

    func pin(_ image: CGImage) {
        let screen = NSScreen.underMouse ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        var size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let visible = screen?.visibleFrame {
            let limit = CGSize(width: visible.width * 0.6, height: visible.height * 0.6)
            let fit = min(1, limit.width / size.width, limit.height / size.height)
            size = CGSize(width: size.width * fit, height: size.height * fit)
        }

        let panel = KeyablePanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentAspectRatio = size
        panel.minSize = CGSize(width: 80, height: 80 * size.height / max(size.width, 1))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PinnedImageView(
            image: NSImage(cgImage: image),
            onClose: { [weak self, weak panel] in
                guard let panel else { return }
                self?.unpin(panel)
            },
            onCopy: { Pasteboard.copy(image: image) }
        ))

        if let screen {
            let frame = screen.visibleFrame
            let offset = CGFloat(panels.count % 6) * 24
            panel.setFrameOrigin(CGPoint(x: frame.midX - size.width / 2 + offset, y: frame.midY - size.height / 2 - offset))
        }
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    private func unpin(_ panel: NSPanel) {
        panel.orderOut(nil)
        // Released on the next turn: this runs inside the panel's own click handler.
        Task { @MainActor in self.panels.removeAll { $0 === panel } }
    }
}

private struct PinnedImageView: View {
    let image: NSImage
    var onClose: @MainActor () -> Void
    var onCopy: @MainActor () -> Void
    @State private var hovering = false
    @State private var opacity = 1.0

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .opacity(opacity)
            .overlay(alignment: .topTrailing) {
                if hovering {
                    HStack(spacing: 6) {
                        Button { onCopy() } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy")
                        Button(action: { opacity = opacity > 0.6 ? 0.45 : 1 }) { Image(systemName: "circle.lefthalf.filled") }
                            .help("Toggle transparency")
                        Button { onClose() } label: { Image(systemName: "xmark") }
                            .help("Close (Esc)")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
            .onTapGesture(count: 2) { onClose() }
            .onExitCommand { onClose() }
            .contextMenu {
                Button("Copy") { onCopy() }
                Button("Close") { onClose() }
            }
            .environment(\.colorScheme, .dark)
    }
}

/// The thumbnail that slides in after a capture, with quick actions (like CleanShot's overlay).
@MainActor
final class CapturePreviewController {
    private weak var model: AppModel?
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var hovering = false

    init(model: AppModel) {
        self.model = model
    }

    var windowNumber: Int? { panel?.isVisible == true ? panel?.windowNumber : nil }

    func show(image: CGImage, snipID: UUID) {
        guard let model else { return }
        close()
        let fileURL = model.library.snip(snipID)?.primaryMedia?.localFile.map { model.library.media.url(for: $0) }
        let view = CapturePreviewView(
            image: NSImage(cgImage: image),
            fileURL: fileURL,
            onAnnotate: { [weak self] in
                self?.close()
                self?.model?.openEditor(image: image, context: CaptureContext(), snipID: snipID)
            },
            onCopy: { [weak self] in
                Pasteboard.copy(image: image)
                HUD.shared.show("Copied to clipboard", symbol: "doc.on.doc.fill")
                self?.close()
            },
            onPin: { [weak self] in
                PinnedImageController.shared.pin(image)
                self?.close()
            },
            onOpen: { [weak self] in
                self?.close()
                self?.model?.reveal(snipID)
            },
            onDelete: { [weak self] in
                self?.model?.library.delete([snipID])
                self?.close()
            },
            onHover: { [weak self] inside in
                self?.hovering = inside
                if !inside { self?.scheduleDismiss(after: 3) }
            }
        )
        let size = CGSize(width: 300, height: 220)
        let panel = KeyablePanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: view)

        let screen = NSScreen.underMouse ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: frame.maxX - size.width - 12, y: frame.minY + 12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        scheduleDismiss(after: 6)
    }

    func close() {
        dismissTask?.cancel()
        guard let retired = panel else { return }
        retired.orderOut(nil)
        panel = nil
        // Keep it alive until the current event (often a click inside it) has finished.
        Task { @MainActor in withExtendedLifetime(retired) {} }
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.hovering else { return }
            self.close()
        }
    }
}

private struct CapturePreviewView: View {
    let image: NSImage
    let fileURL: URL?
    var onAnnotate: @MainActor () -> Void
    var onCopy: @MainActor () -> Void
    var onPin: @MainActor () -> Void
    var onOpen: @MainActor () -> Void
    var onDelete: @MainActor () -> Void
    var onHover: @MainActor (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                .onDrag {
                    if let fileURL, let provider = NSItemProvider(contentsOf: fileURL) { return provider }
                    return NSItemProvider(object: image)
                }

            if hovering {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        action("pencil.and.outline", "Annotate", onAnnotate)
                        action("doc.on.doc", "Copy", onCopy)
                        action("pin", "Pin", onPin)
                    }
                    HStack(spacing: 8) {
                        action("square.grid.2x2", "Open", onOpen)
                        action("trash", "Delete", onDelete)
                    }
                }
                .padding(12)
                .glassEffect(.regular.tint(Theme.panel.opacity(0.5)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(10)
        .frame(width: 300, height: 220)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
            onHover(inside)
        }
        .environment(\.colorScheme, .dark)
    }

    private func action(_ symbol: String, _ title: String, _ perform: @escaping @MainActor () -> Void) -> some View {
        Button {
            perform()
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(title)
    }
}
