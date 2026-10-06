import Foundation
import XCTest
@testable import SnipperCore

final class SearchTests: XCTestCase {
    func testQueryParserOperators() {
        let q = QueryParser.parse(#"from:@Vercel tag:#Design type:posts is:fav "liquid glass" refraction"#)
        XCTAssertEqual(q.authors, ["vercel"])
        XCTAssertEqual(q.tags, ["design"])
        XCTAssertEqual(q.kinds, [.tweet])
        XCTAssertTrue(q.favoritesOnly)
        XCTAssertEqual(q.phrases, ["liquid glass"])
        XCTAssertEqual(q.text, "liquid glass refraction")
        XCTAssertEqual(q.terms, ["liquid", "glass", "refraction"])
        XCTAssertTrue(q.hasFilters)
    }

    func testQueryParserPlainText() {
        let q = QueryParser.parse("  Café   déjà-vu  ")
        XCTAssertEqual(q.text, "Café déjà-vu")
        XCTAssertEqual(q.terms, ["cafe", "deja", "vu"])
        XCTAssertFalse(q.hasFilters)
        XCTAssertTrue(QueryParser.parse("   ").isEmpty)
        XCTAssertTrue(QueryParser.parse("type:unknown").kinds.isEmpty)
    }

    func testTextNormalizerWords() {
        XCTAssertEqual(TextNormalizer.words(in: "@Jony #Design, Ive's"), ["jony", "design", "ive", "s"])
    }

    private func candidates() -> [Snip] {
        [
            Snip(kind: .tweet, body: "Thoughts on refraction in UI materials", author: SnipAuthor(name: "Glass Lab", handle: "glasslab"), tags: ["design"], savedAt: Date(timeIntervalSince1970: 3)),
            Snip(kind: .note, title: "Grocery list", body: "eggs, milk, refraction lens cleaner", savedAt: Date(timeIntervalSince1970: 2)),
            Snip(kind: .screenshot, title: "Revenue chart", isFavorite: true, savedAt: Date(timeIntervalSince1970: 1), ocrText: "Q3 revenue grew 20%"),
        ]
    }

    func testKeywordOnlyRanking() {
        let snips = candidates()
        let c = snips.map(SearchCandidate.init)
        let hits = HybridRanker.rank(c, query: QueryParser.parse("refraction"), semantic: nil)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.id, snips[0].id, "title/author boost and recency")

        let ocr = HybridRanker.rank(c, query: QueryParser.parse("revenue"), semantic: nil)
        XCTAssertEqual(ocr.map(\.id), [snips[2].id])

        XCTAssertTrue(HybridRanker.rank(c, query: QueryParser.parse("zebra"), semantic: nil).isEmpty)
    }

    func testFiltersWithoutText() {
        let snips = candidates()
        let c = snips.map(SearchCandidate.init)
        XCTAssertEqual(HybridRanker.rank(c, query: QueryParser.parse("is:fav"), semantic: nil).map(\.id), [snips[2].id])
        XCTAssertEqual(HybridRanker.rank(c, query: QueryParser.parse("from:glasslab"), semantic: nil).map(\.id), [snips[0].id])
        XCTAssertEqual(HybridRanker.rank(c, query: QueryParser.parse("tag:design"), semantic: nil).map(\.id), [snips[0].id])
        XCTAssertEqual(HybridRanker.rank(c, query: QueryParser.parse("type:note"), semantic: nil).map(\.id), [snips[1].id])
        // Filter-only queries list everything that matches, newest first.
        XCTAssertEqual(HybridRanker.rank(c, query: QueryParser.parse("type:note type:screenshot"), semantic: nil).map(\.id), [snips[1].id, snips[2].id])
    }

    func testSemanticRankingBlendsKeywords() {
        let snips = candidates()
        let c = snips.map(SearchCandidate.init)
        let semantic: [UUID: Float] = [snips[0].id: 0.40, snips[1].id: 0.30, snips[2].id: 0.72]
        let hits = HybridRanker.rank(c, query: QueryParser.parse("money growth"), semantic: semantic)
        XCTAssertEqual(hits.map(\.id), [snips[2].id, snips[0].id, snips[1].id])
        XCTAssertEqual(hits.first?.semantic ?? 0, 0.72, accuracy: 1e-6)

        // A keyword hit lifts a weaker semantic match.
        let boosted = HybridRanker.rank(c, query: QueryParser.parse("grocery"), semantic: [snips[0].id: 0.5, snips[1].id: 0.45, snips[2].id: 0.4])
        XCTAssertEqual(boosted.first?.id, snips[1].id)

        // Snips without vectors yet still surface through keywords.
        let partial = HybridRanker.rank(c, query: QueryParser.parse("revenue"), semantic: [snips[0].id: 0.3])
        XCTAssertTrue(partial.contains { $0.id == snips[2].id && $0.keyword > 0 })
    }

