import Foundation

/// Body of `POST /api/snips`, sent by the browser extension.
public struct ExtensionEnvelope: Decodable, Sendable {
    public var source: String?
    public var items: [ExtensionItem]

    public init(source: String? = nil, items: [ExtensionItem]) {
        self.source = source
        self.items = items
    }
}

/// A post as normalized by the extension's GraphQL/DOM parser (`Extension/shared/tweet-parse.js`).
public struct ExtensionPost: Codable, Sendable, Equatable {
    public struct Author: Codable, Sendable, Equatable {
        public var name: String?
        public var handle: String?
        public var avatar: String?
        public var verified: Bool?
    }

    public struct Metrics: Codable, Sendable, Equatable {
        public var likes: Int?
        public var retweets: Int?
        public var replies: Int?
        public var quotes: Int?
        public var bookmarks: Int?
        public var views: Int?
    }

    public struct Media: Codable, Sendable, Equatable {
        public var type: String?
        public var url: String?
        public var width: Int?
        public var height: Int?
        public var alt: String?
        public var videoUrl: String?
    }

    public struct Card: Codable, Sendable, Equatable {
        public var url: String?
        public var title: String?
        public var description: String?
        public var image: String?
        public var siteName: String?
    }

    /// Quoted posts carry the same fields, without a nested quote.
    public struct Quoted: Codable, Sendable, Equatable {
        public var id: String?
        public var url: String?
        public var text: String?
        public var createdAt: String?
        public var author: Author?
        public var media: [Media]?
    }

    public var id: String
    public var url: String?
    public var text: String?
    public var createdAt: String?
    public var lang: String?
    public var conversationId: String?
    public var author: Author?
    public var metrics: Metrics?
    public var media: [Media]?
    public var quoted: Quoted?
    public var card: Card?
}

public struct ExtensionItem: Decodable, Sendable {
    /// "tweet", "selection", "page", "link", "image" or "note".
    public var type: String
    public var tweet: ExtensionPost?
    public var text: String?
    public var url: String?
    public var title: String?
    public var description: String?
    public var image: String?
    public var siteName: String?
    public var favicon: String?
    /// For images: where the image lives on the web.
    public var srcUrl: String?
    /// For images and tab screenshots: inline `data:` URL bytes.
    public var dataUrl: String?
    public var tags: [String]?
}

/// A snip built from an extension item, plus media the app still has to store.
public struct IncomingSnip: Sendable {
    public var snip: Snip
    /// Decoded inline image bytes to save as the snip's first media item.
    public var inlineImage: Data?
    public var inlineImageExtension: String?
    /// Remote image to download and attach.
    public var remoteImage: String?
}

public enum ExtensionPayloadError: Error, Equatable {
    case unsupportedType(String)
    case missingContent
}

