import AppKit
import ScreenCaptureKit
import Vision

enum ScreenCapturePermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards the user has to use System Settings.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A screen's pixels captured just before the selection overlay appears.
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage
    /// The screen's frame in AppKit global coordinates.
    let frame: CGRect

    var pixelScale: CGFloat { CGFloat(image.width) / max(frame.width, 1) }
}

/// An on-screen window, for the "click a window" capture mode.
struct WindowInfo {
    let id: CGWindowID
    /// Frame in Core Graphics global coordinates (top-left origin of the main display).
    let cgFrame: CGRect
    let appName: String
    let title: String
}

@MainActor
enum ScreenCapturer {
    enum CaptureError: LocalizedError {
        case noDisplays
        case windowGone

        var errorDescription: String? {
            switch self {
            case .noDisplays: "No display could be captured."
            case .windowGone: "That window is no longer available."
            }
        }
    }

    /// Captures every screen at full resolution, leaving out the given windows of ours.
    static func freezeScreens(excluding windowNumbers: Set<Int> = []) async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excluded = content.windows.filter { windowNumbers.contains(Int($0.windowID)) }
        var frozen: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            frozen.append(FrozenScreen(screen: screen, image: image, frame: screen.frame))
        }
        guard !frozen.isEmpty else { throw CaptureError.noDisplays }
        return frozen
    }

    /// A single window, rendered on its own (unobstructed, without other windows on top).
    static func capture(windowID: CGWindowID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.windowGone }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Normal app windows on screen, frontmost first.
    static func visibleWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info -> WindowInfo? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }
            return WindowInfo(
                id: CGWindowID(number),
                cgFrame: bounds,
                appName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? ""
            )
        }
    }

    /// Crops a frozen screen to `rect`, given in the overlay's flipped (top-left origin) points.
    static func crop(_ frozen: FrozenScreen, to rect: CGRect) -> CGImage? {
        let s = frozen.pixelScale
        let pixels = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s).integral
        let bounded = pixels.intersection(CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height))
        guard bounded.width >= 1, bounded.height >= 1 else { return nil }
        return frozen.image.cropping(to: bounded)
    }
}

enum ScreenCoordinates {
    /// Height of the primary display, the reference for flipping between Core Graphics
    /// (top-left origin) and AppKit (bottom-left origin) global coordinates.
    @MainActor static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Converts a Core Graphics global rect to a screen-local, top-left-origin rect.
    @MainActor static func local(_ cgRect: CGRect, in screenFrame: CGRect) -> CGRect {
        let topLeftY = primaryHeight - screenFrame.maxY
        return CGRect(x: cgRect.minX - screenFrame.minX, y: cgRect.minY - topLeftY, width: cgRect.width, height: cgRect.height)
    }
}

enum TextRecognizer {
    /// Recognizes text in reading order, one line per visual line.
    static func recognize(_ image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ""
            }
            let observations = request.results ?? []
            return lines(from: observations)
        }.value
    }

    private static func lines(from observations: [VNRecognizedTextObservation]) -> String {
        struct Item { let text: String; let box: CGRect }
        let items = observations.compactMap { o -> Item? in
            guard let text = o.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return Item(text: text, box: o.boundingBox)
        }
        // Vision's coordinates have their origin at the bottom left: higher midY is higher on screen.
        let sorted = items.sorted { $0.box.midY > $1.box.midY }
        var lines: [[Item]] = []
        for item in sorted {
            if let last = lines.last?.first, abs(last.box.midY - item.box.midY) < min(last.box.height, item.box.height) * 0.5 {
                lines[lines.count - 1].append(item)
            } else {
                lines.append([item])
            }
        }
        return lines
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}

enum CaptureSound {
    @MainActor static func play() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        let sound = FileManager.default.fileExists(atPath: path) ? NSSound(contentsOfFile: path, byReference: true) : NSSound(named: "Tink")
        sound?.play()
    }
}
