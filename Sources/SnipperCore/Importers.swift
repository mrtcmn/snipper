import Foundation

public struct ImportOutcome: Sendable {
    public var snips: [Snip]
    public var skipped: Int
    public var warnings: [String]

    public init(snips: [Snip] = [], skipped: Int = 0, warnings: [String] = []) {
        self.snips = snips
        self.skipped = skipped
        self.warnings = warnings
    }

    mutating func merge(_ other: ImportOutcome) {
        snips += other.snips
        skipped += other.skipped
        warnings += other.warnings
    }
}

public enum ImportError: Error, Equatable, CustomStringConvertible {
    case unrecognizedFormat
    case unreadable(String)

    public var description: String {
        switch self {
        case .unrecognizedFormat: "This file doesn't look like a supported export."
        case .unreadable(let name): "Couldn't read \(name)."
        }
    }
}

// MARK: - Generic post objects

/// Maps loosely structured post objects (from JSON or CSV exports by various tools) to snips.
public enum PostObjectMapper {
    private static let idKeys = ["id_str", "rest_id", "tweet_id", "tweetid", "tweetId", "post_id", "status_id", "id"]
    private static let urlKeys = ["url", "tweet_url", "tweeturl", "tweetUrl", "post_url", "link", "permalink", "expandedUrl", "expanded_url"]
    private static let textKeys = ["full_text", "fullText", "full text", "text", "tweet_text", "content", "body", "tweet", "note_tweet_text"]
    private static let handleKeys = ["screen_name", "username", "user_name", "handle", "author_handle", "user_handle", "userName", "screenName", "author_username", "author"]
    private static let nameKeys = ["name", "display_name", "author_name", "displayName", "user_display_name", "author_display_name"]
    private static let dateKeys = ["created_at", "createdAt", "date", "timestamp", "tweeted_at", "time", "datetime", "posted_at"]

    public static func snip(from object: [String: Any], source: String, now: Date = Date()) -> Snip? {
        let lookup = CaseInsensitive(object)
        let urlString = lookup.string(urlKeys)
        let reference = urlString.flatMap(TweetURL.parse)
        var id = reference?.id
        if id == nil, let raw = lookup.string(idKeys), raw.allSatisfy(\.isASCIIDigit), raw.count >= 5 { id = raw }

        let nested = (lookup.any(["user", "author", "core.user_results.result", "user_results.result"]) as? [String: Any])
            .map(CaseInsensitive.init)
        let nestedLegacy = (nested?.any(["legacy", "core"]) as? [String: Any]).map(CaseInsensitive.init)
        let handle = nested?.string(handleKeys) ?? nestedLegacy?.string(handleKeys)
            ?? lookup.string(handleKeys.filter { $0 != "author" }) ?? reference?.handle
        let name = nested?.string(nameKeys) ?? nestedLegacy?.string(nameKeys) ?? lookup.string(nameKeys.filter { $0 != "name" || handle != nil })
        let avatar = nested?.string(["profile_image_url_https", "avatar", "avatar_url", "profile_image_url", "image"])
            ?? lookup.string(["avatar", "avatar_url", "profile_image_url_https", "profile_image_url"])

        let text = lookup.string(textKeys).map { PostText.clean($0) } ?? ""
        let created = lookup.any(dateKeys).flatMap(date)
        let media = mediaList(lookup.any(["media", "images", "photos", "mediaDetails", "extended_entities.media", "media_urls"]))

        if let id {
            let ref = TweetReference(id: id, handle: handle ?? reference?.handle)
            let author = handle.map { SnipAuthor(name: name ?? $0, handle: $0, avatarURL: avatar.map(PostMedia.largerAvatar)) }
            guard !text.isEmpty || !media.isEmpty || author != nil else { return nil }
            return Snip(
                kind: .tweet,
                body: text,
                url: ref.canonicalURL,
                author: author,
                media: media,
                createdAt: created ?? now,
                savedAt: now,
                source: source,
                externalID: ref.externalID,
                tweet: TweetInfo(
                    tweetID: id,
                    likes: lookup.int(["favorite_count", "likes", "like_count", "likeCount", "favorites"]),
                    reposts: lookup.int(["retweet_count", "retweets", "retweetCount", "reposts"]),
                    replies: lookup.int(["reply_count", "replies", "replyCount"]),
                    views: lookup.int(["views", "view_count", "viewCount", "impressions"])
                )
            )
        }

        if let urlString, URL(string: urlString)?.scheme?.hasPrefix("http") == true {
            let title = lookup.string(["title", "name"]) ?? ""
            return Snip(
                kind: .link,
                title: title,
                body: text,
                url: urlString,
                createdAt: created ?? now,
                savedAt: now,
                source: source,
                externalID: "url:\(URLNormalizer.normalize(urlString))",
                link: LinkInfo(url: urlString, title: title.isEmpty ? nil : title)
            )
        }

        guard !text.isEmpty else { return nil }
        return Snip(kind: .note, title: lookup.string(["title"]) ?? "", body: text, createdAt: created ?? now, savedAt: now, source: source)
    }

