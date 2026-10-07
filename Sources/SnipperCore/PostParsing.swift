import Foundation

public enum PostParseError: Error, Equatable, CustomStringConvertible {
    case invalidJSON
    case unavailable(String)

    public var description: String {
        switch self {
        case .invalidJSON: "The response was not valid JSON."
        case .unavailable(let reason): "The post is unavailable (\(reason))."
        }
    }
}

/// Turns raw post text into what X displays.
public enum PostText {
    /// The raw text is HTML-escaped while X computes indices on the unescaped text,
    /// so entities are decoded before the display range is applied.
    ///
    /// - Parameters:
    ///   - displayRange: `[start, end)` in Unicode code points; trims reply mentions and media links.
    ///   - urls: t.co link → expanded URL.
    ///   - mediaURLs: t.co links that only point at attached media, which are removed.
    public static func clean(
        _ text: String,
        displayRange: [Int]? = nil,
        urls: [(short: String, expanded: String)] = [],
        mediaURLs: [String] = []
    ) -> String {
        var s = HTMLText.decodeEntities(text)
        if let range = displayRange, range.count == 2 {
            let scalars = Array(s.unicodeScalars)
            let start = max(0, min(range[0], scalars.count))
            let end = max(start, min(range[1], scalars.count))
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[start..<end])
            s = String(view)
        }
        for url in urls where !url.short.isEmpty && !url.expanded.isEmpty {
            s = s.replacingOccurrences(of: url.short, with: url.expanded)
        }
        for url in mediaURLs where !url.isEmpty {
            s = s.replacingOccurrences(of: url, with: "")
        }
        s = HTMLText.replace(s, #"[ \t]+\n"#, "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Untyped JSON access helpers.
enum JSONValue {
    static func object(_ any: Any?) -> [String: Any]? { any as? [String: Any] }
    static func array(_ any: Any?) -> [Any] { any as? [Any] ?? [] }

    static func string(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func int(_ any: Any?) -> Int? {
        switch any {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces)) ?? Double(s).map { Int($0) }
        default: return nil
        }
    }

    static func bool(_ any: Any?) -> Bool? {
        switch any {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "1", "yes"].contains(s.lowercased())
        default: return nil
        }
    }

    /// Follows a dotted path such as "user.screen_name".
    static func value(_ root: Any?, _ path: String) -> Any? {
        var current = root
        for key in path.split(separator: ".") {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[String(key)]
        }
        return current
    }
}

/// Parses X's public embed JSON (`cdn.syndication.twimg.com/tweet-result`).
public enum SyndicationParser {
    public static func snip(from data: Data, source: String? = nil, now: Date = Date()) throws -> Snip {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PostParseError.invalidJSON
        }
        let typename = JSONValue.string(root["__typename"])
        if typename == "TweetTombstone" { throw PostParseError.unavailable("removed or protected") }
        guard let post = parsePost(root) else { throw PostParseError.unavailable("not found") }

        var info = TweetInfo(
            tweetID: post.id,
            conversationID: JSONValue.string(root["conversation_id_str"]),
            lang: JSONValue.string(root["lang"]),
            likes: JSONValue.int(root["favorite_count"]),
            replies: JSONValue.int(root["conversation_count"])
        )
        if let quoted = JSONValue.object(root["quoted_tweet"]), let q = parsePost(quoted) {
            info.quoted = QuotedPost(tweetID: q.id, url: q.reference.canonicalURL, text: q.text, author: q.author, createdAt: q.createdAt, media: q.media)
        }
        info.card = card(root["card"])

        return Snip(
            kind: .tweet,
            body: post.text,
            url: post.reference.canonicalURL,
            author: post.author,
            media: post.media,
            createdAt: post.createdAt ?? now,
            savedAt: now,
            source: source,
            externalID: post.reference.externalID,
            tweet: info
        )
    }

    struct ParsedPost {
        var id: String
        var reference: TweetReference
        var text: String
        var author: SnipAuthor?
        var createdAt: Date?
        var media: [SnipMedia]
    }

    static func parsePost(_ json: [String: Any]) -> ParsedPost? {
        guard let id = JSONValue.string(json["id_str"]) ?? JSONValue.string(json["id"]) else { return nil }
        let user = JSONValue.object(json["user"])
        let author = user.map { u in
            SnipAuthor(
                name: JSONValue.string(u["name"]) ?? "",
                handle: JSONValue.string(u["screen_name"]) ?? "",
                avatarURL: JSONValue.string(u["profile_image_url_https"]).map(PostMedia.largerAvatar),
                verified: JSONValue.bool(u["is_blue_verified"]) == true || JSONValue.bool(u["verified"]) == true
            )
        }

        let urls = JSONValue.array(JSONValue.value(json, "entities.urls")).compactMap { item -> (String, String)? in
            guard let short = JSONValue.string(JSONValue.value(item, "url")),
                  let expanded = JSONValue.string(JSONValue.value(item, "expanded_url")) else { return nil }
            return (short, expanded)
        }
        let mediaDetails = JSONValue.array(json["mediaDetails"])
        let mediaURLs = (JSONValue.array(JSONValue.value(json, "entities.media")) + mediaDetails)
            .compactMap { JSONValue.string(JSONValue.value($0, "url")) }

        let range = JSONValue.array(json["display_text_range"]).compactMap { JSONValue.int($0) }
        let text = PostText.clean(
            JSONValue.string(json["text"]) ?? JSONValue.string(json["full_text"]) ?? "",
            displayRange: range.count == 2 ? range : nil,
            urls: urls.map { (short: $0.0, expanded: $0.1) },
            mediaURLs: mediaURLs
        )

        let media = mediaDetails.compactMap { PostMedia.fromLegacy(JSONValue.object($0)) }
        let handle = author?.handle
        return ParsedPost(
            id: id,
            reference: TweetReference(id: id, handle: handle?.isEmpty == false ? handle : nil),
            text: text,
            author: author,
            createdAt: JSONValue.string(json["created_at"]).flatMap(DateParsing.parse),
            media: media
        )
    }

    /// Link preview cards: `card.binding_values` holds title, description and image.
    static func card(_ any: Any?) -> LinkInfo? {
        guard let card = JSONValue.object(any) else { return nil }
        var values: [String: Any] = [:]
        if let dict = JSONValue.object(card["binding_values"]) {
            values = dict
        } else {
            for entry in JSONValue.array(JSONValue.value(card, "legacy.binding_values")) {
                if let key = JSONValue.string(JSONValue.value(entry, "key")) {
                    values[key] = JSONValue.value(entry, "value")
                }
            }
        }
        func string(_ key: String) -> String? {
            JSONValue.string(JSONValue.value(values[key], "string_value"))
        }
        func image(_ key: String) -> String? {
            JSONValue.string(JSONValue.value(values[key], "image_value.url"))
        }
        let info = LinkInfo(
            url: string("card_url") ?? JSONValue.string(card["url"]),
            title: string("title"),
            summary: string("description"),
            siteName: string("vanity_url") ?? string("domain"),
            imageURL: image("thumbnail_image_large") ?? image("summary_photo_image_large") ?? image("photo_image_full_size_large") ?? image("thumbnail_image")
        )
        return info.isEmpty ? nil : info
    }
}

