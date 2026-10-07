import AppKit
import SnipperCore
import UniformTypeIdentifiers

extension AppModel {
    // MARK: Browser extension

    /// Saves items sent by the browser extension.
    func ingest(_ envelope: ExtensionEnvelope) async -> ImportSummary {
        let source = envelope.source ?? "extension"
        var snips: [Snip] = []
        for item in envelope.items {
            guard var incoming = try? ExtensionPayload.incoming(item, source: source) else { continue }

            // A page or link that is a post is saved as the post itself.
            if incoming.snip.kind == .link, let url = incoming.snip.url, let reference = TweetURL.parse(url),
               var post = try? await WebFetcher.post(reference, source: source) {
                post.tags = incoming.snip.tags
                incoming.snip = post
            }

            if let data = incoming.inlineImage {
                if let media = await storeData(data, ext: incoming.inlineImageExtension ?? "png") {
                    incoming.snip.media.insert(media, at: 0)
                }
            } else if let remote = incoming.remoteImage {
                let ext = URL(string: remote).map { MediaDownloader.fileExtension(mime: nil, url: $0) } ?? "jpg"
                if let data = await ImageLoader.shared.data(forRemote: remote), let media = await storeData(data, ext: ext) {
                    incoming.snip.media.insert(media, at: 0)
                } else {
                    incoming.snip.media.insert(SnipMedia(kind: .image, remoteURL: remote), at: 0)
                }
            } else if incoming.snip.kind == .link, incoming.snip.media.isEmpty, let image = incoming.snip.link?.imageURL {
                incoming.snip.media = [SnipMedia(kind: .image, remoteURL: image)]
            }
            snips.append(incoming.snip)
        }
        guard !snips.isEmpty else { return ImportSummary() }
        let summary = library.addMany(snips)
        downloader.enqueue(summary.ids)
        for id in summary.ids {
            guard let snip = library.snip(id), snip.kind == .image || snip.kind == .screenshot, snip.ocrText == nil,
                  let file = snip.primaryMedia?.localFile else { continue }
            recognizeText(for: id, file: file)
        }
        return summary
    }