    static func date(_ any: Any) -> Date? {
        if let n = any as? NSNumber { return DateParsing.fromEpoch(n.doubleValue) }
        if let s = any as? String { return DateParsing.parse(s) }
        return nil
    }

    static func mediaList(_ any: Any?) -> [SnipMedia] {
        if let s = any as? String {
            // CSV exports often join media URLs with spaces, commas or pipes.
            return s.split { $0 == " " || $0 == "," || $0 == "|" || $0 == "\n" }
                .map(String.init)
                .filter { $0.hasPrefix("http") }
                .map { SnipMedia(kind: .image, remoteURL: $0) }
        }
        return JSONValue.array(any).compactMap { item in
            if let s = item as? String, s.hasPrefix("http") { return SnipMedia(kind: .image, remoteURL: s) }
            guard let dict = item as? [String: Any] else { return nil }
            if let legacy = PostMedia.fromLegacy(dict) { return legacy }
            let l = CaseInsensitive(dict)
            guard let url = l.string(["url", "src", "media_url", "image", "thumbnail"]), url.hasPrefix("http") else { return nil }
            let type = l.string(["type"]) ?? "photo"
            return SnipMedia(
                kind: type.contains("video") ? .video : (type.contains("gif") ? .gif : .image),
                remoteURL: url,
                videoURL: l.string(["videoUrl", "video_url"]),
                width: l.int(["width"]),
                height: l.int(["height"]),
                alt: l.string(["alt", "alt_text", "ext_alt_text"])
            )
        }
    }

    /// Case- and separator-insensitive key lookup with dotted paths.
    struct CaseInsensitive {
        let storage: [String: Any]
        let folded: [String: Any]

        init(_ dict: [String: Any]) {
            storage = dict
            var f: [String: Any] = [:]
            for (k, v) in dict { f[Self.fold(k)] = v }
            folded = f
        }

        static func fold(_ key: String) -> String {
            key.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." }
        }

        func any(_ keys: [String]) -> Any? {
            for key in keys {
                if key.contains(".") {
                    if let v = JSONValue.value(storage, key), !(v is NSNull) { return v }
                } else if let v = folded[Self.fold(key)], !(v is NSNull) {
                    return v
                }
            }
            return nil
        }

        func string(_ keys: [String]) -> String? {
            for key in keys {
                if let s = JSONValue.string(any([key]))?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
            }
            return nil
        }

        func int(_ keys: [String]) -> Int? {
            for key in keys { if let v = JSONValue.int(any([key])) { return v } }
            return nil
        }
    }
}

// MARK: - JSON and CSV files

