import Foundation
import NaturalLanguage
import SnipperCore

/// Something that turns text (and optionally images) into vectors.
@MainActor
protocol EmbeddingEngine: AnyObject {
    /// Vectors from different model IDs are never compared; changing it re-indexes the library.
    var modelID: String { get }
    var displayName: String { get }
    var promptStyle: PromptStyle { get }
    var supportsImages: Bool { get }

    func prepare(progress: @escaping @MainActor (String, Double?) -> Void) async throws
    func embed(texts: [String]) async throws -> [[Float]]
    /// One vector for text with `<|image|>` placeholders plus the matching images (JPEG data).
    func embed(text: String?, images: [Data]) async throws -> [Float]
    func shutdown()
}

/// EmbeddingGemma 2 running in WebKit (WebGPU), 768 dimensions, text + images.
@MainActor
final class GemmaEngine: EmbeddingEngine {
    private let runtime = GemmaRuntime()
    private var status: GemmaRuntime.Status?

    var modelID: String { "embeddinggemma-2-\(status?.dtype ?? "q4")-768" }
    var displayName: String {
        guard let status else { return "EmbeddingGemma 2" }
        return "EmbeddingGemma 2 · \(status.device == "webgpu" ? "WebGPU" : "CPU")"
    }
    var promptStyle: PromptStyle { .gemma }
    var supportsImages: Bool { status?.vision ?? true }

    func prepare(progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        runtime.onEvent = { event in
            if case .progress(let label, let fraction) = event { progress(label, fraction) }
        }
        do {
            status = try await runtime.start(vision: true, preferGPU: true)
        } catch GemmaRuntime.RuntimeError.script(let message) where message.contains("WEBGPU_UNAVAILABLE") {
            runtime.stop()
            throw EngineError.webGPUUnavailable
        } catch {
            runtime.stop()
            throw error
        }
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        try await runtime.embed(texts: texts)
    }

    func embed(text: String?, images: [Data]) async throws -> [Float] {
        // Post photos use a smaller vision budget than screenshots, where detail matters.
        let budget = images.count > 1 ? 140 : 280
        return try await runtime.embed(text: text, images: images, visionBudget: budget)
    }

    func shutdown() {
        runtime.stop()
    }
}

enum EngineError: LocalizedError {
    case webGPUUnavailable
    case modelUnavailable
    case imagesUnsupported

    var errorDescription: String? {
        switch self {
        case .webGPUUnavailable: "WebGPU isn't available, which EmbeddingGemma 2 needs. Using Apple's built-in embeddings instead."
        case .modelUnavailable: "The embedding model isn't available on this Mac."
        case .imagesUnsupported: "This search engine can't read images."
        }
    }
}

/// Apple's built-in sentence embeddings (NaturalLanguage). English, text only, no download.
@MainActor
final class AppleSentenceEngine: EmbeddingEngine {
    private var embedding: SendableEmbedding?

    var modelID: String { "apple-nl-sentence-en-1" }
    var displayName: String { "Apple Natural Language" }
    var promptStyle: PromptStyle { .plain }
    var supportsImages: Bool { false }

    func prepare(progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        progress("Loading Apple embeddings", nil)
        let loaded = await Task.detached(priority: .userInitiated) {
            NLEmbedding.sentenceEmbedding(for: .english).map(SendableEmbedding.init)
        }.value
        guard let loaded else { throw EngineError.modelUnavailable }
        embedding = loaded
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        guard let embedding else { throw EngineError.modelUnavailable }
        return await Task.detached(priority: .utility) {
            texts.map { embedding.vector(for: $0) }
        }.value
    }

    func embed(text: String?, images: [Data]) async throws -> [Float] {
        guard images.isEmpty else { throw EngineError.imagesUnsupported }
        return try await embed(texts: [text ?? ""]).first ?? []
    }

    func shutdown() {
        embedding = nil
    }
}

/// NLEmbedding is immutable once loaded and safe to read from one task at a time.
private final class SendableEmbedding: @unchecked Sendable {
    private let embedding: NLEmbedding
    private let lock = NSLock()

    init(_ embedding: NLEmbedding) {
        self.embedding = embedding
    }

    func vector(for text: String) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        // Sentence embeddings work best on a few hundred characters.
        let trimmed = String(text.prefix(2_000))
        guard let values = embedding.vector(for: trimmed) else {
            return [Float](repeating: 0, count: embedding.dimension)
        }
        return VectorMath.normalized(values.map(Float.init))
    }
}
