import Foundation

/// Cells for the library globe: equal cards in a brick grid that repeats in every direction.
/// Item 0 sits at the center and later items fill rings around it.
public struct GlobeLayout: Sendable, Equatable {
    /// Cell centers in cell units, one per item: x in column pitches, y in row pitches.
    public let cells: [SIMD2<Double>]
    /// The grid repeats every `columns` pitches horizontally and `rows` pitches vertically.
    public let columns: Int
    public let rows: Int

    /// - Parameter cellAspect: column pitch divided by row pitch, so the grid comes out about square.
    public init(count: Int, cellAspect: Double) {
        let n = max(0, count)
        let aspect = cellAspect > 0 ? cellAspect : 1
        let (rows, columns) = Self.shape(count: n, aspect: aspect)

        // Rows share the items evenly (the extra ones go to the middle rows) and spread them over
        // the full period, so leftover space becomes slightly wider gaps instead of a band of holes.
        let base = n / rows
        let extra = n % rows
        let rowIndices = Array(-(rows / 2)..<(rows - rows / 2))
        let fuller = Set(rowIndices.sorted { abs($0) < abs($1) || (abs($0) == abs($1) && $0 < $1) }.prefix(extra))

        var cells: [SIMD2<Double>] = []
        cells.reserveCapacity(n)
        for row in rowIndices {
            let count = base + (fuller.contains(row) ? 1 : 0)
            guard count > 0 else { continue }
            let spacing = Double(columns) / Double(count)
            // Odd rows shift half a card; an even row count keeps that pattern across the repeat.
            let offset = abs(row) % 2 == 1 ? 0.5 : 0
            for k in -(count / 2)..<(count - count / 2) {
                cells.append(SIMD2((Double(k) + offset) * spacing, Double(row)))
            }
        }
        cells.sort { a, b in
            let da = a.x * a.x * aspect * aspect + a.y * a.y
            let db = b.x * b.x * aspect * aspect + b.y * b.y
            if abs(da - db) > 1e-9 { return da < db }
            return atan2(a.y, a.x) < atan2(b.y, b.x)
        }
        self.cells = cells
        self.columns = columns
        self.rows = rows
    }

    /// An even row count near square that leaves the fewest empty slots.
    private static func shape(count n: Int, aspect: Double) -> (rows: Int, columns: Int) {
        guard n > 1 else { return (1, 1) }
        let ideal = (Double(n) * aspect).squareRoot()
        var best: (rows: Int, columns: Int, empty: Int, off: Double)?
        var rows = max(2, Int(ideal) - 2)
        if rows % 2 == 1 { rows -= 1 }
        while Double(rows) <= ideal + 2.5 {
            let columns = Int((Double(n) / Double(rows)).rounded(.up))
            let empty = rows * columns - n
            let off = abs(Double(rows) - ideal)
            if best == nil || empty < best!.empty || (empty == best!.empty && off < best!.off) {
                best = (rows, columns, empty, off)
            }
            rows += 2
        }
        return (best!.rows, best!.columns)
    }

    /// `value` moved by whole periods into `-period/2 ..< period/2`.
    public static func wrap(_ value: Double, period: Double) -> Double {
        guard period > 0 else { return value }
        return value - period * (value / period).rounded()
    }
}
