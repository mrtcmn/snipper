import Foundation
import XCTest
@testable import SnipperCore

final class GlobeLayoutTests: XCTestCase {
    func testCellsFillRingsFromTheCenter() {
        XCTAssertTrue(GlobeLayout(count: 0, cellAspect: 1.3).cells.isEmpty)
        XCTAssertEqual(GlobeLayout(count: 1, cellAspect: 1.3).cells, [SIMD2(0, 0)])

        let aspect = 1.3
        let layout = GlobeLayout(count: 81, cellAspect: aspect)
        XCTAssertEqual(layout.cells.count, 81)
        XCTAssertEqual(layout.cells.first, SIMD2(0, 0))
        XCTAssertEqual(Set(layout.cells.map { "\($0.x),\($0.y)" }).count, 81, "no two items share a cell")
        XCTAssertEqual(layout.rows % 2, 0, "even rows keep the brick pattern across the repeat")
        XCTAssertGreaterThanOrEqual(layout.columns * layout.rows, 81)
        let distances = layout.cells.map { $0.x * $0.x * aspect * aspect + $0.y * $0.y }
        XCTAssertEqual(distances, distances.sorted(), "better ranks sit closer to the center")

        // Rows differ by at most one card, and cards in a row never overlap, also across the repeat.
        let rows = Dictionary(grouping: layout.cells, by: \.y)
        XCTAssertEqual(rows.count, layout.rows, "no empty band of rows")
        let counts = rows.values.map(\.count)
        XCTAssertLessThanOrEqual(counts.max()! - counts.min()!, 1)
        for row in rows.values {
            let xs: [Double] = row.map(\.x).sorted()
            let wrapped: Double = xs[0] + Double(layout.columns)
            for (a, b) in zip(xs, Array(xs.dropFirst()) + [wrapped]) {
                XCTAssertGreaterThanOrEqual(b - a, 1 - 1e-9)
            }
        }
    }

    func testWrap() {
        XCTAssertEqual(GlobeLayout.wrap(0.4, period: 1), 0.4, accuracy: 1e-9)
        XCTAssertEqual(GlobeLayout.wrap(0.6, period: 1), -0.4, accuracy: 1e-9)
        XCTAssertEqual(GlobeLayout.wrap(-7.25, period: 2), -1.25 + 2, accuracy: 1e-9)
    }
}
