import Foundation
import XCTest
@testable import SnipperCore

final class PostParsingTests: XCTestCase {
    func testTweetURLParsing() {
        XCTAssertEqual(TweetURL.parse("https://x.com/jack/status/20"), TweetReference(id: "20", handle: "jack"))
        XCTAssertEqual(TweetURL.parse("https://twitter.com/jack/status/20?s=20&t=abc"), TweetReference(id: "20", handle: "jack"))
        XCTAssertEqual(TweetURL.parse("mobile.twitter.com/jack/statuses/20/photo/1"), TweetReference(id: "20", handle: "jack"))
        XCTAssertEqual(TweetURL.parse("https://x.com/i/web/status/1790000000000000000"), TweetReference(id: "1790000000000000000"))
        XCTAssertEqual(TweetURL.parse("https://www.fxtwitter.com/a_b/status/123"), TweetReference(id: "123", handle: "a_b"))
        XCTAssertNil(TweetURL.parse("https://x.com/jack"))
        XCTAssertNil(TweetURL.parse("https://example.com/jack/status/20"))
        XCTAssertNil(TweetURL.parse("https://x.com/jack/status/abc"))
        XCTAssertEqual(TweetReference(id: "20").canonicalURL, "https://x.com/i/web/status/20")
        XCTAssertEqual(TweetReference(id: "20").externalID, "x:20")
    }

    func testRadixStringMatchesV8() {
        // Expected values printed by Node.js (V8).
        XCTAssertEqual(SyndicationToken.radixString(0.5, radix: 36), "0.i")
        XCTAssertEqual(SyndicationToken.radixString(0.1, radix: 36), "0.3lllllllllm")
        XCTAssertEqual(SyndicationToken.radixString(1.0 / 3.0, radix: 36), "0.c")
        XCTAssertEqual(SyndicationToken.radixString(123.456, radix: 36), "3f.gez4w97ry")
        XCTAssertEqual(SyndicationToken.radixString(123.456, radix: 16), "7b.74bc6a7ef9dc")
        XCTAssertEqual(SyndicationToken.radixString(255.5, radix: 16), "ff.8")
        XCTAssertEqual(SyndicationToken.radixString(0.1, radix: 2), "0.0001100110011001100110011001100110011001100110011001101")
        XCTAssertEqual(SyndicationToken.radixString(1e21, radix: 36), "5v1j4f4ds7c000")
        XCTAssertEqual(SyndicationToken.radixString(9_007_199_254_740_994, radix: 36), "2gosa7pa2gy")
        XCTAssertEqual(SyndicationToken.radixString(0.000001, radix: 36), "0.0001ogs5wo29m8")
        XCTAssertEqual(SyndicationToken.radixString(35.99999999999999, radix: 36), "z.zzzzzzzzz")
        XCTAssertEqual(SyndicationToken.radixString(1295.9999999999998, radix: 36), "zz.zzzzzzzzd")
        XCTAssertEqual(SyndicationToken.radixString(-255.5, radix: 16), "-ff.8")
    }

    func testSyndicationTokens() {
        let expected: [(String, String)] = [
            ("20", "6dq1a2xwd93"),
            ("1", "bhi2ay3f28n"),
            ("1790000000000000000", "4c7g8auqyik"),
            ("1629307668568633344", "3y6mctgwzxo"),
            ("1683920951807971329", "42y6zv7ufp"),
            ("1458498745632681985", "3jablbephl"),
            ("1845151337846214663", "4hpp759o8r"),
            ("1234567890", "6iio5bzbwyw"),
            ("1500000000000000000", "3mwe49oefy"),
        ]
        for (id, token) in expected {
            XCTAssertEqual(SyndicationToken.token(for: id), token, "token for \(id)")
        }
    }

    func testPostTextCleaning() {
        let raw = "@bob @carol Look 👀 at this &amp; that https://t.co/abc https://t.co/media"
        // Indices are code points of the unescaped text: the emoji and "&" count once.
        let start = Array("@bob @carol ".unicodeScalars).count
        let end = Array("@bob @carol Look 👀 at this & that https://t.co/abc".unicodeScalars).count
        let cleaned = PostText.clean(
            raw,
            displayRange: [start, end],
            urls: [(short: "https://t.co/abc", expanded: "https://example.com/article")],
            mediaURLs: ["https://t.co/media"]
        )
        XCTAssertEqual(cleaned, "Look 👀 at this & that https://example.com/article")
        XCTAssertEqual(PostText.clean("a&lt;b&gt;c &#39;q&#39; &#x1F600;"), "a<b>c 'q' 😀")
        XCTAssertEqual(PostText.clean("short", displayRange: [0, 99]), "short")
    }

