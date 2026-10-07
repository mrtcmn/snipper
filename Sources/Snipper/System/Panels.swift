import AppKit
import SwiftUI

/// A borderless panel that can still take keyboard focus (for text input).
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension NSScreen {
    /// The screen under the mouse pointer.
    static var underMouse: NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(point, $0.frame, false) } ?? main
    }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// Transient confirmation bubbles ("Saved to Snipper").
@MainActor
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(_ text: String, symbol: String = "checkmark.circle.fill", tint: Color = Theme.accent, swatch: Color? = nil, duration: Double = 1.8) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: HUDView(text: text, symbol: symbol, tint: tint, swatch: swatch))
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        if let screen = NSScreen.underMouse {
            let frame = screen.visibleFrame
            let size = host.fittingSize
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 18))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func error(_ text: String) {
        show(text, symbol: "exclamationmark.triangle.fill", tint: Theme.danger, duration: 3.2)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }
}

private struct HUDView: View {
    let text: String
    let symbol: String
    let tint: Color
    let swatch: Color?

    var body: some View {
        HStack(spacing: 10) {
            if let swatch {
                Circle().fill(swatch).frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(Theme.panel.opacity(0.45)), in: Capsule())
        .padding(14) // room for the glass edge highlight
        .environment(\.colorScheme, .dark)
    }
}