    /// Routes requests from the extension (see `LocalAPIAccess` for who may call).
    func handleAPI(_ request: HTTPRequest) async -> HTTPResponse {
        let origin = request.header("origin")
        let cors = LocalAPIAccess.corsHeaders(for: origin)
        func reply(_ response: HTTPResponse) -> HTTPResponse {
            var r = response
            r.headers.append(contentsOf: cors)
            return r
        }

        if request.method == "OPTIONS" {
            return LocalAPIAccess.isAllowedOrigin(origin) ? HTTPResponse(status: 204, headers: cors) : .error(403, "Origin not allowed")
        }
        guard request.path.hasPrefix("/api/") else { return .error(404, "Not found") }
        guard LocalAPIAccess.authorize(request) else { return .error(403, "Forbidden") }
        noteExtensionContact()

        let body = request.jsonObject() as? [String: Any] ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/api/status"):
            return reply(.json([
                "ok": true,
                "app": "Snipper",
                "version": AppResources.version,
                "snips": library.snips.count,
                "search": index.engineName,
                "semantic": index.isReady,
            ]))

        case ("POST", "/api/snips"):
            guard let envelope = try? JSONDecoder().decode(ExtensionEnvelope.self, from: request.body) else {
                return reply(.error(400, "Invalid payload"))
            }
            let summary = await ingest(envelope)
            return reply(.json([
                "ok": true,
                "added": summary.added,
                "updated": summary.updated,
                "unchanged": summary.unchanged,
                "total": library.snips.count,
            ]))

        case ("POST", "/api/exists"):
            let ids = body["ids"] as? [String] ?? []
            let saved = ids.filter { library.contains(externalID: TweetReference.externalID(for: $0)) }
            return reply(.json(["ok": true, "saved": saved]))

        case ("POST", "/api/remove"):
            let ids = body["tweetIds"] as? [String] ?? []
            let snipIDs = ids.compactMap { library.snip(externalID: TweetReference.externalID(for: $0))?.id }
            library.delete(snipIDs)
            return reply(.json(["ok": true, "removed": snipIDs.count]))

        case ("POST", "/api/open"):
            showLibrary(focusSearch: body["query"] == nil)
            if let query = body["query"] as? String { search.text = query }
            return reply(.json(["ok": true]))

        case ("POST", "/api/import-progress"):
            // The bookmarks importer reports progress while it scrolls.
            if let done = body["done"] as? Bool, done {
                setActivity(nil)
                let count = body["count"] as? Int ?? 0
                HUD.shared.show("Imported \(count) bookmarks from X", symbol: "bookmark.fill")
            } else if let count = body["count"] as? Int {
                setActivity("Importing X bookmarks… \(count)")
            }
            return reply(.json(["ok": true]))

        default:
            return reply(.error(404, "Not found"))
        }
    }

    /// Opens X's bookmarks page in the browser; the extension offers to import everything there.
    func importXBookmarksInBrowser() {
        guard let url = URL(string: "https://x.com/i/bookmarks#snipper-import") else { return }
        NSWorkspace.shared.open(url)
        if lastExtensionContact == nil {
            HUD.shared.show("Install the Snipper browser extension to import bookmarks", symbol: "puzzlepiece.extension", duration: 4)
        }
    }

    // MARK: Files

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose an X archive (.zip or folder), a JSON or CSV export, browser bookmarks (.html), Markdown or images."
        panel.prompt = "Import"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importURLs(urls) }
    }

    func importURLs(_ urls: [URL]) async {
        setActivity("Importing…")
        defer { setActivity(nil) }
        var outcome = ImportOutcome()
        var images: [URL] = []
        for url in urls {
            do {
                let (result, found) = try await read(url)
                outcome.snips += result.snips
                outcome.skipped += result.skipped
                outcome.warnings += result.warnings
                images += found
            } catch {
                outcome.warnings.append("\(url.lastPathComponent): \(error)")
            }
        }

        var summary = library.addMany(outcome.snips)
        for imageURL in images {
            guard let data = try? Data(contentsOf: imageURL) else { continue }
            if let snip = await saveImageData(data, title: imageURL.deletingPathExtension().lastPathComponent, source: "import:file") {
                summary.added += 1
                summary.ids.append(snip.id)
            }
        }
        downloader.enqueue(summary.ids)

        if outcome.warnings.isEmpty {
            HUD.shared.show(summary.message, symbol: "tray.and.arrow.down.fill", duration: 3)
        } else {
            let alert = NSAlert()
            alert.messageText = "Import finished: \(summary.message)"
            alert.informativeText = outcome.warnings.prefix(8).joined(separator: "\n")
            _ = alert.runModal()
        }
    }

    private func read(_ url: URL) async throws -> (ImportOutcome, [URL]) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isDirectory {
            if let archive = try? XArchiveImporter.importFolder(url) { return (archive, []) }
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return (ImportOutcome(), contents.filter(Self.isImageFile))
        }
        if Self.isImageFile(url) { return (ImportOutcome(), [url]) }

        switch url.pathExtension.lowercased() {
        case "zip":
            let folder = try await Self.unzipArchiveData(url)
            defer { try? FileManager.default.removeItem(at: folder) }
            return (try XArchiveImporter.importFolder(Self.archiveRoot(in: folder)), [])
        case "json":
            return (try GenericImporter.importJSON(try Data(contentsOf: url)), [])
        case "csv", "tsv":
            return (GenericImporter.importCSV(try String(contentsOf: url, encoding: .utf8)), [])
        case "html", "htm":
            return (GenericImporter.importBookmarksHTML(try String(contentsOf: url, encoding: .utf8)), [])
        case "js":
            return (try XArchiveImporter.importFile(url), [])
        case "md", "markdown", "txt":
            let text = try String(contentsOf: url, encoding: .utf8)
            let note = Snip(kind: .note, title: url.deletingPathExtension().lastPathComponent, body: text, source: "import:file")
            return (ImportOutcome(snips: [note]), [])
        default:
            throw ImportError.unrecognizedFormat
        }
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Extracts only the data files of an X archive (it can be gigabytes of media).
    private static func unzipArchiveData(_ zip: URL) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("snipper-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", "-o", zip.path, "*data/*.js", "-d", destination.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }.value
        return destination
    }

    /// The folder holding `data/` inside an extracted archive (some zips nest it one level down).
    private static func archiveRoot(in folder: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent("data").path) { return folder }
        let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return children.first { fm.fileExists(atPath: $0.appendingPathComponent("data").path) } ?? folder
    }

    // MARK: Export

    func exportMarkdown(_ snips: [Snip]) {
        guard !snips.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to create the export folder. Each snip becomes a Markdown file; images go in media/."
        NSApp.activate()
        guard panel.runModal() == .OK, let base = panel.url else { return }

        let stamp = DateParsing.isoString(Date()).prefix(10)
        let folder = base.appendingPathComponent("Snipper Export \(stamp)")
        let mediaStore = library.media
        Task {
            let count = await Task.detached(priority: .userInitiated) { () -> Int in
                let fm = FileManager.default
                let mediaFolder = folder.appendingPathComponent("media")
                try? fm.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
                var written = 0
                for snip in snips {
                    let file = folder.appendingPathComponent(MarkdownExporter.fileName(for: snip))
                    do {
                        try MarkdownExporter.markdown(for: snip).write(to: file, atomically: true, encoding: .utf8)
                        written += 1
                    } catch { continue }
                    for name in snip.media.compactMap(\.localFile) {
                        try? fm.copyItem(at: mediaStore.url(for: name), to: mediaFolder.appendingPathComponent(name))
                    }
                }
                return written
            }.value
            HUD.shared.show("Exported \(count) snips", symbol: "square.and.arrow.up.fill")
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    func exportJSON(_ snips: [Snip]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Snipper Library.json"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SnipCoding.exportEncoder().encode(snips).write(to: url, options: .atomic)
            HUD.shared.show("Exported \(snips.count) snips", symbol: "square.and.arrow.up.fill")
        } catch {
            HUD.shared.error("Export failed: \(error.localizedDescription)")
        }
    }
}
