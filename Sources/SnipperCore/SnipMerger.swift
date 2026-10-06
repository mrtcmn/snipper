import Foundation

public enum SnipMerger {
    /// Combines a fresh capture of an item that is already in the library.
    ///
    /// User data (tags, favorite, title edits, local media) is kept; content and
    /// metrics are refreshed when the incoming copy has more to offer.
    public static func merge(existing: Snip, incoming: Snip, now: Date = Date()) -> Snip {
        var merged = existing

        let incomingBody = incoming.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if incomingBody.count > existing.body.trimmingCharacters(in: .whitespacesAndNewlines).count {
            merged.body = incoming.body
        }
        if merged.title.isEmpty { merged.title = incoming.title }
        if merged.url == nil { merged.url = incoming.url }

        if let a = incoming.author {
            if var current = merged.author {
                if current.name.isEmpty || current.name == current.handle { current.name = a.name }
                if current.handle.isEmpty { current.handle = a.handle }
                if a.avatarURL != nil { current.avatarURL = a.avatarURL }
                current.verified = current.verified || a.verified
                merged.author = current
            } else {
                merged.author = a
            }
        }

        merged.media = mergeMedia(existing.media, incoming.media)
        merged.tags = mergeTags(existing.tags, incoming.tags)
        merged.isFavorite = existing.isFavorite || incoming.isFavorite
        // A real post date beats a placeholder "now" from a sparse import.
        if incoming.kind == .tweet, incoming.createdAt < existing.createdAt { merged.createdAt = incoming.createdAt }
        merged.ocrText = existing.ocrText ?? incoming.ocrText
        merged.source = existing.source ?? incoming.source
        merged.link = mergeLink(existing.link, incoming.link)
        merged.tweet = mergeTweet(existing.tweet, incoming.tweet)

        if merged != existing { merged.updatedAt = now }
        return merged
    }

    static func mergeTags(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0).inserted }
    }

    static func mergeMedia(_ existing: [SnipMedia], _ incoming: [SnipMedia]) -> [SnipMedia] {
        guard !incoming.isEmpty else { return existing }
        guard !existing.isEmpty else { return incoming }
        var result = existing
        for m in incoming {
            if let i = result.firstIndex(where: { sameMedia($0, m) }) {
                // Keep the stored file; fill in details we lacked.
                result[i].videoURL = result[i].videoURL ?? m.videoURL
                result[i].width = result[i].width ?? m.width
                result[i].height = result[i].height ?? m.height
                result[i].alt = result[i].alt ?? m.alt
            } else {
                result.append(m)
            }
        }
        return result
    }

    /// Compares X media URLs ignoring size/format parameters.
    static func sameMedia(_ a: SnipMedia, _ b: SnipMedia) -> Bool {
        guard let ua = a.remoteURL, let ub = b.remoteURL else { return false }
        func key(_ s: String) -> String {
            var base = s.split(separator: "?").first.map(String.init) ?? s
            if let dot = base.lastIndex(of: "."), base[dot...].count <= 5 { base = String(base[..<dot]) }
            return base
        }
        return key(ua) == key(ub)
    }

    static func mergeLink(_ a: LinkInfo?, _ b: LinkInfo?) -> LinkInfo? {
        guard let b else { return a }
        guard var a else { return b }
        a.title = a.title ?? b.title
        a.summary = a.summary ?? b.summary
        a.siteName = a.siteName ?? b.siteName
        a.imageURL = a.imageURL ?? b.imageURL
        a.faviconURL = a.faviconURL ?? b.faviconURL
        return a
    }

    static func mergeTweet(_ a: TweetInfo?, _ b: TweetInfo?) -> TweetInfo? {
        guard let b else { return a }
        guard var a else { return b }
        a.conversationID = a.conversationID ?? b.conversationID
        a.lang = a.lang ?? b.lang
        a.likes = b.likes ?? a.likes
        a.reposts = b.reposts ?? a.reposts
        a.replies = b.replies ?? a.replies
        a.quotes = b.quotes ?? a.quotes
        a.bookmarks = b.bookmarks ?? a.bookmarks
        a.views = b.views ?? a.views
        a.quoted = a.quoted ?? b.quoted
        a.card = a.card ?? b.card
        return a
    }
}

public enum CompactNumber {
    /// 999 → "999", 1_250 → "1.3K", 15_300 → "15.3K", 2_000_000 → "2M".
    public static func format(_ value: Int) -> String {
        let n = Double(abs(value))
        let sign = value < 0 ? "-" : ""
        func trimmed(_ d: Double, _ suffix: String) -> String {
            let rounded = (d * 10).rounded() / 10
            let text = rounded.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(rounded)) : String(format: "%.1f", rounded)
            return sign + text + suffix
        }
        switch n {
        case ..<1_000: return sign + String(Int(n))
        case ..<999_950: return trimmed(n / 1_000, "K")
        case ..<999_950_000: return trimmed(n / 1_000_000, "M")
        default: return trimmed(n / 1_000_000_000, "B")
        }
    }
}