public enum ExtensionPayload {
    public static func incoming(_ item: ExtensionItem, source: String?, now: Date = Date()) throws -> IncomingSnip {
        let tags = (item.tags ?? []).map(TagNormalizer.normalize).filter { !$0.isEmpty }
        switch item.type {
        case "tweet", "post":
            guard let post = item.tweet else { throw ExtensionPayloadError.missingContent }
            var snip = snip(from: post, source: source, now: now)
            snip.tags = tags
            return IncomingSnip(snip: snip)

        case "selection", "note", "text":
            let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ExtensionPayloadError.missingContent }
            let snip = Snip(
                kind: item.type == "note" ? .note : .text,
                title: item.title ?? "",
                body: text,
                url: item.url,
                tags: tags,
                createdAt: now,
                savedAt: now,
                source: source,
                link: item.url == nil ? nil : LinkInfo(url: item.url, title: item.title, siteName: item.siteName, faviconURL: item.favicon)
            )
            return IncomingSnip(snip: snip)

        case "page", "link":
            guard let url = item.url, !url.isEmpty else { throw ExtensionPayloadError.missingContent }
            let info = LinkInfo(
                url: url,
                title: item.title,
                summary: item.description,
                siteName: item.siteName,
                imageURL: item.image,
                faviconURL: item.favicon
            )
            let snip = Snip(
                kind: .link,
                title: item.title ?? "",
                body: item.text ?? "",
                url: url,
                tags: tags,
                createdAt: now,
                savedAt: now,
                source: source,
                externalID: "url:\(URLNormalizer.normalize(url))",
                link: info
            )
            return IncomingSnip(snip: snip)

        case "image", "screenshot":
            var data: Data?
            var ext: String?
            if let dataURL = item.dataUrl, let decoded = DataURL.decode(dataURL) {
                data = decoded.data
                ext = decoded.fileExtension
            }
            guard data != nil || item.srcUrl != nil else { throw ExtensionPayloadError.missingContent }
            let isScreenshot = item.type == "screenshot"
            let snip = Snip(
                kind: isScreenshot ? .screenshot : .image,
                title: item.title ?? "",
                body: item.text ?? "",
                url: item.url,
                media: [],
                tags: tags,
                createdAt: now,
                savedAt: now,
                source: source,
                link: item.url == nil ? nil : LinkInfo(url: item.url, title: item.title, siteName: item.siteName)
            )
            return IncomingSnip(snip: snip, inlineImage: data, inlineImageExtension: ext, remoteImage: data == nil ? item.srcUrl : nil)

        default:
            throw ExtensionPayloadError.unsupportedType(item.type)
        }
    }

    public static func snip(from post: ExtensionPost, source: String?, now: Date = Date()) -> Snip {
        let author = post.author.map(Self.author)
        let reference = TweetReference(id: post.id, handle: author?.handle.isEmpty == false ? author?.handle : nil)
        var info = TweetInfo(
            tweetID: post.id,
            conversationID: post.conversationId,
            lang: post.lang,
            likes: post.metrics?.likes,
            reposts: post.metrics?.retweets,
            replies: post.metrics?.replies,
            quotes: post.metrics?.quotes,
            bookmarks: post.metrics?.bookmarks,
            views: post.metrics?.views
        )
        if let q = post.quoted, let text = q.text {
            let qa = q.author.map(Self.author)
            info.quoted = QuotedPost(
                tweetID: q.id,
                url: q.url ?? q.id.map { TweetReference(id: $0, handle: qa?.handle).canonicalURL },
                text: text,
                author: qa,
                createdAt: q.createdAt.flatMap(DateParsing.parse),
                media: (q.media ?? []).compactMap(Self.media)
            )
        }
        if let card = post.card {
            let link = LinkInfo(url: card.url, title: card.title, summary: card.description, siteName: card.siteName, imageURL: card.image)
            info.card = link.isEmpty ? nil : link
        }
        return Snip(
            kind: .tweet,
            body: post.text ?? "",
            url: post.url ?? reference.canonicalURL,
            author: author,
            media: (post.media ?? []).compactMap(Self.media),
            createdAt: post.createdAt.flatMap(DateParsing.parse) ?? now,
            savedAt: now,
            source: source,
            externalID: reference.externalID,
            tweet: info
        )
    }

    static func author(_ a: ExtensionPost.Author) -> SnipAuthor {
        SnipAuthor(
            name: a.name ?? a.handle ?? "",
            handle: a.handle ?? "",
            avatarURL: a.avatar.map(PostMedia.largerAvatar),
            verified: a.verified ?? false
        )
    }

    static func media(_ m: ExtensionPost.Media) -> SnipMedia? {
        guard let url = m.url, !url.isEmpty else { return nil }
        let kind: SnipMedia.Kind
        switch m.type {
        case "video": kind = .video
        case "gif", "animated_gif": kind = .gif
        default: kind = .image
        }
        return SnipMedia(kind: kind, remoteURL: url, videoURL: m.videoUrl, width: m.width, height: m.height, alt: m.alt)
    }
}

public enum DataURL {
    /// Decodes `data:image/png;base64,....`.
    public static func decode(_ string: String) -> (data: Data, mimeType: String, fileExtension: String)? {
        guard string.hasPrefix("data:"), let comma = string.firstIndex(of: ",") else { return nil }
        let header = string[string.index(string.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let mime = String(header.dropLast(7))
        guard let data = Data(base64Encoded: String(string[string.index(after: comma)...]), options: .ignoreUnknownCharacters) else {
            return nil
        }
        let ext: String
        switch mime {
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        case "image/heic": ext = "heic"
        default: ext = "png"
        }
        return (data, mime, ext)
    }
}

public enum URLNormalizer {
    /// Lowercases scheme and host and drops fragments and tracking parameters,
    /// so the same page saved twice is recognized.
    public static func normalize(_ string: String) -> String {
        guard var components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return string
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if let items = components.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !(name.hasPrefix("utm_") || ["fbclid", "gclid", "ref_src", "igshid", "mc_cid", "mc_eid"].contains(name))
            }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        if components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? string
    }
}

public enum TagNormalizer {
    /// "#Design Systems " → "design-systems".
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") { s.removeFirst() }
        let parts = s.lowercased().split { $0.isWhitespace }
        return parts.joined(separator: "-")
    }
}
