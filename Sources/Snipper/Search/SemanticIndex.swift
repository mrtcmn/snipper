import Foundation
import Observation
import SnipperCore

/// Keeps an embedding for every snip and answers similarity queries.
///
/// Vectors live in SQLite (per model) and in memory as one matrix. When snips are added or
/// edited, their embedding input hash changes and they are re-embedded in the background,
/// newest first.
@MainActor
@Observable
final class SemanticIndex {
    enum State: Equatable {
        case off
        case preparing(label: String, progress: Double?)
        case ready
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var engineName = "Keywords"
    private(set) var embeddedCount = 0
    private(set) var pendingCount = 0
    private(set) var isIndexing = false
    /// Explains a fallback, e.g. when WebGPU is unavailable.
    private(set) var notice: String? = nil

    var isReady: Bool { state == .ready }
    var supportsImages: Bool { isReady && (engine?.supportsImages ?? false) }

    /// Called after a pass adds vectors, so an active search can refresh.
    @ObservationIgnored var onVectorsChanged: (() -> Void)?

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var engine: EmbeddingEngine?
    @ObservationIgnored private var vectors: [UUID: StoredVector] = [:]
    @ObservationIgnored private var matrixCache: VectorMatrix?
    @ObservationIgnored private var unembeddable: [UUID: String] = [:]
    @ObservationIgnored private var queryCache: [String: [Float]] = [:]
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var generation = 0

    init(library: LibraryStore, settings: AppSettings) {
        self.library = library
        self.settings = settings
    }

    // MARK: Engine

