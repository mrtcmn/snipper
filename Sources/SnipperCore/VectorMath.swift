import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

public enum VectorMath {
    public static func norm(_ v: [Float]) -> Float {
        #if canImport(Accelerate)
        var result: Float = 0
        vDSP_svesq(v, 1, &result, vDSP_Length(v.count))
        return result.squareRoot()
        #else
        return v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #endif
    }

    /// Returns `v` scaled to unit length (unchanged if it is all zeros).
    public static func normalized(_ v: [Float]) -> [Float] {
        let n = norm(v)
        guard n > 0, n.isFinite else { return v }
        return v.map { $0 / n }
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "Vector sizes differ")
        #if canImport(Accelerate)
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
        #else
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
        #endif
    }

    /// Keeps the leading `dimensions` values and re-normalizes, as Matryoshka
    /// embeddings require after truncation.
    public static func truncated(_ v: [Float], to dimensions: Int) -> [Float] {
        guard dimensions > 0, dimensions < v.count else { return v }
        return normalized(Array(v.prefix(dimensions)))
    }

    /// Little-endian Float32 bytes, the storage format for vectors.
    public static func encode(_ v: [Float]) -> Data {
        var data = Data(capacity: v.count * 4)
        for value in v {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / 4
        var result = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let bits = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                result[i] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return result
    }
}

/// Embeddings for many snips stored as one row-major matrix, for fast
/// similarity scoring against a query vector.
public struct VectorMatrix: Sendable {
    public let ids: [UUID]
    public let dimensions: Int
    private let values: [Float]

    public var count: Int { ids.count }

    /// Rows whose size is not `dimensions` are skipped.
    public init(dimensions: Int, rows: [(UUID, [Float])]) {
        var ids: [UUID] = []
        var values: [Float] = []
        ids.reserveCapacity(rows.count)
        values.reserveCapacity(rows.count * dimensions)
        for (id, vector) in rows where vector.count == dimensions {
            ids.append(id)
            values.append(contentsOf: vector)
        }
        self.ids = ids
        self.dimensions = dimensions
        self.values = values
    }

    /// Dot product of every row with `query` (cosine similarity for unit vectors).
    public func scores(for query: [Float]) -> [Float] {
        guard query.count == dimensions, !ids.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: ids.count)
        #if canImport(Accelerate)
        vDSP_mmul(values, 1, query, 1, &out, 1, vDSP_Length(ids.count), 1, vDSP_Length(dimensions))
        #else
        values.withUnsafeBufferPointer { m in
            for row in 0..<ids.count {
                var sum: Float = 0
                let base = row * dimensions
                for col in 0..<dimensions { sum += m[base + col] * query[col] }
                out[row] = sum
            }
        }
        #endif
        return out
    }

    public func scoreMap(for query: [Float]) -> [UUID: Float] {
        let s = scores(for: query)
        var map: [UUID: Float] = [:]
        map.reserveCapacity(s.count)
        for (i, id) in ids.enumerated() where i < s.count { map[id] = s[i] }
        return map
    }

    public func topK(_ query: [Float], k: Int, excluding: Set<UUID> = []) -> [(id: UUID, score: Float)] {
        let s = scores(for: query)
        var hits: [(id: UUID, score: Float)] = []
        hits.reserveCapacity(s.count)
        for (i, id) in ids.enumerated() where i < s.count && !excluding.contains(id) {
            hits.append((id, s[i]))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(max(0, k)))
    }
}

/// 64-bit FNV-1a, used to detect when a snip's embedding input changed.
public enum ContentHash {
    public static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
