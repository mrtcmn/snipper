import Foundation

/// What a snip is. Raw values are persisted, so never rename them.
public enum SnipKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case tweet
    case screenshot
    case note
    case link
    case image
    /// Text clipped from somewhere else (a selection, the clipboard, OCR).
    case text

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tweet: "Post"
        case .screenshot: "Screenshot"
        case .note: "Note"
        case .link: "Link"
        case .image: "Image"
        case .text: "Clip"
        }
    }

    public var pluralLabel: String {
        switch self {
        case .tweet: "Posts"
        case .screenshot: "Screenshots"
        case .note: "Notes"
        case .link: "Links"
        case .image: "Images"
        case .text: "Clips"
        }
    }
}

public struct SnipAuthor: Codable, Hashable, Sendable {
    public var name: String
    /// Handle without the leading "@".
    public var handle: String
    public var avatarURL: String?
    public var verified: Bool

    public init(name: String, handle: String, avatarURL: String? = nil, verified: Bool = false) {
        self.name = name
        self.handle = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        self.avatarURL = avatarURL
        self.verified = verified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let handle = try c.decodeIfPresent(String.self, forKey: .handle) ?? ""
        self.init(
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? handle,
            handle: handle,
            avatarURL: try c.decodeIfPresent(String.self, forKey: .avatarURL),
            verified: try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        )
    }
}

public struct SnipMedia: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case image, video, gif
    }

    public var kind: Kind
    /// File name inside the app's media folder, once the bytes are stored locally.
    public var localFile: String?
    /// Where the media came from (a still image, or a video's poster frame).
    public var remoteURL: String?
    /// Playable video URL for videos and GIFs.
    public var videoURL: String?
    public var width: Int?
    public var height: Int?
    public var alt: String?

    public var id: String { localFile ?? remoteURL ?? videoURL ?? "media-\(kind.rawValue)" }

    public var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    public init(
        kind: Kind = .image,
        localFile: String? = nil,
        remoteURL: String? = nil,
        videoURL: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        alt: String? = nil
    ) {
        self.kind = kind
        self.localFile = localFile
        self.remoteURL = remoteURL
        self.videoURL = videoURL
        self.width = width
        self.height = height
        self.alt = alt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .image,
            localFile: try c.decodeIfPresent(String.self, forKey: .localFile),
            remoteURL: try c.decodeIfPresent(String.self, forKey: .remoteURL),
            videoURL: try c.decodeIfPresent(String.self, forKey: .videoURL),
            width: try c.decodeIfPresent(Int.self, forKey: .width),
            height: try c.decodeIfPresent(Int.self, forKey: .height),
            alt: try c.decodeIfPresent(String.self, forKey: .alt)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind, localFile, remoteURL, videoURL, width, height, alt
    }
}

public struct LinkInfo: Codable, Hashable, Sendable {
    public var url: String?
    public var title: String?
    public var summary: String?
    public var siteName: String?
    public var imageURL: String?
    public var faviconURL: String?

    public init(
        url: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        siteName: String? = nil,
        imageURL: String? = nil,
        faviconURL: String? = nil
    ) {
        self.url = url
        self.title = title
        self.summary = summary
        self.siteName = siteName
        self.imageURL = imageURL
        self.faviconURL = faviconURL
    }

    public var isEmpty: Bool {
        [title, summary, siteName, imageURL].allSatisfy { ($0 ?? "").isEmpty }
    }
}

/// A post quoted inside another post.
public struct QuotedPost: Codable, Hashable, Sendable {
    public var tweetID: String?
    public var url: String?
    public var text: String
    public var author: SnipAuthor?
    public var createdAt: Date?
    public var media: [SnipMedia]

