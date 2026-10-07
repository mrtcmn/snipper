import AppKit
import Observation
import SnipperCore
import SwiftUI

/// The composition root: owns the library, search, capture and integrations,
/// and implements the app's user-facing actions.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings: AppSettings
    let library: LibraryStore
    let index: SemanticIndex
    let search: SearchController

    // MARK: UI state

    /// The snip open in the viewer.
    var viewerID: UUID? = nil
    var showOnboarding = false
    /// Incremented to ask the search field to take focus.
    var searchFocusRequest = 0
    private(set) var serverState: LocalServer.State = .stopped
    private(set) var lastExtensionContact: Date? = nil
    /// Progress text for long-running imports.
    private(set) var activity: String? = nil

    // MARK: Services

    @ObservationIgnored let paths: AppPaths
    @ObservationIgnored let downloader: MediaDownloader
    @ObservationIgnored private(set) var capture: CaptureCoordinator!
    @ObservationIgnored private(set) var capturePreview: CapturePreviewController!
    @ObservationIgnored private(set) var quickNote: QuickNoteController!
    @ObservationIgnored let editor = AnnotationEditorController()
    @ObservationIgnored private(set) var server: LocalServer!
    @ObservationIgnored private var libraryWindow: LibraryWindowController?
    @ObservationIgnored private var statusItem: StatusItemController?
    @ObservationIgnored private let services = ServicesProvider()
    @ObservationIgnored private var started = false

    private init() {
        let paths = AppPaths.standard()
        self.paths = paths
        let settings = AppSettings()
        self.settings = settings
        let database: SnipDatabase
        do {
            database = try SnipDatabase(fileURL: paths.database)
        } catch {
            // Keep the app usable (in memory) and tell the user once the UI is up.
            logger.fault("Opening the database failed: \(String(describing: error), privacy: .public)")
            database = try! SnipDatabase(path: ":memory:")
        }
        let library = LibraryStore(database: database, media: MediaStore(folder: paths.media))
        self.library = library
        let index = SemanticIndex(library: library, settings: settings)
        self.index = index
        search = SearchController(library: library, index: index)
        downloader = MediaDownloader(library: library, settings: settings)
        capture = CaptureCoordinator(model: self)
        capturePreview = CapturePreviewController(model: self)
        quickNote = QuickNoteController(model: self)
        server = LocalServer { [weak self] request in
            await self?.handleAPI(request) ?? .error(503, "Snipper is shutting down")
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        ImageLoader.shared.configure(media: library.media, remoteCache: paths.remoteCache)
        applyDockPolicy()
        statusItem = StatusItemController(model: self)

        HotKeyCenter.shared.handler = { [weak self] action in self?.perform(action) }
        HotKeyCenter.shared.configure(saved: settings.hotKeyData)

        services.model = self
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        server.onStateChange = { [weak self] state in self?.serverState = state }
        server.start(port: UInt16(settings.serverPort))

        library.observe { [weak self] change in self?.libraryDidChange(change) }
        index.onVectorsChanged = { [weak self] in
            guard let self, self.search.isQueryActive else { return }
            self.search.refresh(debounce: 0.1)
        }

        await library.load()
        search.refresh(debounce: 0)
        downloader.scan()
        showLibrary()

        if settings.didOnboard {
            await index.configure()
        } else {
            showOnboarding = true
        }
    }

    private func libraryDidChange(_ change: LibraryChange) {
        index.libraryDidChange(change)
        search.libraryChanged()
        if case .added(let ids) = change { downloader.enqueue(ids) }
        if case .removed(let ids) = change, let viewerID, ids.contains(viewerID) { self.viewerID = nil }
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    func restartServer() {
        server.stop()
        server.start(port: UInt16(settings.serverPort))
    }

    func searchEngineChanged() {
        Task { await index.configure() }
    }

    func finishOnboarding() {
        settings.didOnboard = true
        showOnboarding = false
        Task { await index.configure() }
    }

    // MARK: Windows

    func showLibrary(focusSearch: Bool = false) {
        if libraryWindow == nil { libraryWindow = LibraryWindowController(model: self) }
        libraryWindow?.present()
        if focusSearch { searchFocusRequest += 1 }
    }

    var libraryIsKey: Bool { libraryWindow?.window?.isKeyWindow == true }

    /// Our floating panels, which must never appear in screenshots.
    var transientWindowNumbers: Set<Int> {
        var numbers = Set<Int>()
        if let n = capturePreview.windowNumber { numbers.insert(n) }
        return numbers
    }

    /// Opens the library with `id` in the viewer.
    func reveal(_ id: UUID) {
        search.clear()
        search.filter = .all
        showLibrary()
        viewerID = id
    }

    // MARK: Shortcut actions

    func perform(_ action: HotKeyAction) {
        switch action {
        case .captureRegion: capture.begin(.region)
        case .captureWindow: capture.begin(.window)
        case .captureScreen: capture.begin(.screen)
        case .captureText: capture.begin(.text)
        case .quickNote: newNote()
        case .snipBrowserTab: Task { await snipBrowserTab() }
        case .saveClipboard: saveClipboard()
        case .pickColor: ScreenColorPicker.pick()
        case .openLibrary: showLibrary(focusSearch: true)
        }
    }

    // MARK: Notes and clips

    func newNote(prefill: String? = nil) {
        quickNote.show(prefill: prefill)
    }

    @discardableResult
    func addNote(title: String, body: String, tags: [String]) -> Snip? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !title.isEmpty else { return nil }
        let snip = Snip(
            kind: .note,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: text,
            tags: tags.map(TagNormalizer.normalize).filter { !$0.isEmpty },
            source: "note"
        )
        return library.add(snip).snip
    }

    func saveClipboard() {
        if !saveFromPasteboard(.general, source: "clipboard") {
            HUD.shared.error("The clipboard is empty.")
        }
    }

    /// Saves whatever the pasteboard holds: image files, image data, a link or text.
    @discardableResult
    func saveFromPasteboard(_ pasteboard: NSPasteboard, source: String) -> Bool {
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            Task { await importURLs(fileURLs) }
            return true
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            Task {
                if await saveImageData(data, title: "Pasted image", source: source) != nil {
                    HUD.shared.show("Saved image", symbol: "photo.fill")
                }
            }
            return true
        }
        let string = (pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return false }
        if !string.contains(where: \.isWhitespace), let url = URL(string: string), url.scheme?.hasPrefix("http") == true {
            Task { await saveURL(url, title: nil, source: source) }
        } else {
            library.add(Snip(kind: .text, body: string, source: source))
            HUD.shared.show("Saved clip", symbol: "text.quote")
        }
        return true
    }

    // MARK: Web

    /// "Snip browser tab": saves the frontmost browser's current page (or post).
    func snipBrowserTab() async {
        let tab: BrowserBridge.Tab
        do {
            tab = try BrowserBridge.currentTab()
        } catch {
            HUD.shared.error(error.localizedDescription)
            return
        }
        guard let url = URL(string: tab.url), url.scheme?.hasPrefix("http") == true else {
            HUD.shared.error("This tab isn't a web page.")
            return
        }
        await saveURL(url, title: tab.title, source: "browser:\(tab.browser)")
    }

    /// Saves a link, or the post it points to.
    func saveURL(_ url: URL, title: String?, source: String) async {
        if let reference = TweetURL.parse(url.absoluteString) {
            HUD.shared.show("Saving post…", symbol: "arrow.down.circle")
            do {
                let post = try await WebFetcher.post(reference, source: source)
                let result = library.add(post)
                let who = result.snip.author.map { " by @\($0.handle)" } ?? ""
                HUD.shared.show(result.isNew ? "Saved post\(who)" : "Post already saved — refreshed", symbol: "checkmark.circle.fill")
                return
            } catch {
                logger.info("Post fetch failed, saving as a link: \(error.localizedDescription, privacy: .public)")
            }
        }
        HUD.shared.show("Saving page…", symbol: "arrow.down.circle")
        let snip = await WebFetcher.link(url, title: title, source: source)
        let result = library.add(snip)
        HUD.shared.show(result.isNew ? "Saved “\(result.snip.displayTitle.prefix(48))”" : "Already saved — refreshed", symbol: "checkmark.circle.fill")
    }

    // MARK: Screenshots and images

    func saveScreenshot(_ image: CGImage, context: CaptureContext, source: String = "capture") async -> Snip? {
        guard let media = await storeImage(image) else {
            HUD.shared.error("Couldn't save the screenshot.")
            return nil
        }
        let snip = Snip(kind: .screenshot, title: context.title, media: [media], source: source, appName: context.appName)
        let saved = library.add(snip).snip
        recognizeText(for: saved.id, image: image)
        return saved
    }

    func saveTextCapture(_ text: String, image: CGImage, context: CaptureContext) async {
        let media = await storeImage(image)
        let title = context.appName.map { "Text from \($0)" } ?? "Recognized text"
        library.add(Snip(kind: .text, title: title, body: text, media: media.map { [$0] } ?? [], source: "capture:text", ocrText: nil, appName: context.appName))
    }

    @discardableResult
    func saveImageData(_ data: Data, title: String, source: String, url: String? = nil) async -> Snip? {
        guard let image = ImageCoding.cgImage(data: data) else { return nil }
        let isPNGorJPEG = data.starts(with: [0x89, 0x50]) || data.starts(with: [0xFF, 0xD8])
        let stored: SnipMedia?
        if isPNGorJPEG {
            stored = await storeData(data, ext: data.starts(with: [0xFF, 0xD8]) ? "jpg" : "png", size: CGSize(width: image.width, height: image.height))
        } else {
            stored = await storeImage(image)
        }
        guard let stored else { return nil }
        let snip = library.add(Snip(kind: .image, title: title, url: url, media: [stored], source: source)).snip
        recognizeText(for: snip.id, image: image)
        return snip
    }

    /// Writes a PNG to the media folder off the main thread.
    func storeImage(_ image: CGImage) async -> SnipMedia? {
        let media = library.media
        let width = image.width, height = image.height
        guard let name = try? await Task.detached(priority: .userInitiated, operation: { try media.savePNG(image) }).value else { return nil }
        return SnipMedia(kind: .image, localFile: name, width: width, height: height)
    }

    func storeData(_ data: Data, ext: String, size: CGSize? = nil) async -> SnipMedia? {
        let media = library.media
        guard let name = try? await Task.detached(priority: .userInitiated, operation: { try media.save(data, fileExtension: ext) }).value else { return nil }
        let pixelSize = size ?? media.pixelSize(name)
        return SnipMedia(kind: .image, localFile: name, width: pixelSize.map { Int($0.width) }, height: pixelSize.map { Int($0.height) })
    }

    /// Fills in a snip's `ocrText` in the background so its image text is searchable.
    func recognizeText(for id: UUID, image: CGImage) {
        Task {
            let text = await TextRecognizer.recognize(image)
            guard !text.isEmpty else { return }
            library.mutate(id) { $0.ocrText = text }
        }
    }

    func recognizeText(for id: UUID, file: String) {
        let url = library.media.url(for: file)
        Task {
            guard let image = await Task.detached(priority: .utility, operation: { ImageCoding.cgImage(at: url) }).value else { return }
            recognizeText(for: id, image: image)
        }
    }

    // MARK: Annotation

    func openEditor(image: CGImage, context: CaptureContext, snipID: UUID?) {
        editor.open(image: image, title: "Annotate — \(context.title)") { [weak self] edited in
            guard let self else { return }
            Task {
                if let snipID, self.library.snip(snipID) != nil {
                    await self.replaceImage(of: snipID, with: edited)
                    HUD.shared.show("Saved changes", symbol: "checkmark.circle.fill")
                } else if await self.saveScreenshot(edited, context: context) != nil {
                    Pasteboard.copy(image: edited)
                    HUD.shared.show("Saved and copied", symbol: "checkmark.circle.fill")
                }
            }
        }
    }

    func annotate(_ snip: Snip) {
        guard let file = snip.primaryMedia?.localFile, let image = library.media.cgImage(file) else {
            HUD.shared.error("This snip has no local image to annotate.")
            return
        }
        openEditor(image: image, context: CaptureContext(appName: snip.appName ?? snip.displayTitle), snipID: snip.id)
    }

    private func replaceImage(of id: UUID, with image: CGImage) async {
        guard let stored = await storeImage(image) else { return }
        var oldFiles: [String] = []
        library.mutate(id) { snip in
            if let i = snip.media.firstIndex(where: { $0.localFile != nil }) {
                if let old = snip.media[i].localFile { oldFiles.append(old) }
                snip.media[i] = stored
            } else {
                snip.media.insert(stored, at: 0)
            }
            snip.ocrText = nil
        }
        for file in oldFiles { ImageLoader.shared.evict(localFile: file) }
        library.media.delete(oldFiles)
        recognizeText(for: id, image: image)
    }

    func pin(_ snip: Snip) {
        guard let file = snip.primaryMedia?.localFile, let image = library.media.cgImage(file) else { return }
        PinnedImageController.shared.pin(image)
    }

    // MARK: Snip actions

    func toggleFavorite(_ id: UUID) {
        library.mutate(id) { $0.isFavorite.toggle() }
    }

    func setTags(_ tags: [String], for id: UUID) {
        let clean = tags.map(TagNormalizer.normalize).filter { !$0.isEmpty }
        var seen = Set<String>()
        library.mutate(id) { $0.tags = clean.filter { seen.insert($0).inserted } }
    }

    func delete(_ ids: [UUID]) {
        library.delete(ids)
    }

    func copy(_ snip: Snip) {
        switch snip.kind {
        case .screenshot, .image:
            if let file = snip.primaryMedia?.localFile, let image = library.media.cgImage(file) {
                Pasteboard.copy(image: image)
                HUD.shared.show("Image copied", symbol: "doc.on.doc.fill")
                return
            }
            fallthrough
        default:
            var text = snip.body.isEmpty ? snip.displayTitle : snip.body
            if let url = snip.url, !text.contains(url) { text += "\n\(url)" }
            Pasteboard.copy(text: text)
            HUD.shared.show("Copied", symbol: "doc.on.doc.fill")
        }
    }

    func copyMarkdown(_ snip: Snip) {
        let markdown = MarkdownExporter.markdown(for: snip, mediaFolder: paths.media.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        Pasteboard.copy(text: markdown)
        HUD.shared.show("Copied as Markdown", symbol: "doc.richtext")
    }

    func openOriginal(_ snip: Snip) {
        guard let string = snip.url ?? snip.link?.url, let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ snip: Snip) {
        let urls = snip.media.compactMap(\.localFile).map(library.media.url(for:))
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [paths.root] : urls)
    }

    func showSimilar(to id: UUID) {
        viewerID = nil
        search.showSimilar(to: id)
        showLibrary()
    }

    func revealExtensionFolder() {
        guard let folder = AppResources.extensionFolder else {
            HUD.shared.error("The extension folder wasn't found.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: URL scheme

    /// Handles `snipper://…` links (from the extension, Shortcuts, Raycast, etc.).
    func handle(url: URL) {
        guard url.scheme == "snipper" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let path = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }

        switch path.first {
        case "search":
            showLibrary(focusSearch: true)
            if let q = value("q") { search.text = q }
        case "capture":
            switch path.dropFirst().first {
            case "window": capture.begin(.window)
            case "screen": capture.begin(.screen)
            case "text": capture.begin(.text)
            default: capture.begin(.region)
            }
        case "note":
            newNote(prefill: value("text"))
        case "save":
            if let raw = value("url"), let target = URL(string: raw) {
                Task { await saveURL(target, title: value("title"), source: "url-scheme") }
            } else if let text = value("text") {
                library.add(Snip(kind: .text, body: text, source: "url-scheme"))
                HUD.shared.show("Saved clip", symbol: "text.quote")
            }
        case "import-bookmarks":
            importXBookmarksInBrowser()
        default:
            showLibrary()
        }
    }

    // MARK: Activity

    func setActivity(_ text: String?) {
        activity = text
    }

    func noteExtensionContact() {
        lastExtensionContact = Date()
    }
}
