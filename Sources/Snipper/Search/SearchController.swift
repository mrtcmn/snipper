import AppKit
import Foundation
import Observation
import SnipperCore

/// The sidebar-style scope applied before searching.
enum LibraryFilter: Hashable, Identifiable {
    case all
    case favorites
    case bookmarks
    case kind(SnipKind)
    case tag(String)

    var id: String {
        switch self {
        case .all: "all"
        case .favorites: "favorites"
        case .bookmarks: "bookmarks"
        case .kind(let k): "kind:\(k.rawValue)"
        case .tag(let t): "tag:\(t)"
        }
    }

    var title: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .bookmarks: "X Bookmarks"
        case .kind(let k): k.pluralLabel
        case .tag(let t): "#\(t)"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .favorites: "star"
        case .bookmarks: "bookmark"
        case .kind(let k): Theme.symbol(for: k)
        case .tag: "number"
        }
    }

    func matches(_ snip: Snip) -> Bool {
        switch self {
        case .all: true
        case .favorites: snip.isFavorite
        case .bookmarks: snip.source == "x-bookmarks" || snip.source == "import:x-bookmarks" || snip.tags.contains("bookmark")
        case .kind(let k): snip.kind == k
        case .tag(let t): snip.tags.contains(t)
        }
    }
}

struct DisplayItem: Identifiable, Equatable {
    let snip: Snip
    /// Combined relevance, when a query is active.
    var score: Float?
    /// Embedding similarity, shown as "92% match".
    var similarity: Float?

    var id: UUID { snip.id }
}

struct ImageQuery {
    let data: Data
    let preview: NSImage
}

/// Turns the search box (text, a dropped image, or "more like this") plus the active filter
/// into the list of snips the library shows.
@MainActor
@Observable
final class SearchController {
    var text = "" {
        didSet { if text != oldValue { textChanged() } }
    }
    var filter: LibraryFilter = .all {
        didSet { if filter != oldValue { refresh(debounce: 0) } }
    }

    private(set) var imageQuery: ImageQuery? = nil
    private(set) var similarTo: UUID? = nil
    /// Everything that passes the filter, best match first (the atlas shows all of it).
    private(set) var items: [DisplayItem] = []
    /// The matches worth listing (the grid shows only these while searching).
    private(set) var relevantItems: [DisplayItem] = []
    private(set) var isSearching = false
    private(set) var elapsedMilliseconds: Double? = nil
    private(set) var usedSemantic = false
    private(set) var lastError: String? = nil

    var isQueryActive: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || imageQuery != nil || similarTo != nil
    }

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let index: SemanticIndex
    @ObservationIgnored private var candidates: [SearchCandidate] = []
    @ObservationIgnored private var candidatesRevision = -1
    @ObservationIgnored private var task: Task<Void, Never>?

    init(library: LibraryStore, index: SemanticIndex) {
        self.library = library
        self.index = index
    }

    // MARK: Inputs

    func libraryChanged() {
        refresh(debounce: isQueryActive ? 0.25 : 0)
    }

    func search(image data: Data) {
        guard let preview = NSImage(data: data) else { return }
        imageQuery = ImageQuery(data: data, preview: preview)
        similarTo = nil
        if !text.isEmpty { text = "" } // didSet refreshes
        refresh(debounce: 0)
    }

    func showSimilar(to id: UUID) {
        similarTo = id
        imageQuery = nil
        if !text.isEmpty { text = "" }
        refresh(debounce: 0)
    }

    func clear() {
        imageQuery = nil
        similarTo = nil
        text = ""
        refresh(debounce: 0)
    }

    private func textChanged() {
        if !text.isEmpty {
            imageQuery = nil
            similarTo = nil
        }
        refresh(debounce: 0.22)
    }

    // MARK: Running

    func refresh(debounce: Double) {
        task?.cancel()
        guard isQueryActive else {
            let filter = filter
            items = library.snips.filter(filter.matches).map { DisplayItem(snip: $0) }
            relevantItems = items
            isSearching = false
            elapsedMilliseconds = nil
            usedSemantic = false
            return
        }
        isSearching = true
        task = Task { [weak self] in
            if debounce > 0 {
                try? await Task.sleep(for: .seconds(debounce))
                guard !Task.isCancelled else { return }
            }
            await self?.run()
        }
    }

    private func run() async {
        let start = Date()
        let parsed = QueryParser.parse(text)
        let filter = filter

        var semantic: [UUID: Float]?
        lastError = nil
        do {
            if let similarTo {
                semantic = index.scores(similarTo: similarTo) ?? [:]
            } else if let imageQuery {
                semantic = try await index.scores(forImage: imageQuery.data)
            } else if parsed.hasFreeText, index.isReady {
                semantic = try await index.scores(forQuery: parsed.text)
            }
        } catch {
            lastError = error.localizedDescription
            semantic = nil
        }
        guard !Task.isCancelled else { return }

        if candidatesRevision != library.revision {
            candidates = library.snips.map(SearchCandidate.init)
            candidatesRevision = library.revision
        }
        let scoped = candidates.filter { c in
            guard let snip = library.snip(c.id) else { return false }
            return filter.matches(snip)
        }
        let hits = HybridRanker.rank(scoped, query: parsed, semantic: semantic)
        let relevant = Set(HybridRanker.relevant(hits).map(\.id))

        var all: [DisplayItem] = []
        var focused: [DisplayItem] = []
        all.reserveCapacity(hits.count)
        for hit in hits {
            guard let snip = library.snip(hit.id) else { continue }
            let item = DisplayItem(snip: snip, score: hit.score, similarity: hit.semantic)
            all.append(item)
            if relevant.contains(hit.id) { focused.append(item) }
        }
        items = all
        relevantItems = focused
        usedSemantic = semantic != nil
        elapsedMilliseconds = Date().timeIntervalSince(start) * 1000
        isSearching = false
    }
}
