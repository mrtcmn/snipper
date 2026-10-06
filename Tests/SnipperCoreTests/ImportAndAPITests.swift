import Foundation
import XCTest
@testable import SnipperCore

final class ImportAndAPITests: XCTestCase {
    // MARK: CSV

    func testCSVParsing() {
        let text = "id,text,author\r\n1,\"Hello, \"\"world\"\"\nsecond line\",ada\n2,plain,bob\n\n"
        let rows = CSV.parse(text)
        XCTAssertEqual(rows, [["id", "text", "author"], ["1", "Hello, \"world\"\nsecond line", "ada"], ["2", "plain", "bob"]])
        XCTAssertEqual(CSV.records("a;b\n1;2").first, ["a": "1", "b": "2"])
    }

    func testCSVImportOfPosts() {
        let csv = """
        Tweet URL,Full Text,Username,Display Name,Created At,Media
        https://x.com/ada/status/123456,"Hello, CSV",ada,Ada L,2024-01-02T03:04:05Z,https://pbs.twimg.com/media/1.jpg https://pbs.twimg.com/media/2.jpg
        https://example.com/article,An article,,,,
        ,just a note,,,,
        ,,,,,
        """
        let outcome = GenericImporter.importCSV(csv, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(outcome.snips.count, 3)
        XCTAssertEqual(outcome.skipped, 1)
        let post = outcome.snips[0]
        XCTAssertEqual(post.kind, .tweet)
        XCTAssertEqual(post.externalID, "x:123456")
        XCTAssertEqual(post.author?.handle, "ada")
        XCTAssertEqual(post.author?.name, "Ada L")
        XCTAssertEqual(post.body, "Hello, CSV")
        XCTAssertEqual(post.media.count, 2)
        XCTAssertEqual(post.createdAt, DateParsing.parse("2024-01-02T03:04:05Z"))
        XCTAssertEqual(outcome.snips[1].kind, .link)
        XCTAssertEqual(outcome.snips[2].kind, .note)
    }

    // MARK: JSON

    func testGenericJSONImport() throws {
        let json = """
        {"bookmarks": [
          {"tweet": {"id_str": "777777", "full_text": "Wrapped &amp; nested", "user": {"screen_name": "neo", "name": "Neo"}, "created_at": "Wed Oct 10 20:19:24 +0000 2018", "favorite_count": 9}},
          {"id": 888888, "text": "Flat", "username": "trin", "likes": "12"},
          {"nothing": true}
        ]}
        """
        let outcome = try GenericImporter.importJSON(Data(json.utf8))
        XCTAssertEqual(outcome.snips.count, 2)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.snips[0].body, "Wrapped & nested")
        XCTAssertEqual(outcome.snips[0].author?.handle, "neo")
        XCTAssertEqual(outcome.snips[0].tweet?.likes, 9)
        XCTAssertEqual(outcome.snips[0].createdAt.timeIntervalSince1970, 1_539_202_764)
        XCTAssertEqual(outcome.snips[1].externalID, "x:888888")
        XCTAssertEqual(outcome.snips[1].author?.handle, "trin")
        XCTAssertEqual(outcome.snips[1].tweet?.likes, 12)
        XCTAssertThrowsError(try GenericImporter.importJSON(Data("not json".utf8)))
    }

