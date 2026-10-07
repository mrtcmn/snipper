import Foundation

/// A search box query split into free text and filter operators.
///
/// Supported operators: `from:handle`, `tag:name`, `type:post|screenshot|note|link|image|clip`,
/// `is:fav`, and "quoted phrases".
public struct ParsedQuery: Equatable, Sendable {
    /// Free text with operators removed, used for semantic search.
    public var text: String = ""
    /// Normalized words for keyword matching.
    public var terms: [String] = []
    /// Normalized quoted phrases that must appear verbatim.
    public var phrases: [String] = []
    public var authors: [String] = []
    public var tags: [String] = []
    public var kinds: Set<SnipKind> = []
    public var favoritesOnly = false

    public init() {}

    public var hasFreeText: Bool { !text.isEmpty }
    public var hasFilters: Bool { !authors.isEmpty || !tags.isEmpty || !kinds.isEmpty || favoritesOnly }
    public var isEmpty: Bool { !hasFreeText && !hasFilters }
}

public enum QueryParser {
    private static let kindAliases: [String: SnipKind] = [
        "post": .tweet, "posts": .tweet, "tweet": .tweet, "tweets": .tweet, "x": .tweet,
        "screenshot": .screenshot, "screenshots": .screenshot, "shot": .screenshot, "capture": .screenshot,
        "note": .note, "notes": .note,
        "link": .link, "links": .link, "page": .link,
        "image": .image, "images": .image, "img": .image, "photo": .image,
        "clip": .text, "clips": .text, "text": .text, "selection": .text,
    ]

    public static func parse(_ raw: String) -> ParsedQuery {
        var query = ParsedQuery()
        var freeWords: [String] = []

        for token in tokenize(raw) {
            if token.quoted {
                let phrase = TextNormalizer.normalize(token.value)
                if !phrase.isEmpty {
                    query.phrases.append(phrase)
                    freeWords.append(token.value)
                }
                continue
            }
            let lower = token.value.lowercased()
            if let value = operatorValue(lower, "from:") {
                query.authors.append(value.hasPrefix("@") ? String(value.dropFirst()) : value)
            } else if let value = operatorValue(lower, "tag:") {
                query.tags.append(value.hasPrefix("#") ? String(value.dropFirst()) : value)
            } else if let value = operatorValue(lower, "type:") ?? operatorValue(lower, "kind:") {
                if let kind = kindAliases[value] { query.kinds.insert(kind) }
            } else if let value = operatorValue(lower, "is:") {
                if ["fav", "favs", "favorite", "favorites", "favourite", "star", "starred"].contains(value) {
                    query.favoritesOnly = true
                }
            } else {
                freeWords.append(token.value)
            }
        }

        query.text = freeWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        query.terms = freeWords
            .flatMap { TextNormalizer.words(in: $0) }
            .filter { !$0.isEmpty }
        return query
    }

    private static func operatorValue(_ token: String, _ prefix: String) -> String? {
        guard token.hasPrefix(prefix), token.count > prefix.count else { return nil }
        return String(token.dropFirst(prefix.count))
    }

    private struct Token { var value: String; var quoted: Bool }

    private static func tokenize(_ raw: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        func flush(quoted: Bool) {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { tokens.append(Token(value: trimmed, quoted: quoted)) }
            current = ""
        }
        for ch in raw {
            if ch == "\"" || ch == "“" || ch == "”" {
                flush(quoted: inQuotes)
                inQuotes.toggle()
            } else if ch.isWhitespace && !inQuotes {
                flush(quoted: false)
            } else {
                current.append(ch)
            }
        }
        flush(quoted: inQuotes)
        return tokens
    }
}

public enum TextNormalizer {
    /// Lowercased, accent-insensitive form used for matching.
    public static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Normalized words, splitting on anything that is not a letter, number, `@`, `#` or `_`.
    public static func words(in s: String) -> [String] {
        normalize(s)
            .split { !($0.isLetter || $0.isNumber || $0 == "@" || $0 == "#" || $0 == "_") }
            .map { word in
                // "@handle" and "#tag" should also match the bare word.
                var w = Substring(word)
                while let first = w.first, first == "@" || first == "#" { w = w.dropFirst() }
                return String(w)
            }
    }
}

/// What the ranker needs to know about a snip, precomputed once per library change.
public struct SearchCandidate: Sendable {
    public var id: UUID
    public var kind: SnipKind
    public var haystack: String
    public var title: String
    public var authorHandle: String?
    public var tags: [String]
    public var isFavorite: Bool
    public var savedAt: Date