    public init(
        tweetID: String? = nil,
        url: String? = nil,
        text: String,
        author: SnipAuthor? = nil,
        createdAt: Date? = nil,
        media: [SnipMedia] = []
    ) {
        self.tweetID = tweetID
        self.url = url
        self.text = text
        self.author = author
        self.createdAt = createdAt
        self.media = media
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tweetID: try c.decodeIfPresent(String.self, forKey: .tweetID),
            url: try c.decodeIfPresent(String.self, forKey: .url),
            text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
            author: try? c.decodeIfPresent(SnipAuthor.self, forKey: .author),
            createdAt: try? c.decodeIfPresent(Date.self, forKey: .createdAt),
            media: (try? c.decodeIfPresent([SnipMedia].self, forKey: .media)) ?? []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case tweetID, url, text, author, createdAt, media
    }
}

/// Post-specific details for `.tweet` snips.
public struct TweetInfo: Codable, Hashable, Sendable {
    public var tweetID: String
    public var conversationID: String?
    public var lang: String?
    public var likes: Int?
    public var reposts: Int?
    public var replies: Int?
    public var quotes: Int?
    public var bookmarks: Int?
    public var views: Int?
    public var quoted: QuotedPost?
    public var card: LinkInfo?

    public init(
        tweetID: String,
        conversationID: String? = nil,
        lang: String? = nil,
        likes: Int? = nil,
        reposts: Int? = nil,
        replies: Int? = nil,
        quotes: Int? = nil,
        bookmarks: Int? = nil,
        views: Int? = nil,
        quoted: QuotedPost? = nil,
        card: LinkInfo? = nil
    ) {
        self.tweetID = tweetID
        self.conversationID = conversationID
        self.lang = lang
        self.likes = likes
        self.reposts = reposts
        self.replies = replies
        self.quotes = quotes
        self.bookmarks = bookmarks
        self.views = views
        self.quoted = quoted
        self.card = card
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tweetID: try c.decodeIfPresent(String.self, forKey: .tweetID) ?? "",
            conversationID: try c.decodeIfPresent(String.self, forKey: .conversationID),
            lang: try c.decodeIfPresent(String.self, forKey: .lang),
            likes: try c.decodeIfPresent(Int.self, forKey: .likes),
            reposts: try c.decodeIfPresent(Int.self, forKey: .reposts),
            replies: try c.decodeIfPresent(Int.self, forKey: .replies),
            quotes: try c.decodeIfPresent(Int.self, forKey: .quotes),
            bookmarks: try c.decodeIfPresent(Int.self, forKey: .bookmarks),
            views: try c.decodeIfPresent(Int.self, forKey: .views),
            quoted: try? c.decodeIfPresent(QuotedPost.self, forKey: .quoted),
            card: try? c.decodeIfPresent(LinkInfo.self, forKey: .card)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case tweetID, conversationID, lang, likes, reposts, replies, quotes, bookmarks, views, quoted, card
    }
}