    func testSnipperExportRoundTrip() throws {
        let original = [
            Snip(kind: .note, title: "T", body: "B", tags: ["x"], savedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            Snip(kind: .link, url: "https://a.dev", savedAt: Date(timeIntervalSince1970: 1_700_000_001)),
        ]
        let data = try SnipCoding.exportEncoder().encode(original)
        let outcome = try GenericImporter.importJSON(data)
        XCTAssertEqual(outcome.snips.map(\.id), original.map(\.id))
        XCTAssertEqual(outcome.snips[0].tags, ["x"])
    }

    func testNetscapeBookmarks() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
          <DT><H3>Bookmarks Bar</H3>
          <DL><p>
            <DT><A HREF="https://a.dev/" ADD_DATE="1700000000">A &amp; B</A>
            <DT><H3>Design Systems</H3>
            <DL><p>
              <DT><A HREF="https://glass.dev/x?utm_source=feed" ADD_DATE="1700000001" TAGS="ui,Glass">Glass</A>
            </DL><p>
            <DT><A HREF="javascript:void(0)">Bookmarklet</A>
          </DL><p>
        </DL><p>
        """
        let outcome = GenericImporter.importBookmarksHTML(html)
        XCTAssertEqual(outcome.snips.count, 2)
        XCTAssertEqual(outcome.snips[0].title, "A & B")
        XCTAssertEqual(outcome.snips[0].tags, [], "generic folder names are not tags")
        XCTAssertEqual(outcome.snips[0].createdAt.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(outcome.snips[1].tags, ["design-systems", "glass", "ui"])
        XCTAssertEqual(outcome.snips[1].externalID, "url:https://glass.dev/x")
    }

    func testXArchiveFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"window.YTD.account.part0 = [{"account": {"username": "me", "accountDisplayName": "Me Myself"}}]"#
            .write(to: data.appendingPathComponent("account.js"), atomically: true, encoding: .utf8)
        try #"window.YTD.like.part0 = [{"like": {"tweetId": "111", "fullText": "Liked &amp; saved", "expandedUrl": "https://twitter.com/i/web/status/111"}}, {"like": {}}]"#
            .write(to: data.appendingPathComponent("like.js"), atomically: true, encoding: .utf8)
        try #"""
        window.YTD.tweets.part0 = [{"tweet": {"id_str": "222", "full_text": "@friend My post https://t.co/l", "display_text_range": ["8", "30"],
          "entities": {"urls": [{"url": "https://t.co/l", "expanded_url": "https://me.dev"}]}, "created_at": "Wed Oct 10 20:19:24 +0000 2018", "favorite_count": "3"}}]
        """#.write(to: data.appendingPathComponent("tweets.js"), atomically: true, encoding: .utf8)
        try "window.YTD.tweet_headers.part0 = []".write(to: data.appendingPathComponent("tweet-headers.js"), atomically: true, encoding: .utf8)

        let outcome = try XArchiveImporter.importFolder(root)
        XCTAssertEqual(outcome.skipped, 1)
        let like = try XCTUnwrap(outcome.snips.first { $0.externalID == "x:111" })
        XCTAssertEqual(like.body, "Liked & saved")
        XCTAssertEqual(like.tags, ["liked"])
        let own = try XCTUnwrap(outcome.snips.first { $0.externalID == "x:222" })
        XCTAssertEqual(own.body, "My post https://me.dev")
        XCTAssertEqual(own.author?.handle, "me")
        XCTAssertEqual(own.url, "https://x.com/me/status/222")
        XCTAssertEqual(own.tweet?.likes, 3)
        XCTAssertEqual(outcome.snips.count, 2)
    }

    // MARK: Extension payloads

    func testExtensionEnvelopeDecoding() throws {
        let json = """
        {"source": "x-bookmarks", "items": [
          {"type": "tweet", "tweet": {
            "id": "1790000000000000001", "url": "https://x.com/ada/status/1790000000000000001",
            "text": "Full text of a long post", "createdAt": "2024-05-01T10:20:30.000Z", "lang": "en",
            "author": {"name": "Ada", "handle": "ada", "avatar": "https://pbs.twimg.com/p/a_normal.png", "verified": true},
            "metrics": {"likes": 5, "retweets": 2, "replies": 1, "views": 100},
            "media": [{"type": "photo", "url": "https://pbs.twimg.com/media/x.jpg", "width": 10, "height": 20}, {"type": "video", "url": "https://pbs.twimg.com/t.jpg", "videoUrl": "https://v.mp4"}],
            "quoted": {"id": "5", "text": "Quoted", "author": {"name": "Q", "handle": "q"}},
            "card": {"title": "Card", "url": "https://card.dev"}
          }},
          {"type": "selection", "text": "  picked text  ", "url": "https://blog.dev/p", "title": "Blog", "tags": ["#Read Later"]},
          {"type": "page", "url": "https://blog.dev/p?utm_source=x#top", "title": "Blog", "description": "About", "image": "https://blog.dev/og.png"},
          {"type": "screenshot", "dataUrl": "data:image/png;base64,iVBORw0KGgo=", "url": "https://blog.dev/p", "title": "Tab"},
          {"type": "image", "srcUrl": "https://cdn.dev/i.webp"},
          {"type": "hologram"}
        ]}
        """
        let envelope = try JSONDecoder().decode(ExtensionEnvelope.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_000)
        let post = try ExtensionPayload.incoming(envelope.items[0], source: envelope.source, now: now).snip
        XCTAssertEqual(post.kind, .tweet)
        XCTAssertEqual(post.externalID, "x:1790000000000000001")
        XCTAssertEqual(post.author?.avatarURL, "https://pbs.twimg.com/p/a_200x200.png")
        XCTAssertEqual(post.media.map(\.kind), [.image, .video])
        XCTAssertEqual(post.media[1].videoURL, "https://v.mp4")
        XCTAssertEqual(post.tweet?.reposts, 2)
        XCTAssertEqual(post.tweet?.views, 100)
        XCTAssertEqual(post.tweet?.quoted?.url, "https://x.com/q/status/5")
        XCTAssertEqual(post.tweet?.card?.title, "Card")
        XCTAssertEqual(post.source, "x-bookmarks")
        XCTAssertEqual(post.createdAt, DateParsing.parse("2024-05-01T10:20:30.000Z"))

        let selection = try ExtensionPayload.incoming(envelope.items[1], source: nil, now: now).snip
        XCTAssertEqual(selection.kind, .text)
        XCTAssertEqual(selection.body, "picked text")
        XCTAssertEqual(selection.tags, ["read-later"])

        let page = try ExtensionPayload.incoming(envelope.items[2], source: nil, now: now).snip
        XCTAssertEqual(page.kind, .link)
        XCTAssertEqual(page.externalID, "url:https://blog.dev/p")
        XCTAssertEqual(page.link?.imageURL, "https://blog.dev/og.png")

        let shot = try ExtensionPayload.incoming(envelope.items[3], source: nil, now: now)
        XCTAssertEqual(shot.snip.kind, .screenshot)
        XCTAssertEqual(shot.inlineImageExtension, "png")
        XCTAssertEqual(shot.inlineImage?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))

        let image = try ExtensionPayload.incoming(envelope.items[4], source: nil, now: now)
        XCTAssertEqual(image.remoteImage, "https://cdn.dev/i.webp")
        XCTAssertNil(image.inlineImage)

        XCTAssertThrowsError(try ExtensionPayload.incoming(envelope.items[5], source: nil))
    }

    func testURLAndTagNormalization() {
        XCTAssertEqual(URLNormalizer.normalize("HTTPS://Example.COM/a/?utm_medium=x&id=3#frag"), "https://example.com/a?id=3")
        XCTAssertEqual(URLNormalizer.normalize("https://example.com/"), "https://example.com/")
        XCTAssertEqual(TagNormalizer.normalize("  ##Design  Systems "), "design-systems")
    }

    // MARK: HTTP

    func testHTTPParserCompleteAndIncomplete() {
        let body = #"{"a":1}"#
        let raw = "POST /api/snips?x=1&name=a%20b HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nOrigin: chrome-extension://abc\r\n\r\n\(body)"
        let data = Data(raw.utf8)

        guard case .incomplete = HTTPRequestParser.parse(data.prefix(20), maxBodyBytes: 1_000) else { return XCTFail("expected incomplete") }
        guard case .incomplete = HTTPRequestParser.parse(data.dropLast(2), maxBodyBytes: 1_000) else { return XCTFail("expected incomplete body") }
        guard case .complete(let request) = HTTPRequestParser.parse(data, maxBodyBytes: 1_000) else { return XCTFail("expected request") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/snips")
        XCTAssertEqual(request.query, ["x": "1", "name": "a b"])
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)

        guard case .invalid(let status, _) = HTTPRequestParser.parse(data, maxBodyBytes: 3) else { return XCTFail("expected too large") }
        XCTAssertEqual(status, 413)
        let chunked = Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        guard case .invalid(let status2, _) = HTTPRequestParser.parse(chunked, maxBodyBytes: 10) else { return XCTFail("expected chunked rejection") }
        XCTAssertEqual(status2, 411)
    }

    func testHTTPResponseSerialization() {
        let response = HTTPResponse.json(["ok": true]).adding("X-Test", "1")
        let text = String(data: response.serialized(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(text.contains("X-Test: 1\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }

    func testLocalAPIAccess() {
        func request(origin: String?, client: Bool) -> HTTPRequest {
            var headers: [String: String] = [:]
            if let origin { headers["origin"] = origin }
            if client { headers["x-snipper-client"] = "extension" }
            return HTTPRequest(method: "POST", path: "/api/snips", query: [:], headers: headers, body: Data())
        }
        XCTAssertTrue(LocalAPIAccess.authorize(request(origin: "chrome-extension://abcdef", client: true)))
        XCTAssertTrue(LocalAPIAccess.authorize(request(origin: nil, client: true)))
        XCTAssertFalse(LocalAPIAccess.authorize(request(origin: "https://evil.example", client: true)))
        XCTAssertFalse(LocalAPIAccess.authorize(request(origin: "chrome-extension://abcdef", client: false)))
        XCTAssertTrue(LocalAPIAccess.corsHeaders(for: "https://evil.example").isEmpty)
        XCTAssertFalse(LocalAPIAccess.corsHeaders(for: "chrome-extension://abcdef").isEmpty)
    }

    // MARK: Merge and export

    func testMergeKeepsUserDataAndRefreshesContent() {
        let existing = Snip(
            kind: .tweet,
            title: "My title",
            body: "Short text…",
            author: SnipAuthor(name: "ada", handle: "ada"),
            media: [SnipMedia(kind: .image, localFile: "local.jpg", remoteURL: "https://pbs.twimg.com/media/A.jpg?name=small")],
            tags: ["keep"],
            isFavorite: true,
            createdAt: Date(timeIntervalSince1970: 5_000),
            savedAt: Date(timeIntervalSince1970: 5_000),
            externalID: "x:1",
            tweet: TweetInfo(tweetID: "1", likes: 1)
        )
        let incoming = Snip(
            kind: .tweet,
            body: "Short text that is now complete",
            author: SnipAuthor(name: "Ada Lovelace", handle: "ada", avatarURL: "https://a"),
            media: [
                SnipMedia(kind: .image, remoteURL: "https://pbs.twimg.com/media/A.jpg", width: 100, height: 50, alt: "alt"),
                SnipMedia(kind: .image, remoteURL: "https://pbs.twimg.com/media/B.jpg"),
            ],
            tags: ["new"],
            createdAt: Date(timeIntervalSince1970: 1_000),
            savedAt: Date(timeIntervalSince1970: 9_000),
            externalID: "x:1",
            tweet: TweetInfo(tweetID: "1", likes: 42, views: 900)
        )
        let merged = SnipMerger.merge(existing: existing, incoming: incoming, now: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(merged.id, existing.id)
        XCTAssertEqual(merged.title, "My title")
        XCTAssertEqual(merged.body, "Short text that is now complete")
        XCTAssertEqual(merged.author?.name, "Ada Lovelace")
        XCTAssertEqual(merged.author?.avatarURL, "https://a")
        XCTAssertEqual(merged.media.count, 2)
        XCTAssertEqual(merged.media[0].localFile, "local.jpg")
        XCTAssertEqual(merged.media[0].alt, "alt")
        XCTAssertEqual(merged.tags, ["keep", "new"])
        XCTAssertTrue(merged.isFavorite)
        XCTAssertEqual(merged.savedAt, existing.savedAt)
        XCTAssertEqual(merged.createdAt.timeIntervalSince1970, 1_000)
        XCTAssertEqual(merged.tweet?.likes, 42)
        XCTAssertEqual(merged.tweet?.views, 900)
        XCTAssertEqual(merged.updatedAt.timeIntervalSince1970, 10_000)

        let unchanged = SnipMerger.merge(existing: merged, incoming: merged, now: Date(timeIntervalSince1970: 20_000))
        XCTAssertEqual(unchanged.updatedAt, merged.updatedAt, "no-op merges keep updatedAt")
    }

    func testMarkdownExport() {
        let snip = Snip(
            kind: .tweet,
            body: "Line one\n\nLine \"two\"",
            url: "https://x.com/ada/status/1",
            author: SnipAuthor(name: "Ada", handle: "ada"),
            media: [SnipMedia(localFile: "a.png", alt: "Chart")],
            tags: ["design", "glass"],
            createdAt: Date(timeIntervalSince1970: 1_709_251_200),
            savedAt: Date(timeIntervalSince1970: 1_709_251_200),
            ocrText: "Revenue"
        )
        let md = MarkdownExporter.markdown(for: snip)
        XCTAssertTrue(md.hasPrefix("---\nid: \"\(snip.id.uuidString)\"\nkind: \"tweet\"\n"))
        XCTAssertTrue(md.contains("tags: [\"design\", \"glass\"]\n---"))
        XCTAssertTrue(md.contains("# Ada\n"))
        XCTAssertTrue(md.contains("> Line one\n>\n> Line \"two\"\n"))
        XCTAssertTrue(md.contains("![Chart](media/a.png)"))
        XCTAssertTrue(md.contains("Revenue"))
        XCTAssertTrue(md.contains("[Open original](https://x.com/ada/status/1)"))

        let name = MarkdownExporter.fileName(for: Snip(kind: .note, title: "a/b: c?", savedAt: Date(timeIntervalSince1970: 1_709_251_200)))
        XCTAssertTrue(name.hasPrefix("2024-03-01 a b c "))
        XCTAssertTrue(name.hasSuffix(".md"))
    }
}