public enum PostMedia {
    /// Media objects in X's legacy shape (`extended_entities.media`, `mediaDetails`).
    static func fromLegacy(_ m: [String: Any]?) -> SnipMedia? {
        guard let m, let url = JSONValue.string(m["media_url_https"]) ?? JSONValue.string(m["media_url"]) else { return nil }
        let type = JSONValue.string(m["type"]) ?? "photo"
        let kind: SnipMedia.Kind = type == "photo" ? .image : (type == "animated_gif" ? .gif : .video)
        return SnipMedia(
            kind: kind,
            remoteURL: url,
            videoURL: bestVideoVariant(JSONValue.array(JSONValue.value(m, "video_info.variants"))),
            width: JSONValue.int(JSONValue.value(m, "original_info.width")),
            height: JSONValue.int(JSONValue.value(m, "original_info.height")),
            alt: JSONValue.string(m["ext_alt_text"])
        )
    }

    static func bestVideoVariant(_ variants: [Any]) -> String? {
        let mp4 = variants.compactMap { v -> (Int, String)? in
            guard JSONValue.string(JSONValue.value(v, "content_type")) == "video/mp4",
                  let url = JSONValue.string(JSONValue.value(v, "url")) else { return nil }
            return (JSONValue.int(JSONValue.value(v, "bitrate")) ?? 0, url)
        }
        return mp4.max { $0.0 < $1.0 }?.1
    }

    /// X serves 48px avatars by default ("_normal"); the 200px variant looks sharp on Retina.
    public static func largerAvatar(_ url: String) -> String {
        url.replacingOccurrences(of: "_normal.", with: "_200x200.")
    }

    /// A reasonably sized variant of an X image URL for downloading.
    public static func downloadURL(for url: String) -> String {
        guard url.contains("pbs.twimg.com/"), !url.contains("name=") else { return url }
        return url + (url.contains("?") ? "&" : "?") + "name=medium"
    }
}

/// Parses `publish.twitter.com/oembed` responses, a fallback when the embed JSON is unavailable.
public enum OEmbedParser {
    public static func snip(from data: Data, reference: TweetReference, source: String? = nil, now: Date = Date()) throws -> Snip {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PostParseError.invalidJSON
        }
        guard let html = JSONValue.string(root["html"]) else { throw PostParseError.unavailable("no embed markup") }

        let paragraph = HTMLText.matches(html, #"<p[^>]*>([\s\S]*?)</p>"#).first?[1] ?? ""
        // Drop the trailing "pic.twitter.com/…" link that stands in for attached media.
        let withoutPicLinks = HTMLText.replace(paragraph, #"<a[^>]*>\s*pic\.(twitter|x)\.com/[^<]*</a>"#, "")
        let text = HTMLText.plainText(fromHTML: withoutPicLinks)

        let authorName = JSONValue.string(root["author_name"]) ?? ""
        let authorURL = JSONValue.string(root["author_url"]) ?? ""
        let handle = authorURL.split(separator: "/").last.map(String.init) ?? reference.handle ?? ""
        let date = HTMLText.matches(html, #"<a[^>]*>([^<]+)</a>\s*</blockquote>"#).last?[1].flatMap(DateParsing.parse)

        let resolved = TweetReference(id: reference.id, handle: handle.isEmpty ? reference.handle : handle)
        return Snip(
            kind: .tweet,
            body: text,
            url: resolved.canonicalURL,
            author: SnipAuthor(name: authorName, handle: handle),
            createdAt: date ?? now,
            savedAt: now,
            source: source,
            externalID: resolved.externalID,
            tweet: TweetInfo(tweetID: reference.id)
        )
    }
}
