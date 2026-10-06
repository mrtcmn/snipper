import Foundation
import XCTest
@testable import SnipperCore

final class ModelAndStorageTests: XCTestCase {
    private func samplePost(id: String = "1790000000000000000") -> Snip {
        Snip(
            kind: .tweet,
            body: "Liquid glass is a material, not a filter.",
            url: "https://x.com/designer/status/\(id)",
            author: SnipAuthor(name: "Designer", handle: "@designer", avatarURL: "https://pbs.twimg.com/a_normal.jpg"),
            media: [SnipMedia(kind: .image, remoteURL: "https://pbs.twimg.com/media/abc.jpg", width: 1200, height: 800)],
            tags: ["design"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            savedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: "test",
            externalID: TweetReference.externalID(for: id),
            tweet: TweetInfo(tweetID: id, likes: 10)
        )
    }

    func testAuthorDropsAtSign() {
        XCTAssertEqual(SnipAuthor(name: "A", handle: "@abc").handle, "abc")
    }

    func testStorageRoundTrip() throws {
        let snip = samplePost()
        let data = try SnipCoding.storageEncoder().encode(snip)
        let decoded = try SnipCoding.storageDecoder().decode(Snip.self, from: data)
        XCTAssertEqual(decoded, snip)
    }

    func testDecodingToleratesMissingAndUnknownFields() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"hologram","media":[{"kind":"sculpture","remoteURL":"https://x"}],"tags":"oops"}"#
        let snip = try SnipCoding.storageDecoder().decode(Snip.self, from: Data(json.utf8))
        XCTAssertEqual(snip.kind, .note)
        XCTAssertEqual(snip.media.first?.kind, .image)
        XCTAssertEqual(snip.tags, [])
        XCTAssertEqual(snip.body, "")
    }

    func testDisplayTitleFallbacks() {
        XCTAssertEqual(samplePost().displayTitle, "Designer")
        XCTAssertEqual(Snip(kind: .note, body: "\n  First line \nSecond").displayTitle, "First line")
        XCTAssertEqual(Snip(kind: .link, url: "https://www.example.com/a").displayTitle, "www.example.com")
        XCTAssertEqual(Snip(kind: .link, url: "https://www.example.com/a").domain, "example.com")
        XCTAssertEqual(Snip(kind: .screenshot).displayTitle, "Screenshot")
    }

    func testDatabaseCRUDAndVectors() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("snipper-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try SnipDatabase(path: path)
        let a = samplePost(id: "1")
        var b = Snip(kind: .note, body: "Second", savedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await db.upsert([a, b])
        var all = try await db.loadAll()
        XCTAssertEqual(all.map(\.id), [b.id, a.id], "newest first")

        b.body = "Second, edited"
        try await db.upsert(b)
        let reloaded = try await db.snip(id: b.id)
        XCTAssertEqual(reloaded?.body, "Second, edited")
        let total = try await db.count()
        XCTAssertEqual(total, 2)

        let vector = VectorMath.normalized([1, 2, 3, 4])
        try await db.saveVectors([StoredVector(snipID: a.id, contentHash: "h1", vector: vector)], model: "m")
        try await db.saveVectors([StoredVector(snipID: a.id, contentHash: "h2", vector: vector)], model: "m")
        var vectors = try await db.vectors(model: "m")
        XCTAssertEqual(vectors.count, 1)
        XCTAssertEqual(vectors.first?.contentHash, "h2")
        XCTAssertEqual(vectors.first?.vector ?? [], vector)
        let otherModel = try await db.vectors(model: "other")
        XCTAssertTrue(otherModel.isEmpty)

        try await db.delete(ids: [a.id])
        all = try await db.loadAll()
        XCTAssertEqual(all.map(\.id), [b.id])
        vectors = try await db.vectors(model: "m")
        XCTAssertTrue(vectors.isEmpty)
        let vectorCount = try await db.vectorCount(model: "m")
        XCTAssertEqual(vectorCount, 0)

        // Reopening sees the same data (migrations are idempotent).
        let reopened = try SnipDatabase(path: path)
        let afterReopen = try await reopened.loadAll()
        XCTAssertEqual(afterReopen.map(\.id), [b.id])
    }

    func testVectorMath() {
        let v = VectorMath.normalized([3, 4])
        XCTAssertEqual(v[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(v[1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.dot([1, 2, 3], [4, 5, 6]), 32, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.decode(VectorMath.encode([1.5, -2.25, 0])), [1.5, -2.25, 0])
        let t = VectorMath.truncated([3, 4, 12], to: 2)
        XCTAssertEqual(t[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.normalized([0, 0]), [0, 0])
    }

    func testVectorMatrixTopK() {
        let a = UUID(), b = UUID(), c = UUID(), wrong = UUID()
        let m = VectorMatrix(dimensions: 2, rows: [
            (a, [1, 0]), (b, VectorMath.normalized([1, 1])), (c, [0, 1]), (wrong, [1, 0, 0]),
        ])
        XCTAssertEqual(m.count, 3, "rows with the wrong size are skipped")
        let top = m.topK([1, 0], k: 2)
        XCTAssertEqual(top.map(\.id), [a, b])
        XCTAssertEqual(m.topK([1, 0], k: 5, excluding: [a]).map(\.id), [b, c])
        XCTAssertEqual(m.scoreMap(for: [0, 1])[c] ?? 0, 1, accuracy: 1e-6)
        XCTAssertTrue(m.scores(for: [1, 0, 0]).isEmpty)
    }

    func testContentHashIsStable() {
        XCTAssertEqual(ContentHash.fnv1a(""), "cbf29ce484222325")
        XCTAssertEqual(ContentHash.fnv1a("a"), "af63dc4c8601ec8c")
        XCTAssertNotEqual(ContentHash.fnv1a("a"), ContentHash.fnv1a("b"))
    }

    func testDateParsing() {
        XCTAssertEqual(DateParsing.parse("Wed Oct 10 20:19:24 +0000 2018")?.timeIntervalSince1970, 1_539_202_764)
        XCTAssertEqual(DateParsing.parse("2018-10-10T20:19:24.000Z")?.timeIntervalSince1970, 1_539_202_764)
        XCTAssertEqual(DateParsing.parse("2018-10-10T20:19:24Z")?.timeIntervalSince1970, 1_539_202_764)
        XCTAssertEqual(DateParsing.parse("1539202764")?.timeIntervalSince1970, 1_539_202_764)
        XCTAssertEqual(DateParsing.parse("1539202764000")?.timeIntervalSince1970, 1_539_202_764)
        XCTAssertEqual(DateParsing.parse("March 1, 2024")?.timeIntervalSince1970, 1_709_251_200)
        XCTAssertNil(DateParsing.parse("not a date"))
    }

    func testCompactNumbers() {
        XCTAssertEqual(CompactNumber.format(0), "0")
        XCTAssertEqual(CompactNumber.format(999), "999")
        XCTAssertEqual(CompactNumber.format(1_000), "1K")
        XCTAssertEqual(CompactNumber.format(1_250), "1.3K")
        XCTAssertEqual(CompactNumber.format(15_300), "15.3K")
        XCTAssertEqual(CompactNumber.format(999_999), "1M")
        XCTAssertEqual(CompactNumber.format(2_000_000), "2M")
        XCTAssertEqual(CompactNumber.format(-1_500), "-1.5K")
    }
}
