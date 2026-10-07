import Foundation
import SnipperCore

/// Keeps a local copy of web media attached to snips (post photos, link images),
/// so the library works offline and images can be embedded for search.
@MainActor
final class MediaDownloader {
    private let library: LibraryStore
    private let settings: AppSettings
    private var queue: [UUID] = []
    private var queued: Set<UUID> = []
    private var running = 0
    private let maxConcurrent = 4
    private var attempts: [String: Int] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    init(library: LibraryStore, settings: AppSettings) {
        self.library = library
        self.settings = settings
    }

    /// Queues every snip that still has remote-only media.
    func scan() {
        enqueue(library.snips.filter(needsDownload).map(\.id))
    }

    func enqueue(_ ids: [UUID]) {
        guard settings.downloadPostMedia else { return }
        for id in ids where !queued.contains(id) {
            guard let snip = library.snip(id), needsDownload(snip) else { continue }
            queued.insert(id)
            queue.append(id)
        }
        pump()
    }

    private func needsDownload(_ snip: Snip) -> Bool {
        snip.media.contains { m in
            m.localFile == nil && m.remoteURL != nil && (attempts[m.remoteURL!] ?? 0) < 2
        }
    }

    private func pump() {
        while running < maxConcurrent, !queue.isEmpty {
            let id = queue.removeFirst()
            running += 1
            Task {
                await download(id)
                running -= 1
                queued.remove(id)
                pump()
            }
        }
    }

    private func download(_ id: UUID) async {
        guard let snip = library.snip(id) else { return }
        var stored: [String: String] = [:] // remote URL → local file

        for media in snip.media where media.localFile == nil {
            guard let remote = media.remoteURL, (attempts[remote] ?? 0) < 2,
                  let url = URL(string: PostMedia.downloadURL(for: remote)) else { continue }
            attempts[remote, default: 0] += 1
            guard let fetched = await fetch(url) else { continue }
            let (data, mime) = fetched
            let ext = Self.fileExtension(mime: mime, url: url)
            let store = library.media
            let name = await Task.detached(priority: .utility) { try? store.save(data, fileExtension: ext) }.value
            if let name { stored[remote] = name }
        }
        guard !stored.isEmpty else { return }

        let store = library.media
        library.mutate(id) { snip in
            for i in snip.media.indices {
                guard let remote = snip.media[i].remoteURL, let file = stored[remote] else { continue }
                snip.media[i].localFile = file
                if snip.media[i].width == nil, let size = store.pixelSize(file) {
                    snip.media[i].width = Int(size.width)
                    snip.media[i].height = Int(size.height)
                }
            }
        }
    }

    private func fetch(_ url: URL) async -> (Data, String?)? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            guard !data.isEmpty else { return nil }
            return (data, response.mimeType)
        } catch {
            return nil
        }
    }

    static func fileExtension(mime: String?, url: URL) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/jpeg", "image/jpg": return "jpg"
        default:
            let ext = url.pathExtension.lowercased()
            return ["png", "gif", "webp", "heic", "jpg", "jpeg"].contains(ext) ? ext : "jpg"
        }
    }
}