    func testRelevantWindow() {
        let ids = (0..<4).map { _ in UUID() }
        let hits = [
            RankedHit(id: ids[0], score: 0.8, semantic: 0.8, keyword: 0),
            RankedHit(id: ids[1], score: 0.65, semantic: 0.65, keyword: 0),
            RankedHit(id: ids[2], score: 0.5, semantic: 0.5, keyword: 0),
            RankedHit(id: ids[3], score: 0.2, semantic: 0.1, keyword: 0.4),
        ]
        XCTAssertEqual(HybridRanker.relevant(hits).map(\.id), [ids[0], ids[1], ids[3]])
        XCTAssertTrue(HybridRanker.relevant([]).isEmpty)
    }

    func testGemmaDocumentForPostWithImage() {
        var post = Snip(
            kind: .tweet,
            body: "New icon set <|image|> is out",
            author: SnipAuthor(name: "Ada", handle: "ada"),
            media: [SnipMedia(kind: .image, localFile: "a.jpg", remoteURL: "https://pbs.twimg.com/media/a.jpg")],
            tags: ["icons"],
            tweet: TweetInfo(tweetID: "1", quoted: QuotedPost(text: "Old icons", author: SnipAuthor(name: "B", handle: "bee")))
        )
        let doc = EmbeddingDocumentBuilder.document(for: post, style: .gemma)
        XCTAssertEqual(doc.imageFiles, ["a.jpg"])
        XCTAssertEqual(doc.text, "title: Ada (@ada) | text: New icon set   is out\n\nQuoting @bee: Old icons\n\n#icons <|image|>")
        XCTAssertEqual(doc.text?.components(separatedBy: "<|image|>").count, 2, "exactly one placeholder")

        let withoutImages = EmbeddingDocumentBuilder.document(for: post, style: .gemma, includePostImages: false)
        XCTAssertTrue(withoutImages.imageFiles.isEmpty)
        XCTAssertNotEqual(withoutImages.hash, doc.hash)

        post.media[0].localFile = nil
        XCTAssertTrue(EmbeddingDocumentBuilder.document(for: post, style: .gemma).imageFiles.isEmpty, "remote-only media is skipped")
    }

    func testDocumentsForOtherKinds() {
        let shot = Snip(kind: .screenshot, title: "", media: [SnipMedia(localFile: "s.png")], ocrText: "Total 42", appName: "Figma")
        let doc = EmbeddingDocumentBuilder.document(for: shot, style: .gemma)
        XCTAssertEqual(doc.text, "title: Figma | text: Total 42 <|image|>")

        let note = Snip(kind: .note, body: "Ship it")
        XCTAssertEqual(EmbeddingDocumentBuilder.document(for: note, style: .gemma).text, "title: none | text: Ship it")
        XCTAssertEqual(EmbeddingDocumentBuilder.document(for: note, style: .plain).text, "Ship it")
        XCTAssertNil(EmbeddingDocumentBuilder.document(for: Snip(kind: .note), style: .plain).text)

        let link = Snip(kind: .link, url: "https://www.example.com/x", link: LinkInfo(title: "Example | Home", summary: "A page"))
        XCTAssertEqual(EmbeddingDocumentBuilder.document(for: link, style: .gemma).text, "title: Example / Home | text: A page\n\nexample.com")

        let long = Snip(kind: .note, body: String(repeating: "a", count: 10_000))
        XCTAssertLessThanOrEqual(EmbeddingDocumentBuilder.document(for: long, style: .plain, maxCharacters: 100).text?.count ?? 0, 100)
    }

    func testQueryPrompt() {
        XCTAssertEqual(EmbeddingPrompts.query("red planet", style: .gemma), "task: search result | query: red planet")
        XCTAssertEqual(EmbeddingPrompts.query(" red <|image|> ", style: .plain), "red")
    }
}
