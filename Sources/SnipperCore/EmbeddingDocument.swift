import Foundation

/// How an embedding model expects its inputs to be phrased.
public enum PromptStyle: String, Sendable {
    /// EmbeddingGemma task prefixes, with `<|image|>` placeholders for media.
    case gemma
    /// Bare text, for models without task prompts.
    case plain
}

/// The input to embed for one snip.
public struct EmbeddingDocument: Sendable, Equatable {
    /// Text to embed. For `.gemma` it contains one `<|image|>` placeholder per image.
    public var text: String?
    /// Local media file names, in placeholder order.
    public var imageFiles: [String]
    /// Changes whenever the input changes, so stale vectors can be detected.
    public var hash: String

    public var hasImages: Bool { !imageFiles.isEmpty }
}

public enum EmbeddingPrompts {
    public static let imagePlaceholder = "<|image|>"
    private static let reservedTokens = ["<|image|>", "<|video|>", "<|audio|>", "<|image>", "<image|>", "<|audio>", "<audio|>"]

    /// Query phrasing for retrieval.
    public static func query(_ text: String, style: PromptStyle) -> String {
        let clean = sanitize(text)
        switch style {
        case .gemma: return "task: search result | query: \(clean)"
        case .plain: return clean
        }
    }

    /// Document phrasing for retrieval: `title: {title} | text: {content}`.
    public static func document(title: String?, text: String, style: PromptStyle) -> String {
        switch style {
        case .gemma:
            let t = sanitize(title ?? "").replacingOccurrences(of: "|", with: "/")
            return "title: \(t.isEmpty ? "none" : t) | text: \(sanitize(text))"
        case .plain:
            return [title, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    /// Removes the model's special placeholder tokens from user content, so only the
    /// placeholders we add line up with the images we pass.
    public static func sanitize(_ text: String) -> String {
        var s = text
        for token in reservedTokens where s.contains(token) {
            s = s.replacingOccurrences(of: token, with: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum EmbeddingDocumentBuilder {
    /// Builds the embedding input for `snip`.
    ///
    /// - Parameters:
    ///   - includePostImages: attach a post's first photo, so posts can be found by what their images show.
    ///   - maxCharacters: text budget; long notes are truncated to stay inside the model's batch limits.
    public static func document(
        for snip: Snip,
        style: PromptStyle,
        includePostImages: Bool = true,
        maxCharacters: Int = 6_000
    ) -> EmbeddingDocument {
        var title: String?
        var parts: [String] = []
        var images: [String] = []

        func localImage(_ media: [SnipMedia]) -> String? {
            media.first { $0.kind == .image && $0.localFile != nil }?.localFile
                ?? media.first { $0.localFile != nil }?.localFile
        }

        switch snip.kind {
        case .tweet:
            if let author = snip.author {
                title = author.name.isEmpty ? "@\(author.handle)" : "\(author.name) (@\(author.handle))"
            }
            parts.append(snip.body)
            if let quoted = snip.tweet?.quoted, !quoted.text.isEmpty {
                let who = quoted.author.map { "@\($0.handle)" } ?? "a post"
                parts.append("Quoting \(who): \(quoted.text)")
            }
            if let card = snip.tweet?.card {
                parts.append([card.title, card.summary].compactMap { $0 }.joined(separator: " — "))
            }
            for alt in snip.media.compactMap(\.alt) where !alt.isEmpty { parts.append(alt) }
            if includePostImages, let file = localImage(snip.media) { images.append(file) }

        case .screenshot, .image:
            title = snip.title.isEmpty ? (snip.appName ?? snip.kind.label) : snip.title
            if !snip.body.isEmpty { parts.append(snip.body) }
            if let ocr = snip.ocrText, !ocr.isEmpty { parts.append(String(ocr.prefix(1_500))) }
            if let file = localImage(snip.media) { images.append(file) }

        case .note, .text:
            title = snip.title.isEmpty ? nil : snip.title
            parts.append(snip.body)
            if let ocr = snip.ocrText, !ocr.isEmpty { parts.append(ocr) }
            if let file = localImage(snip.media) { images.append(file) }

        case .link:
            title = snip.title.isEmpty ? snip.link?.title : snip.title
            if let summary = snip.link?.summary, !summary.isEmpty { parts.append(summary) }
            if !snip.body.isEmpty { parts.append(snip.body) }
            if let site = snip.link?.siteName ?? snip.domain { parts.append(site) }
        }

        if !snip.tags.isEmpty { parts.append(snip.tags.map { "#\($0)" }.joined(separator: " ")) }

        var body = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if body.count > maxCharacters { body = String(body.prefix(maxCharacters)) }

        let text: String?
        switch style {
        case .gemma:
            var t = EmbeddingPrompts.document(title: title, text: body, style: .gemma)
            for _ in images { t += " " + EmbeddingPrompts.imagePlaceholder }
            text = t
        case .plain:
            images.removeAll()
            let t = EmbeddingPrompts.document(title: title, text: body, style: .plain)
            text = t.isEmpty ? nil : t
        }

        let hash = ContentHash.fnv1a([style.rawValue, text ?? "", images.joined(separator: ",")].joined(separator: "\u{1F}"))
        return EmbeddingDocument(text: text, imageFiles: images, hash: hash)
    }
}