public enum GenericImporter {
    public static func importJSON(_ data: Data, source: String = "import:json", now: Date = Date()) throws -> ImportOutcome {
        // Snipper's own export round-trips losslessly.
        if let snips = try? SnipCoding.exportDecoder().decode([Snip].self, from: data), !snips.isEmpty,
           snips.allSatisfy({ !$0.body.isEmpty || !$0.title.isEmpty || !$0.media.isEmpty || $0.url != nil }) {
            return ImportOutcome(snips: snips)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw ImportError.unrecognizedFormat }

        let objects: [[String: Any]]
        if let array = root as? [Any] {
            objects = array.compactMap { $0 as? [String: Any] }
        } else if let dict = root as? [String: Any] {
            let keys = ["bookmarks", "tweets", "posts", "data", "items", "results", "likes"]
            let found = keys.lazy.compactMap { dict[$0] as? [Any] }.first
            objects = (found ?? [dict]).compactMap { $0 as? [String: Any] }
        } else {
            throw ImportError.unrecognizedFormat
        }

        var outcome = ImportOutcome()
        for object in objects {
            // Wrappers such as {"tweet": {...}} or {"like": {...}}.
            let inner = (object.count == 1 ? object.values.first as? [String: Any] : nil) ?? object
            if let snip = PostObjectMapper.snip(from: inner, source: source, now: now) {
                outcome.snips.append(snip)
            } else {
                outcome.skipped += 1
            }
        }
        if outcome.snips.isEmpty && objects.isEmpty { throw ImportError.unrecognizedFormat }
        return outcome
    }

    public static func importCSV(_ text: String, source: String = "import:csv", now: Date = Date()) -> ImportOutcome {
        var outcome = ImportOutcome()
        for record in CSV.records(text) {
            if let snip = PostObjectMapper.snip(from: record, source: source, now: now) {
                outcome.snips.append(snip)
            } else {
                outcome.skipped += 1
            }
        }
        return outcome
    }

    /// Netscape bookmark files, as exported by Chrome, Safari, Firefox and Arc.
    /// Folder names become tags.
    public static func importBookmarksHTML(_ html: String, source: String = "import:bookmarks", now: Date = Date()) -> ImportOutcome {
        var outcome = ImportOutcome()
        var folders: [String] = []
        var pendingFolder: String?

        let pattern = #"<DL>|</DL>|<H3[^>]*>([\s\S]*?)</H3>|<A\s([^>]*)>([\s\S]*?)</A>"#
        for m in HTMLText.matches(html, pattern) {
            guard let whole = m[0] else { continue }
            let upper = whole.prefix(4).uppercased()
            if upper.hasPrefix("<DL>") {
                folders.append(pendingFolder ?? "")
                pendingFolder = nil
            } else if upper.hasPrefix("</DL") {
                _ = folders.popLast()
            } else if upper.hasPrefix("<H3") {
                pendingFolder = m[1].map { HTMLText.plainText(fromHTML: $0) }
            } else if let attrs = m[2].map(HTMLText.attributes(ofTag:)), let href = attrs["href"], href.hasPrefix("http") {
                let title = m[3].map { HTMLText.plainText(fromHTML: $0) } ?? ""
                let added = attrs["add_date"].flatMap(Double.init).flatMap(DateParsing.fromEpoch)
                var tags = (attrs["tags"] ?? "").split(separator: ",").map { TagNormalizer.normalize(String($0)) }
                if let folder = folders.last(where: { !$0.isEmpty }), !Self.genericFolders.contains(folder.lowercased()) {
                    tags.append(TagNormalizer.normalize(folder))
                }
                outcome.snips.append(Snip(
                    kind: .link,
                    title: title,
                    url: href,
                    tags: Array(Set(tags.filter { !$0.isEmpty })).sorted(),
                    createdAt: added ?? now,
                    savedAt: now,
                    source: source,
                    externalID: "url:\(URLNormalizer.normalize(href))",
                    link: LinkInfo(url: href, title: title.isEmpty ? nil : title, faviconURL: attrs["icon_uri"])
                ))
            }
        }
        return outcome
    }

