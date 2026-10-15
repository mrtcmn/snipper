import AppKit
import SnipperCore
import SwiftUI

enum ImageSource: Hashable, Sendable {
    /// A file in the media folder.
    case local(String)
    /// A web image, cached on disk.
    case remote(String)

    static func of(_ media: SnipMedia) -> ImageSource? {
        if let file = media.localFile { return .local(file) }
        if let url = media.remoteURL { return .remote(url) }
        return nil
    }
}

/// Decodes thumbnails off the main thread and caches them in memory and on disk.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private var media: MediaStore?
    private var remoteFolder: URL?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Stash/1.0 (Macintosh)"]
        return URLSession(configuration: config)
    }()

    private init() {
        memory.totalCostLimit = 256 * 1024 * 1024
    }

    func configure(media: MediaStore, remoteCache: URL) {
        self.media = media
        remoteFolder = remoteCache
    }

    private func key(_ source: ImageSource, _ maxPixels: Int) -> String {
        switch source {
        case .local(let f): "l:\(f)@\(maxPixels)"
        case .remote(let u): "r:\(u)@\(maxPixels)"
        }
    }

    func cached(_ source: ImageSource?, maxPixels: Int) -> NSImage? {
        guard let source else { return nil }
        return memory.object(forKey: key(source, maxPixels) as NSString)
    }

    func evict(localFile: String) {
        // NSCache can't enumerate keys; drop the common sizes.
        for size in [160, 320, 480, 640, 800, 1200, 1600, 2400] {
            memory.removeObject(forKey: key(.local(localFile), size) as NSString)
        }
    }

    func image(for source: ImageSource?, maxPixels: Int) async -> NSImage? {
        guard let source else { return nil }
        let k = key(source, maxPixels)
        if let hit = memory.object(forKey: k as NSString) { return hit }
        if let running = inflight[k] { return await running.value }

        let task = Task<NSImage?, Never> { [media, remoteFolder, session] in
            let cg: CGImage?
            switch source {
            case .local(let file):
                guard let media else { return nil }
                let url = media.url(for: file)
                cg = await Task.detached(priority: .utility) { ImageCoding.thumbnail(at: url, maxPixels: maxPixels) }.value
            case .remote(let string):
                guard let url = URL(string: string), let remoteFolder else { return nil }
                let file = remoteFolder.appendingPathComponent(ContentHash.fnv1a(string))
                if FileManager.default.fileExists(atPath: file.path) {
                    cg = await Task.detached(priority: .utility) { ImageCoding.thumbnail(at: file, maxPixels: maxPixels) }.value
                } else {
                    guard let data = await ImageLoader.fetch(url, session: session) else { return nil }
                    try? data.write(to: file, options: .atomic)
                    cg = await Task.detached(priority: .utility) { ImageCoding.thumbnail(data: data, maxPixels: maxPixels) }.value
                }
            }
            return cg.map { NSImage(cgImage: $0) }
        }
        inflight[k] = task
        let image = await task.value
        inflight[k] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            memory.setObject(image, forKey: k as NSString, cost: cost)
        }
        return image
    }

    /// Raw bytes of a remote image, using the disk cache (for saving web images as snips).
    func data(forRemote string: String) async -> Data? {
        guard let url = URL(string: string) else { return nil }
        if let remoteFolder {
            let file = remoteFolder.appendingPathComponent(ContentHash.fnv1a(string))
            if let data = try? Data(contentsOf: file) { return data }
        }
        return await Self.fetch(url, session: session)
    }

    /// GETs `url`, returning the body for 2xx responses. Only http(s): URLs can come from
    /// the extension, and file URLs must never be read on its behalf.
    nonisolated static func fetch(_ url: URL, session: URLSession) async -> Data? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        guard let result = try? await session.data(from: url) else { return nil }
        if let http = result.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return result.0
    }
}

/// An image that loads asynchronously, with a soft placeholder while it does.
struct AsyncThumbnail: View {
    let source: ImageSource?
    var maxPixels: Int = 800
    var contentMode: ContentMode = .fill
    var placeholderTint: Color = Theme.accent

    @State private var image: NSImage?

    init(source: ImageSource?, maxPixels: Int = 800, contentMode: ContentMode = .fill, placeholderTint: Color = Theme.accent) {
        self.source = source
        self.maxPixels = maxPixels
        self.contentMode = contentMode
        self.placeholderTint = placeholderTint
        _image = State(initialValue: ImageLoader.shared.cached(source, maxPixels: maxPixels))
    }

    var body: some View {
        ZStack {
            if let image, contentMode == .fill {
                // Take the size from the frame, not the image, so a fill never grows the card.
                Color.clear
                    .overlay { Image(nsImage: image).resizable().interpolation(.high).scaledToFill() }
                    .clipped()
                    .transition(.opacity)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                LinearGradient(
                    colors: [placeholderTint.opacity(0.10), Color.white.opacity(0.03)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .task(id: source) {
            if let hit = ImageLoader.shared.cached(source, maxPixels: maxPixels) {
                image = hit
                return
            }
            let loaded = await ImageLoader.shared.image(for: source, maxPixels: maxPixels)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}
