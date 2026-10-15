import AppKit
import SnipperCore
import SwiftUI
import UniformTypeIdentifiers

/// The floating Liquid Glass search field at the bottom of the library, with a caption above it.
struct SearchBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var dropTargeted = false

    private var search: SearchController { model.search }

    var body: some View {
        @Bindable var search = model.search
        VStack(spacing: 12) {
            caption
            HStack(spacing: 6) {
                leadingIcon
                    .frame(width: 34, height: 38)

                if let image = search.imageQuery {
                    HStack(spacing: 8) {
                        Image(nsImage: image.preview)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text("Searching by image")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                    }
                } else if let similar = search.similarTo, let snip = model.library.snip(similar) {
                    HStack(spacing: 6) {
                        Text("More like")
                            .foregroundStyle(Theme.inkSecondary)
                        Text("“\(snip.displayTitle.prefix(40))”")
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.system(size: 15))
                } else {
                    TextField("", text: $search.text, prompt: Text(placeholder).foregroundStyle(Color(hex: 0x9A9A9A)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .tracking(-0.3)
                        .foregroundStyle(Color(hex: 0xF3F3F3))
                        .focused($focused)
                        .onSubmit { search.refresh(debounce: 0) }
                        .onKeyPress(.escape) {
                            if search.isQueryActive {
                                search.clear()
                                return .handled
                            }
                            return .ignored
                        }
                }

                if search.isQueryActive {
                    iconButton("xmark", help: "Clear search") { search.clear() }
                }
                if model.index.supportsImages {
                    iconButton("photo.badge.magnifyingglass", help: "Search by image — or drop one here") { pickImage() }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 58)
            .glassEffect(.regular.tint(Color(hex: 0x0F0F0F).opacity(0.55)).interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(focused || dropTargeted ? 0.45 : 0), lineWidth: 1)
            )
            .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        }
        .frame(maxWidth: 560)
        .onChange(of: model.searchFocusRequest) { _, _ in focused = true }
    }

    private var placeholder: String {
        if model.library.snips.isEmpty { return "Search your snips" }
        return model.index.isReady ? "Search by meaning — “charts about growth”, “funny cats”…" : "Search posts, screenshots and notes"
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if search.isSearching {
            ProgressRing(progress: nil, size: 16)
        } else {
            Image(systemName: model.index.isReady ? "sparkle.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(hex: 0xDADADA))
        }
    }

    private var caption: some View {
        Group {
            if search.isQueryActive {
                HStack(spacing: 12) {
                    Text(resultSummary)
                    if let ms = search.elapsedMilliseconds {
                        Text("\(Int(ms.rounded())) ms").monospacedDigit()
                    }
                    Text(search.usedSemantic ? model.index.engineName : "keywords")
                    Button("Clear") { search.clear() }
                        .buttonStyle(.plain)
                        .underline()
                        .foregroundStyle(Theme.ink)
                }
            } else if let activity = model.activity {
                HStack(spacing: 8) {
                    ProgressRing(progress: nil, size: 12)
                    Text(activity)
                }
            } else if model.index.isIndexing, model.index.pendingCount > 0 {
                HStack(spacing: 8) {
                    ProgressRing(progress: nil, size: 12)
                    Text("Indexing \(model.index.pendingCount) snip\(model.index.pendingCount == 1 ? "" : "s") with \(model.index.engineName)…")
                }
            } else if case .preparing(let label, let progress) = model.index.state {
                HStack(spacing: 8) {
                    ProgressRing(progress: progress, size: 12)
                    Text(progress.map { "\(label) · \(Int($0 * 100))%" } ?? label)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(hex: 0xDDDDDD).opacity(0.72))
        .shadow(color: .black.opacity(0.85), radius: 8, y: 1)
        .animation(.easeOut(duration: 0.2), value: search.isQueryActive)
    }

    private var resultSummary: String {
        let count = model.settings.viewMode == .grid ? search.relevantItems.count : search.items.count
        if count == 0 { return "No results" }
        return "\(count) result\(count == 1 ? "" : "s")"
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(hex: 0xDADADA))
        .help(help)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        model.search.search(image: data)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.index.supportsImages, let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data else { return }
                Task { @MainActor in AppModel.shared.search.search(image: data) }
            }
            return true
        }
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
            guard let url = object as? URL, let data = try? Data(contentsOf: url) else { return }
            Task { @MainActor in AppModel.shared.search.search(image: data) }
        }
        return true
    }
}