    private static let genericFolders: Set<String> = ["bookmarks", "bookmarks bar", "bookmarks menu", "favorites", "favourites", "other bookmarks", "mobile bookmarks"]
}

// MARK: - X archive

/// Reads the "Download an archive of your data" export from X.
///
/// The archive contains likes (`like.js`), your own posts (`tweets.js`) and, in newer
/// archives, bookmarks. Each file is `window.YTD.<name>.part0 = [ ... ]`.
public enum XArchiveImporter {
    public static func parseYTD(_ data: Data) throws -> [[String: Any]] {
        guard var text = String(data: data, encoding: .utf8) else { throw ImportError.unreadable("archive file") }
        if let eq = text.firstIndex(of: "="), text.hasPrefix("window.") {
            text = String(text[text.index(after: eq)...])
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] else {
            throw ImportError.unrecognizedFormat
        }
        return json.compactMap { $0 as? [String: Any] }
    }

    /// Imports from an unzipped archive folder (the one containing `data/`).
    public static func importFolder(_ folder: URL, now: Date = Date()) throws -> ImportOutcome {
        let fm = FileManager.default
        let dataDir = fm.fileExists(atPath: folder.appendingPathComponent("data").path) ? folder.appendingPathComponent("data") : folder
        let files = (try? fm.contentsOfDirectory(atPath: dataDir.path)) ?? []
        guard files.contains(where: { $0.hasSuffix(".js") }) else { throw ImportError.unrecognizedFormat }

        var account: SnipAuthor?
        if let data = fm.contents(atPath: dataDir.appendingPathComponent("account.js").path),
           let entry = try? parseYTD(data).first,
           let acc = entry["account"] as? [String: Any] {
            let handle = JSONValue.string(acc["username"]) ?? ""
            account = SnipAuthor(name: JSONValue.string(acc["accountDisplayName"]) ?? handle, handle: handle)
        }

        var outcome = ImportOutcome()
        for file in files.sorted() where file.hasSuffix(".js") {
            let base = file.replacingOccurrences(of: ".js", with: "")
            // "tweets-part1.js" continues "tweets.js"; "tweet-headers.js" is a different file.
            let name = base.split(separator: "-").first.map(String.init) ?? base
            guard base == name || base.hasPrefix(name + "-part"),
                  ["like", "bookmark", "bookmarks", "tweets", "tweet"].contains(name)
            else { continue }
            guard let data = fm.contents(atPath: dataDir.appendingPathComponent(file).path) else {
                outcome.warnings.append("Couldn't read \(file)")
                continue
            }
            let entries = try parseYTD(data)
            switch name {
            case "like":
                outcome.merge(likes(entries, now: now))
            case "bookmark", "bookmarks":
                outcome.merge(bookmarks(entries, now: now))
            default:
                outcome.merge(ownPosts(entries, account: account, now: now))
            }
        }
        return outcome
    }