    func testSyndicationParsing() throws {
        let json = """
        {
          "__typename": "Tweet",
          "lang": "en",
          "favorite_count": 1234,
          "conversation_count": 56,
          "created_at": "2024-05-01T10:20:30.000Z",
          "display_text_range": [0, 43],
          "entities": {
            "urls": [{"url": "https://t.co/link", "expanded_url": "https://glass.dev/post"}],
            "media": [{"url": "https://t.co/pic"}]
          },
          "id_str": "1785000000000000000",
          "text": "Glass needs light to bend https://t.co/link https://t.co/pic",
          "user": {"name": "Glass Lab", "screen_name": "glasslab", "profile_image_url_https": "https://pbs.twimg.com/profile_images/1/a_normal.jpg", "is_blue_verified": true},
          "mediaDetails": [
            {"type": "photo", "media_url_https": "https://pbs.twimg.com/media/A.jpg", "original_info": {"width": 1600, "height": 900}, "url": "https://t.co/pic", "ext_alt_text": "A prism"},
            {"type": "video", "media_url_https": "https://pbs.twimg.com/thumb/B.jpg", "url": "https://t.co/pic",
             "video_info": {"variants": [
                {"content_type": "application/x-mpegURL", "url": "https://video/x.m3u8"},
                {"content_type": "video/mp4", "bitrate": 256000, "url": "https://video/low.mp4"},
                {"content_type": "video/mp4", "bitrate": 2176000, "url": "https://video/high.mp4"}
             ]}}
          ],
          "quoted_tweet": {
            "id_str": "1700000000000000000",
            "text": "Original thought",
            "user": {"name": "Q", "screen_name": "quoter"},
            "created_at": "2023-09-01T00:00:00.000Z"
          }
        }
        """
        let snip = try SyndicationParser.snip(from: Data(json.utf8), source: "browser", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(snip.kind, .tweet)
        XCTAssertEqual(snip.body, "Glass needs light to bend https://glass.dev/post")
        XCTAssertEqual(snip.author?.handle, "glasslab")
        XCTAssertEqual(snip.author?.verified, true)
        XCTAssertEqual(snip.author?.avatarURL, "https://pbs.twimg.com/profile_images/1/a_200x200.jpg")
        XCTAssertEqual(snip.url, "https://x.com/glasslab/status/1785000000000000000")
        XCTAssertEqual(snip.externalID, "x:1785000000000000000")
        XCTAssertEqual(snip.media.count, 2)
        XCTAssertEqual(snip.media[0].alt, "A prism")
        XCTAssertEqual(snip.media[0].width, 1600)
        XCTAssertEqual(snip.media[1].kind, .video)
        XCTAssertEqual(snip.media[1].videoURL, "https://video/high.mp4")
        XCTAssertEqual(snip.tweet?.likes, 1234)
        XCTAssertEqual(snip.tweet?.replies, 56)
        XCTAssertEqual(snip.tweet?.quoted?.text, "Original thought")
        XCTAssertEqual(snip.tweet?.quoted?.author?.handle, "quoter")
        XCTAssertEqual(snip.createdAt, DateParsing.parse("2024-05-01T10:20:30.000Z"))
        XCTAssertEqual(snip.source, "browser")
    }

    func testSyndicationErrors() {
        XCTAssertThrowsError(try SyndicationParser.snip(from: Data("nope".utf8))) { error in
            XCTAssertEqual(error as? PostParseError, .invalidJSON)
        }
        XCTAssertThrowsError(try SyndicationParser.snip(from: Data(#"{"__typename":"TweetTombstone"}"#.utf8)))
        XCTAssertThrowsError(try SyndicationParser.snip(from: Data("{}".utf8)))
    }

    func testOEmbedParsing() throws {
        let json = #"""
        {"url":"https://twitter.com/glasslab/status/42","author_name":"Glass Lab","author_url":"https://twitter.com/glasslab",
         "html":"<blockquote class=\"twitter-tweet\"><p lang=\"en\" dir=\"ltr\">Light &amp; shadow<br>second line <a href=\"https://t.co/x\">pic.twitter.com/x</a></p>&mdash; Glass Lab (@glasslab) <a href=\"https://twitter.com/glasslab/status/42?ref_src=twsrc%5Etfw\">March 1, 2024</a></blockquote>\n"}
        """#
        let snip = try OEmbedParser.snip(from: Data(json.utf8), reference: TweetReference(id: "42"))
        XCTAssertEqual(snip.body, "Light & shadow\nsecond line")
        XCTAssertEqual(snip.author?.name, "Glass Lab")
        XCTAssertEqual(snip.author?.handle, "glasslab")
        XCTAssertEqual(snip.url, "https://x.com/glasslab/status/42")
        XCTAssertEqual(snip.createdAt, DateParsing.parse("2024-03-01"))
    }

    func testHTMLHelpers() {
        XCTAssertEqual(HTMLText.decodeEntities("&amp;&lt;&gt;&quot;&#39;&hellip; & alone &unknown;"), "&<>\"'… & alone &unknown;")
        XCTAssertEqual(HTMLText.plainText(fromHTML: "<p>One<br/>Two</p><script>bad()</script><p>Three&nbsp;!</p>"), "One\nTwo\nThree !")
    }

    func testLinkMetadata() {
        let html = """
        <html><head>
        <title>Fallback &amp; Title</title>
        <meta property="og:title" content="Glass &amp; Light">
        <meta content='A deep dive' name='description'>
        <meta property="og:image" content="/img/cover.png">
        <meta property="og:site_name" content="Glass Blog">
        <link rel="icon" href="/favicon-32.png"><link rel="apple-touch-icon" href="https://cdn.example.com/touch.png">
        </head><body><meta property="og:title" content="ignored"></body></html>
        """
        let result = LinkMetadataParser.parse(html: html, pageURL: URL(string: "https://example.com/posts/1")!)
        XCTAssertEqual(result.title, "Glass & Light")
        XCTAssertEqual(result.info.summary, "A deep dive")
        XCTAssertEqual(result.info.imageURL, "https://example.com/img/cover.png")
        XCTAssertEqual(result.info.siteName, "Glass Blog")
        XCTAssertEqual(result.info.faviconURL, "https://cdn.example.com/touch.png")

        let bare = LinkMetadataParser.parse(html: "<title>Only</title>", pageURL: URL(string: "https://a.dev/x")!)
        XCTAssertEqual(bare.title, "Only")
        XCTAssertEqual(bare.info.faviconURL, "https://a.dev/favicon.ico")
    }
}
