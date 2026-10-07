import SnipperCore
import SwiftUI
import UniformTypeIdentifiers

/// The library window: the spatial field (or grid), floating glass chrome, the viewer and onboarding.
struct LibraryRootView: View {
    @Environment(AppModel.self) private var model
    @State private var fileDropTargeted = false

    private var search: SearchController { model.search }
    private var items: [DisplayItem] {
        model.settings.viewMode == .grid && search.isQueryActive ? search.relevantItems : search.items
    }

    var body: some View {
        ZStack {
            AuroraBackground()

            Group {
                if !model.library.isLoaded {
                    ProgressRing(progress: nil, size: 22)
                } else if items.isEmpty {
                    EmptyLibraryView(
                        isSearching: search.isQueryActive || search.filter != .all,
                        onCapture: { model.perform(.captureRegion) },
                        onImport: { model.importFiles() }
                    )
                } else if model.settings.viewMode == .atlas {
                    AtlasField(items: items, isSearching: search.isQueryActive) { open($0) }
                        .padding(.top, 54)
                } else {
                    MasonryGrid(items: items, isSearching: search.isQueryActive) { open($0) }
                }
            }
            .blur(radius: model.viewerID == nil ? 0 : 14)
            .animation(.easeOut(duration: 0.25), value: model.viewerID == nil)

            VStack(spacing: 0) {
                TopBar()
                Spacer()
                SearchBar()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 26)
            }
            .opacity(model.viewerID == nil ? 1 : 0)
            .allowsHitTesting(model.viewerID == nil)

            if let id = model.viewerID, let snip = model.library.snip(id) {
                let list = items.map(\.id)
                let index = list.firstIndex(of: id)
                SnipViewer(
                    snip: snip,
                    similarity: items.first { $0.id == id }?.similarity,
                    position: index.map { ($0, list.count) },
                    onClose: { close() },
                    onPrevious: { step(-1, in: list) },
                    onNext: { step(1, in: list) }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(10)
            }

            if model.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
                    .zIndex(20)
            }

            if fileDropTargeted {
                DropOverlay()
                    .transition(.opacity)
                    .zIndex(30)
            }
        }
        .frame(minWidth: 880, minHeight: 560)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.viewerID)
        .animation(.easeOut(duration: 0.2), value: fileDropTargeted)
        .onDrop(of: [.fileURL, .image, .url, .plainText], isTargeted: $fileDropTargeted, perform: handleDrop)
    }

    private func open(_ snip: Snip) {
        model.viewerID = snip.id
    }

    private func close() {
        model.viewerID = nil
    }

    private func step(_ delta: Int, in list: [UUID]) {
        guard let id = model.viewerID, let i = list.firstIndex(of: id), !list.isEmpty else { return }
        let next = (i + delta + list.count) % list.count
        model.viewerID = list[next]
    }

    /// Dropping files or links anywhere on the window saves them.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let collected = DropCollector()
        let group = DispatchGroup()
        var handled = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                group.enter()
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    if let url = object as? URL { collected.add(url: url) }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                group.enter()
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    if let data { collected.add(image: data) }
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                handled = true
                group.enter()
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    if let text = object as? String { collected.add(text: text) }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let model = AppModel.shared
                let (urls, texts, images) = collected.snapshot()
                let files = urls.filter(\.isFileURL)
                let links = urls.filter { !$0.isFileURL }
                if !files.isEmpty { Task { await model.importURLs(files) } }
                for link in links { Task { await model.saveURL(link, title: nil, source: "drop") } }
                for data in images { Task { await model.saveImageData(data, title: "Dropped image", source: "drop") } }
                for text in texts where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model.library.add(Snip(kind: .text, body: text, source: "drop"))
                }
            }
        }
        return handled
    }
}

/// Collects items loaded asynchronously from a drop.
private final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var texts: [String] = []
    private var images: [Data] = []

    func add(url: URL) { lock.withLock { urls.append(url) } }
    func add(text: String) { lock.withLock { texts.append(text) } }
    func add(image: Data) { lock.withLock { images.append(image) } }

    func snapshot() -> ([URL], [String], [Data]) {
        lock.withLock { (urls, texts, images) }
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Color(hex: 0x04101B).opacity(0.78)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [10, 8]))
                .padding(26)
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.accent)
                Text("Drop to save")
                    .headline(30, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Text("Images, links, text, X archives, CSV/JSON exports or bookmark files")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