    public init(snip: Snip) {
        id = snip.id
        kind = snip.kind
        haystack = TextNormalizer.normalize(snip.searchableText)
        title = TextNormalizer.normalize(snip.displayTitle + " " + (snip.author.map { "\($0.name) \($0.handle)" } ?? ""))
        authorHandle = snip.author.map { TextNormalizer.normalize($0.handle) }
        tags = snip.tags.map(TextNormalizer.normalize)
        isFavorite = snip.isFavorite
        savedAt = snip.savedAt
    }
}

public struct RankedHit: Sendable, Equatable {
    public var id: UUID
    public var score: Float
    /// Cosine similarity from the embedding model, when available.
    public var semantic: Float?
    /// Keyword match strength in 0...1.
    public var keyword: Float
}

/// Combines keyword matching with embedding similarity.
public enum HybridRanker {
    public static let semanticWeight: Float = 0.75

    public static func keywordScore(_ query: ParsedQuery, _ c: SearchCandidate) -> Float {
        guard !query.terms.isEmpty || !query.phrases.isEmpty else { return 0 }
        var total: Float = 0
        var possible: Float = 0
        for term in query.terms {
            possible += 1
            guard c.haystack.contains(term) else { continue }
            var s: Float = 0.7
            if containsWordPrefix(c.haystack, term) { s += 0.15 }
            if c.title.contains(term) { s += 0.15 }
            total += s
        }
        for phrase in query.phrases {
            possible += 1
            if c.haystack.contains(phrase) { total += 1 }
        }
        return possible > 0 ? min(1, total / possible) : 0
    }

    public static func passesFilters(_ query: ParsedQuery, _ c: SearchCandidate) -> Bool {
        if query.favoritesOnly && !c.isFavorite { return false }
        if !query.kinds.isEmpty && !query.kinds.contains(c.kind) { return false }
        if !query.authors.isEmpty {
            guard let handle = c.authorHandle, query.authors.contains(where: { handle == TextNormalizer.normalize($0) }) else {
                return false
            }
        }
        for tag in query.tags where !c.tags.contains(TextNormalizer.normalize(tag)) {
            return false
        }
        return true
    }

    /// Ranks every candidate that passes the query's filters, best first.
    ///
    /// - Parameter semantic: cosine similarity per snip. Pass nil for keyword-only search.
    ///   Snips missing from the map (not embedded yet) fall back to their keyword score.
    public static func rank(_ candidates: [SearchCandidate], query: ParsedQuery, semantic: [UUID: Float]?) -> [RankedHit] {
        var hits: [RankedHit] = []
        hits.reserveCapacity(candidates.count)
        var savedAt: [UUID: Date] = [:]

        for c in candidates where passesFilters(query, c) {
            let kw = keywordScore(query, c)
            let sim = semantic?[c.id]
            let score: Float
            if !query.hasFreeText {
                // Filter-only queries keep recency order; image and "more like this"
                // queries pass similarity without text.
                score = sim ?? 0
            } else if let semantic, !semantic.isEmpty {
                if let sim {
                    score = semanticWeight * max(0, sim) + (1 - semanticWeight) * kw
                } else {
                    score = kw * 0.6
                }
            } else {
                guard kw > 0 else { continue }
                score = kw
            }
            savedAt[c.id] = c.savedAt
            hits.append(RankedHit(id: c.id, score: score, semantic: sim, keyword: kw))
        }

        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return (savedAt[a.id] ?? .distantPast) > (savedAt[b.id] ?? .distantPast)
        }
        return hits
    }

    /// The hits worth listing: keyword matches plus semantic hits close to the best one.
    public static func relevant(_ hits: [RankedHit], window: Float = 0.2, limit: Int = 200) -> [RankedHit] {
        guard let top = hits.first?.score else { return [] }
        let floor = top - window
        return Array(hits.lazy.filter { $0.keyword > 0 || $0.score >= floor }.prefix(limit))
    }

    private static func containsWordPrefix(_ haystack: String, _ term: String) -> Bool {
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: term, range: searchRange) {
            if range.lowerBound == haystack.startIndex { return true }
            let before = haystack[haystack.index(before: range.lowerBound)]
            if !(before.isLetter || before.isNumber) { return true }
            searchRange = range.upperBound..<haystack.endIndex
        }
        return false
    }
}
