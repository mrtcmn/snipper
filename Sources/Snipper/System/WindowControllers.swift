import AppKit
import ServiceManagement
import SwiftUI

/// The main library window. Content runs edge to edge under a transparent title bar.
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let hosting = NSHostingController(rootView: LibraryRootView().environment(model))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Snipper"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.minSize = NSSize(width: 880, height: 560)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if !window.setFrameUsingName("SnipperLibrary") { window.center() }
        window.setFrameAutosaveName("SnipperLibrary")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    var isVisible: Bool { window?.isVisible == true }
}

/// The menu bar icon and its glass panel.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()

    init(model: AppModel) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Snipper")
            button.target = self
            button.action = #selector(toggle(_:))
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: MenuBarPanel(dismiss: { [weak self] in self?.close() }).environment(model)
        )
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.appearance = NSAppearance(named: .darkAqua)
    }

    @objc private func toggle(_ sender: Any?) {
        popover.isShown ? close() : show()
    }

    func show() {
        guard let button = item.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }
}

/// The floating "Quick note" panel (⌃⇧N), styled like Spotlight.
@MainActor
final class QuickNoteController {
    private var panel: KeyablePanel?
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func show(prefill: String? = nil) {
        guard let model else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = QuickNoteView(initialText: prefill ?? "", onClose: { [weak self] in self?.close() })
            .environment(model)
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        let size = NSSize(width: 620, height: 340)
        panel.setContentSize(size)
        if let screen = NSScreen.underMouse {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62 - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        panel?.orderOut(nil)
        // Drop the SwiftUI view on the next turn; this usually runs from inside it.
        Task { @MainActor in
            if self.panel?.isVisible == false { self.panel?.contentView = nil }
        }
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }
}

/// "Save to Snipper" in every app's Services menu (selected text, links and images).
@MainActor
final class ServicesProvider: NSObject {
    weak var model: AppModel?

    @objc func saveToSnipper(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let model else { return }
        if !model.saveFromPasteboard(pasteboard, source: "service") {
            error.pointee = "Nothing to save" as NSString
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