    /// Imports a single archive file (`like.js`, `bookmarks.js`, `tweets.js`, …), using
    /// `account.js` next to it, when present, as the author of your own posts.
    public static func importFile(_ file: URL, now: Date = Date()) throws -> ImportOutcome {
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw ImportError.unreadable(file.lastPathComponent)
        }
        let entries = try parseYTD(data)
        let name = file.deletingPathExtension().lastPathComponent.split(separator: "-").first.map(String.init) ?? ""
        switch name {
        case "like":
            return likes(entries, now: now)
        case "bookmark", "bookmarks":
            return bookmarks(entries, now: now)
        case "tweets", "tweet":
            var account: SnipAuthor?
            let accountFile = file.deletingLastPathComponent().appendingPathComponent("account.js")
            if let accountData = FileManager.default.contents(atPath: accountFile.path),
               let acc = (try? parseYTD(accountData))?.first?["account"] as? [String: Any] {
                let handle = JSONValue.string(acc["username"]) ?? ""
                account = SnipAuthor(name: JSONValue.string(acc["accountDisplayName"]) ?? handle, handle: handle)
            }
            return ownPosts(entries, account: account, now: now)
        default:
            // Unknown files: try them as generic post objects.
            var outcome = ImportOutcome()
            for entry in entries {
                let inner = (entry.count == 1 ? entry.values.first as? [String: Any] : nil) ?? entry
                if let snip = PostObjectMapper.snip(from: inner, source: "import:x-archive", now: now) {
                    outcome.snips.append(snip)
                } else {
                    outcome.skipped += 1
                }
            }
            return outcome
        }
    }

    static func likes(_ entries: [[String: Any]], now: Date) -> ImportOutcome {
        var outcome = ImportOutcome()
        for entry in entries {
            guard let like = entry["like"] as? [String: Any], let id = JSONValue.string(like["tweetId"]) else {
                outcome.skipped += 1
                continue
            }
            let text = JSONValue.string(like["fullText"]).map { PostText.clean($0) } ?? ""
            let ref = TweetURL.parse(JSONValue.string(like["expandedUrl"]) ?? "") ?? TweetReference(id: id)
            outcome.snips.append(Snip(
                kind: .tweet,
                body: text,
                url: ref.canonicalURL,
                tags: ["liked"],
                createdAt: now,
                savedAt: now,
                source: "import:x-likes",
                externalID: ref.externalID,
                tweet: TweetInfo(tweetID: id)
            ))
        }
        return outcome
    }

    static func bookmarks(_ entries: [[String: Any]], now: Date) -> ImportOutcome {
        var outcome = ImportOutcome()
        for entry in entries {
            let inner = (entry["bookmark"] as? [String: Any]) ?? entry
            if let snip = PostObjectMapper.snip(from: inner, source: "import:x-bookmarks", now: now) {
                outcome.snips.append(snip)
            } else {
                outcome.skipped += 1
            }
        }
        return outcome
    }

    static func ownPosts(_ entries: [[String: Any]], account: SnipAuthor?, now: Date) -> ImportOutcome {
        var outcome = ImportOutcome()
        for entry in entries {
            guard let tweet = (entry["tweet"] as? [String: Any]) ?? (entry["id_str"] != nil ? entry : nil),
                  let id = JSONValue.string(tweet["id_str"]) ?? JSONValue.string(tweet["id"])
            else {
                outcome.skipped += 1
                continue
            }
            let urls = JSONValue.array(JSONValue.value(tweet, "entities.urls")).compactMap { item -> (short: String, expanded: String)? in
                guard let s = JSONValue.string(JSONValue.value(item, "url")), let e = JSONValue.string(JSONValue.value(item, "expanded_url")) else { return nil }
                return (s, e)
            }
            let legacyMedia = JSONValue.array(JSONValue.value(tweet, "extended_entities.media"))
            let mediaURLs = legacyMedia.compactMap { JSONValue.string(JSONValue.value($0, "url")) }
            let range = JSONValue.array(tweet["display_text_range"]).compactMap { JSONValue.int($0) }
            let text = PostText.clean(
                JSONValue.string(tweet["full_text"]) ?? "",
                displayRange: range.count == 2 ? range : nil,
                urls: urls,
                mediaURLs: mediaURLs
            )
            let ref = TweetReference(id: id, handle: account?.handle)
            outcome.snips.append(Snip(
                kind: .tweet,
                body: text,
                url: ref.canonicalURL,
                author: account,
                media: legacyMedia.compactMap { PostMedia.fromLegacy($0 as? [String: Any]) },
                tags: ["my-posts"],
                createdAt: JSONValue.string(tweet["created_at"]).flatMap(DateParsing.parse) ?? now,
                savedAt: now,
                source: "import:x-archive",
                externalID: ref.externalID,
                tweet: TweetInfo(
                    tweetID: id,
                    likes: JSONValue.int(tweet["favorite_count"]),
                    reposts: JSONValue.int(tweet["retweet_count"])
                )
            ))
        }
        return outcome
    }
}
