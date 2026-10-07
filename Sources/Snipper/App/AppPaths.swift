import Foundation
import os

let logger = Logger(subsystem: "dev.grasco.snipper", category: "app")

/// Where Snipper keeps its data: `~/Library/Application Support/Snipper`.
struct AppPaths: Sendable {
    let root: URL
    let database: URL
    let media: URL
    let remoteCache: URL

    static func standard() -> AppPaths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = support.appendingPathComponent("Snipper", isDirectory: true)
        let paths = AppPaths(
            root: root,
            database: root.appendingPathComponent("library.sqlite"),
            media: root.appendingPathComponent("Media", isDirectory: true),
            remoteCache: caches.appendingPathComponent("Snipper/Remote", isDirectory: true)
        )
        for dir in [paths.root, paths.media, paths.remoteCache] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return paths
    }
}

/// Bundled resources (the Gemma runtime page, the browser extension).
enum AppResources {
    /// Looks in the app bundle first, then next to the sources for `swift run` during development.
    static func url(_ name: String, _ ext: String? = nil) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        let sourceResources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // Snipper
            .appendingPathComponent("Resources")
        let candidate = sourceResources.appendingPathComponent(ext.map { "\(name).\($0)" } ?? name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    static func string(_ name: String, _ ext: String) -> String? {
        url(name, ext).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The unpacked Chromium extension folder.
    static var extensionFolder: URL? {
        // build-app.sh copies it as ChromeExtension; the Xcode project as Extension.
        for name in ["ChromeExtension", "Extension"] {
            if let bundled = Bundle.main.url(forResource: name, withExtension: nil) { return bundled }
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extension")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
