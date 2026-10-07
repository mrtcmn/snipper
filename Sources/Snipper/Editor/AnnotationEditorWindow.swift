import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens annotation editors in their own windows.
@MainActor
final class AnnotationEditorController {
    private var windows: [NSWindow] = []

    /// - Parameters:
    ///   - onSave: receives the flattened image when the user saves to the library.
    func open(image: CGImage, title: String, onSave: @escaping @MainActor (CGImage) -> Void) {
        let document = AnnotationDocument(image: image)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 520)

        let close: @MainActor () -> Void = { [weak self, weak window] in
            guard let window else { return }
            window.close()
            // Released on the next turn: this runs from a button inside the window.
            Task { @MainActor in self?.windows.removeAll { $0 === window } }
        }
        let view = AnnotationEditorView(
            document: document,
            onCopy: { image in
                Pasteboard.copy(image: image)
                HUD.shared.show("Copied to clipboard", symbol: "doc.on.doc.fill")
            },
            onSave: { image in
                onSave(image)
                close()
            },
            onSaveAs: { [weak window] image in
                Self.saveAs(image, from: window)
            },
            onClose: close
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        window.contentViewController = hosting

        // Size the window around the image, within 85% of the screen.
        if let screen = NSScreen.underMouse ?? NSScreen.main {
            let visible = screen.visibleFrame
            let scale = screen.backingScaleFactor
            let imageSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            let width = min(visible.width * 0.85, max(900, imageSize.width + 80))
            let height = min(visible.height * 0.85, max(600, imageSize.height + 200))
            window.setFrame(CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height), display: false)
        }
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func saveAs(_ image: CGImage, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Snipper \(formatter.string(from: Date())).png"
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let data = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg"
                ? ImageCoding.jpeg(ImageCoding.flattened(image))
                : ImageCoding.png(image)
            do {
                try data?.write(to: url, options: .atomic)
            } catch {
                HUD.shared.error("Couldn't save: \(error.localizedDescription)")
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }
}