/// One saved item in the library.
public struct Snip: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: SnipKind
    public var title: String
    public var body: String
    public var url: String?
    public var author: SnipAuthor?
    public var media: [SnipMedia]
    public var tags: [String]
    public var isFavorite: Bool
    /// When the original content was made (post date), or the capture time.
    public var createdAt: Date
    /// When it entered the library.
    public var savedAt: Date
    public var updatedAt: Date
    /// Where it came from, e.g. "x-bookmarks", "extension", "capture", "browser:Arc".
    public var source: String?
    /// Text recognized in the snip's image.
    public var ocrText: String?
    /// Stable key for de-duplication, e.g. "x:1790000000000000000".
    public var externalID: String?
    public var tweet: TweetInfo?
    public var link: LinkInfo?
    /// App that was frontmost when a screenshot was taken.
    public var appName: String?

    public init(
        id: UUID = UUID(),
        kind: SnipKind,
        title: String = "",
        body: String = "",
        url: String? = nil,
        author: SnipAuthor? = nil,
        media: [SnipMedia] = [],
        tags: [String] = [],
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        savedAt: Date = Date(),
        updatedAt: Date? = nil,
        source: String? = nil,
        ocrText: String? = nil,
        externalID: String? = nil,
        tweet: TweetInfo? = nil,
        link: LinkInfo? = nil,
        appName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.url = url
        self.author = author
        self.media = media
        self.tags = tags
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.savedAt = savedAt
        self.updatedAt = updatedAt ?? savedAt
        self.source = source
        self.ocrText = ocrText
        self.externalID = externalID
        self.tweet = tweet
        self.link = link
        self.appName = appName
    }

    // Decoding tolerates missing or malformed optional fields, so rows written by
    // older versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? SnipKind.note.rawValue
        let savedAt = (try? c.decodeIfPresent(Date.self, forKey: .savedAt)) ?? Date()
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            kind: SnipKind(rawValue: rawKind) ?? .note,
            title: (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "",
            body: (try? c.decodeIfPresent(String.self, forKey: .body)) ?? "",
            url: try? c.decodeIfPresent(String.self, forKey: .url),
            author: try? c.decodeIfPresent(SnipAuthor.self, forKey: .author),
            media: (try? c.decodeIfPresent([SnipMedia].self, forKey: .media)) ?? [],
            tags: (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? [],
            isFavorite: (try? c.decodeIfPresent(Bool.self, forKey: .isFavorite)) ?? false,
            createdAt: (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? savedAt,
            savedAt: savedAt,
            updatedAt: (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? savedAt,
            source: try? c.decodeIfPresent(String.self, forKey: .source),
            ocrText: try? c.decodeIfPresent(String.self, forKey: .ocrText),
            externalID: try? c.decodeIfPresent(String.self, forKey: .externalID),
            tweet: try? c.decodeIfPresent(TweetInfo.self, forKey: .tweet),
            link: try? c.decodeIfPresent(LinkInfo.self, forKey: .link),
            appName: try? c.decodeIfPresent(String.self, forKey: .appName)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, body, url, author, media, tags, isFavorite, createdAt, savedAt, updatedAt
        case source, ocrText, externalID, tweet, link, appName
    }
}

// MARK: - Derived values

extension Snip {
    /// Title to show in lists: the explicit title, else something meaningful from the content.
    public var displayTitle: String {
        let explicit = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        if kind == .tweet, let author {
            return author.name.isEmpty ? "@\(author.handle)" : author.name
        }
        if let line = body.firstNonEmptyLine { return String(line.prefix(120)) }
        if let line = ocrText?.firstNonEmptyLine { return String(line.prefix(120)) }
        if let host = url.flatMap(URL.init(string:))?.host { return host }
        return kind.label
    }

    /// The first image or video poster to use as the snip's thumbnail.
    public var primaryMedia: SnipMedia? {
        media.first { $0.kind == .image } ?? media.first
    }

    public var hasVisualMedia: Bool { !media.isEmpty }

    /// Host name of the snip's URL, without "www.".
    public var domain: String? {
        guard let host = url.flatMap(URL.init(string:))?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Everything a keyword search should look at.
    public var searchableText: String {
        var parts: [String] = [title, body]
        if let author { parts.append("\(author.name) @\(author.handle) \(author.handle)") }
        if let ocrText { parts.append(ocrText) }
        if let quoted = tweet?.quoted {
            parts.append(quoted.text)
            if let a = quoted.author { parts.append("\(a.name) @\(a.handle)") }
        }
        if let card = tweet?.card { parts.append([card.title, card.summary, card.siteName].compactMap { $0 }.joined(separator: " ")) }
        if let link { parts.append([link.title, link.summary, link.siteName].compactMap { $0 }.joined(separator: " ")) }
        if let appName { parts.append(appName) }
        if let url { parts.append(url) }
        parts.append(contentsOf: media.compactMap(\.alt))
        parts.append(contentsOf: tags)
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension String {
    var firstNonEmptyLine: Substring? {
        split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            .map { Substring($0) }
    }
}

// MARK: - Coding

/// The JSON encoders used for storage and for exports.
public enum SnipCoding {
    /// Compact encoding for the database.
    public static func storageEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    public static func storageDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    /// Readable encoding for exports, with ISO 8601 dates.
    public static func exportEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func exportDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let seconds = try? c.decode(Double.self) {
                // Accept both seconds and milliseconds since 1970.
                return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
            }
            let string = try c.decode(String.self)
            guard let date = DateParsing.parse(string) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized date: \(string)")
            }
            return date
        }
        return d
    }
}