    /// Starts the engine chosen in settings, replacing any running one.
    func configure() async {
        generation += 1
        let current = generation
        scheduled?.cancel()
        engine?.shutdown()
        engine = nil
        vectors = [:]
        matrixCache = nil
        unembeddable = [:]
        queryCache = [:]
        embeddedCount = 0
        notice = nil

        switch settings.searchEngine {
        case .off:
            state = .off
            engineName = "Keywords"
        case .apple:
            await activate(AppleSentenceEngine(), generation: current)
        case .gemma:
            do {
                try await prepareAndActivate(GemmaEngine(), generation: current)
            } catch EngineError.webGPUUnavailable {
                notice = EngineError.webGPUUnavailable.errorDescription
                await activate(AppleSentenceEngine(), generation: current)
            } catch {
                guard current == generation else { return }
                state = .failed(error.localizedDescription)
                engineName = "Keywords"
                logger.error("EmbeddingGemma failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func activate(_ candidate: EmbeddingEngine, generation current: Int) async {
        do {
            try await prepareAndActivate(candidate, generation: current)
        } catch {
            guard current == generation else { return }
            state = .failed(error.localizedDescription)
            engineName = "Keywords"
        }
    }

    private func prepareAndActivate(_ candidate: EmbeddingEngine, generation current: Int) async throws {
        state = .preparing(label: "Starting \(candidate.displayName)", progress: nil)
        try await candidate.prepare { [weak self] label, progress in
            guard let self, self.generation == current else { return }
            self.state = .preparing(label: label, progress: progress)
        }
        guard current == generation else {
            candidate.shutdown()
            return
        }
        engine = candidate
        engineName = candidate.displayName
        let stored = (try? await library.database.vectors(model: candidate.modelID)) ?? []
        guard current == generation else { return }
        vectors = Dictionary(stored.map { ($0.snipID, $0) }, uniquingKeysWith: { first, _ in first })
        matrixCache = nil
        embeddedCount = vectors.count
        state = .ready
        scheduleIndexing(after: 0.3)
    }

    /// Re-embeds the whole library with the current engine.
    func rebuild() async {
        guard let engine else { return }
        try? await library.database.deleteVectors(model: engine.modelID)
        vectors = [:]
        matrixCache = nil
        unembeddable = [:]
        embeddedCount = 0
        scheduleIndexing(after: 0)
    }

    /// Deletes the downloaded EmbeddingGemma files, then restarts the engine.
    func clearDownloadedModel() async {
        engine?.shutdown()
        engine = nil
        state = .off
        await GemmaRuntime.clearCache()
        await configure()
    }

    // MARK: Library changes

    func libraryDidChange(_ change: LibraryChange) {
        if case .removed(let ids) = change {
            for id in ids { vectors[id] = nil }
            matrixCache = nil
            embeddedCount = vectors.count
        }
        scheduleIndexing()
    }

    func hasVector(_ id: UUID) -> Bool { vectors[id] != nil }

    // MARK: Queries

    /// Cosine similarity of every embedded snip to a text query.
    func scores(forQuery text: String) async throws -> [UUID: Float] {
        guard let engine, isReady else { throw EngineError.modelUnavailable }
        let query: [Float]
        if let cached = queryCache[text] {
            query = cached
        } else {
            query = try await engine.embed(texts: [EmbeddingPrompts.query(text, style: engine.promptStyle)]).first ?? []
            if queryCache.count > 64 { queryCache.removeAll() }
            queryCache[text] = query
        }
        return matrix().scoreMap(for: query)
    }

    /// Similarity of every embedded snip to an image (cross-modal: finds posts and notes too).
    func scores(forImage data: Data) async throws -> [UUID: Float] {
        guard let engine, isReady, engine.supportsImages else { throw EngineError.imagesUnsupported }
        guard let jpeg = await Task.detached(priority: .userInitiated, operation: { ImageCoding.embeddingJPEG(data: data) }).value else {
            throw EngineError.imagesUnsupported
        }
        let query = try await engine.embed(text: nil, images: [jpeg])
        return matrix().scoreMap(for: query)
    }

    /// Similarity of every snip to `id`, or nil if `id` has no embedding yet.
    func scores(similarTo id: UUID) -> [UUID: Float]? {
        guard let vector = vectors[id]?.vector else { return nil }
        var map = matrix().scoreMap(for: vector)
        map[id] = nil
        return map
    }

    private func matrix() -> VectorMatrix {
        if let matrixCache { return matrixCache }
        let dims = vectors.values.first?.vector.count ?? 0
        let m = VectorMatrix(dimensions: dims, rows: vectors.map { ($0.key, $0.value.vector) })
        matrixCache = m
        return m
    }

    // MARK: Indexing

    func scheduleIndexing(after delay: Double = 0.8) {
        guard isReady else { return }
        if isIndexing {
            needsAnotherPass = true
            return
        }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.runIndexing()
        }
    }

    private struct PendingDocument {
        let id: UUID
        let document: EmbeddingDocument
    }

    private func runIndexing() async {
        guard let engine, isReady, !isIndexing else { return }
        isIndexing = true
        defer {
            isIndexing = false
            pendingCount = 0
        }
        var added = 0
        repeat {
            needsAnotherPass = false
            let work = pendingDocuments(for: engine)
            pendingCount = work.count
            var index = 0
            while index < work.count {
                guard !Task.isCancelled, self.engine === engine else { return }
                // Text-only documents are batched; documents with images go one by one.
                var batch = [work[index]]
                if !work[index].document.hasImages {
                    var next = index + 1
                    while next < work.count, batch.count < 16, !work[next].document.hasImages {
                        batch.append(work[next])
                        next += 1
                    }
                }
                index += batch.count
                added += await embed(batch, with: engine)
                pendingCount = max(0, work.count - index)
                if added > 0, added % 64 < batch.count { onVectorsChanged?() }
            }
        } while needsAnotherPass && !Task.isCancelled
        if added > 0 { onVectorsChanged?() }
    }

    private func pendingDocuments(for engine: EmbeddingEngine) -> [PendingDocument] {
        let includeImages = engine.supportsImages && settings.indexPostImages
        var work: [PendingDocument] = []
        for snip in library.snips {
            let doc = EmbeddingDocumentBuilder.document(for: snip, style: engine.promptStyle, includePostImages: includeImages)
            if doc.text == nil && doc.imageFiles.isEmpty { continue }
            if vectors[snip.id]?.contentHash == doc.hash || unembeddable[snip.id] == doc.hash { continue }
            work.append(PendingDocument(id: snip.id, document: doc))
        }
        return work
    }

    /// Embeds and stores a batch. Returns how many vectors were added.
    private func embed(_ batch: [PendingDocument], with engine: EmbeddingEngine) async -> Int {
        do {
            let results = try await computeVectors(for: batch, engine: engine)
            return await store(results, engine: engine)
        } catch {
            guard batch.count > 1 else {
                unembeddable[batch[0].id] = batch[0].document.hash
                logger.error("Embedding failed: \(error.localizedDescription, privacy: .public)")
                return 0
            }
            // Retry one by one so a single bad input doesn't sink the batch.
            var added = 0
            for item in batch {
                added += await embed([item], with: engine)
            }
            return added
        }
    }

    private func computeVectors(for batch: [PendingDocument], engine: EmbeddingEngine) async throws -> [StoredVector] {
        if batch.count == 1, batch[0].document.hasImages {
            let item = batch[0]
            let media = library.media
            let files = item.document.imageFiles
            let images = await Task.detached(priority: .utility) {
                files.compactMap { ImageCoding.embeddingJPEG(at: media.url(for: $0)) }
            }.value
            var text = item.document.text
            var usable = images
            if images.count != files.count {
                // A file went missing: fall back to the text alone.
                text = text?.replacingOccurrences(of: " " + EmbeddingPrompts.imagePlaceholder, with: "")
                usable = []
            }
            let vector = try await engine.embed(text: text, images: usable)
            return [StoredVector(snipID: item.id, contentHash: item.document.hash, vector: vector)]
        }
        let texts = batch.map { $0.document.text ?? "" }
        let output = try await engine.embed(texts: texts)
        return zip(batch, output).map { StoredVector(snipID: $0.id, contentHash: $0.document.hash, vector: $1) }
    }

    private func store(_ results: [StoredVector], engine: EmbeddingEngine) async -> Int {
        let valid = results.filter { !$0.vector.isEmpty && $0.vector.allSatisfy(\.isFinite) }
        guard !valid.isEmpty, self.engine === engine else { return 0 }
        // Skip snips deleted while they were being embedded.
        let live = valid.filter { library.snip($0.snipID) != nil }
        for v in live { vectors[v.snipID] = v }
        matrixCache = nil
        embeddedCount = vectors.count
        do {
            try await library.database.saveVectors(live, model: engine.modelID)
        } catch {
            logger.error("Saving vectors failed: \(String(describing: error), privacy: .public)")
        }
        return live.count
    }
}
