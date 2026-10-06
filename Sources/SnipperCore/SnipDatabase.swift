import Foundation

/// An embedding stored for one snip and one model.
public struct StoredVector: Sendable, Equatable {
    public var snipID: UUID
    /// Hash of the embedding input, so changed content gets re-embedded.
    public var contentHash: String
    public var vector: [Float]

    public init(snipID: UUID, contentHash: String, vector: [Float]) {
        self.snipID = snipID
        self.contentHash = contentHash
        self.vector = vector
    }
}

/// Persistent storage for snips and their embeddings (SQLite).
///
/// Snips are stored as JSON documents with a few indexed columns, which keeps
/// schema changes cheap: new optional fields need no migration.
public actor SnipDatabase {
    private let connection: SQLiteConnection
    private let encoder = SnipCoding.storageEncoder()
    private let decoder = SnipCoding.storageDecoder()

    /// Opens (creating if needed) the database at `fileURL`. Pass ":memory:" paths for tests.
    public init(path: String) throws {
        connection = try SQLiteConnection(path: path)
        try Self.migrate(connection)
    }

    public init(fileURL: URL) throws {
        try self.init(path: fileURL.path)
    }

    private static func migrate(_ c: SQLiteConnection) throws {
        try c.execute("PRAGMA journal_mode = WAL")
        try c.execute("PRAGMA synchronous = NORMAL")
        let version = try c.scalarInt("PRAGMA user_version")
        if version < 1 {
            try c.execute("""
            CREATE TABLE IF NOT EXISTS snips (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                saved_at REAL NOT NULL,
                external_id TEXT,
                data BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS snips_saved_at ON snips(saved_at DESC);
            CREATE INDEX IF NOT EXISTS snips_external_id ON snips(external_id);
            CREATE TABLE IF NOT EXISTS vectors (
                snip_id TEXT NOT NULL,
                model TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                dim INTEGER NOT NULL,
                vector BLOB NOT NULL,
                PRIMARY KEY (snip_id, model)
            );
            PRAGMA user_version = 1;
            """)
        }
    }

    // MARK: Snips

    /// All snips, newest first. Rows that fail to decode are skipped.
    public func loadAll() throws -> [Snip] {
        let statement = try connection.prepare("SELECT data FROM snips ORDER BY saved_at DESC")
        var snips: [Snip] = []
        while try statement.step() {
            if let snip = try? decoder.decode(Snip.self, from: statement.data(0)) {
                snips.append(snip)
            }
        }
        return snips
    }

    public func count() throws -> Int {
        try connection.scalarInt("SELECT COUNT(*) FROM snips")
    }

    public func snip(id: UUID) throws -> Snip? {
        let statement = try connection.prepare("SELECT data FROM snips WHERE id = ?")
        try statement.bind([.text(id.uuidString)])
        guard try statement.step() else { return nil }
        return try? decoder.decode(Snip.self, from: statement.data(0))
    }

    public func upsert(_ snip: Snip) throws {
        try upsert([snip])
    }

    public func upsert(_ snips: [Snip]) throws {
        guard !snips.isEmpty else { return }
        let statement = try connection.prepare("""
        INSERT INTO snips (id, kind, saved_at, external_id, data) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind,
            saved_at = excluded.saved_at,
            external_id = excluded.external_id,
            data = excluded.data
        """)
        try connection.transaction {
            for snip in snips {
                let data = try encoder.encode(snip)
                try statement.run([
                    .text(snip.id.uuidString),
                    .text(snip.kind.rawValue),
                    .real(snip.savedAt.timeIntervalSince1970),
                    snip.externalID.map { .text($0) } ?? .null,
                    .blob(data),
                ])
            }
        }
    }

    public func delete(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let deleteSnip = try connection.prepare("DELETE FROM snips WHERE id = ?")
        let deleteVectors = try connection.prepare("DELETE FROM vectors WHERE snip_id = ?")
        try connection.transaction {
            for id in ids {
                try deleteSnip.run([.text(id.uuidString)])
                try deleteVectors.run([.text(id.uuidString)])
            }
        }
    }

    // MARK: Vectors

    /// Vectors stored for `model`, for snips that still exist.
    public func vectors(model: String) throws -> [StoredVector] {
        let statement = try connection.prepare("""
        SELECT v.snip_id, v.content_hash, v.vector FROM vectors v
        JOIN snips s ON s.id = v.snip_id
        WHERE v.model = ?
        """)
        try statement.bind([.text(model)])
        var result: [StoredVector] = []
        while try statement.step() {
            guard let raw = statement.string(0), let id = UUID(uuidString: raw) else { continue }
            result.append(StoredVector(
                snipID: id,
                contentHash: statement.string(1) ?? "",
                vector: VectorMath.decode(statement.data(2))
            ))
        }
        return result
    }

    public func saveVectors(_ vectors: [StoredVector], model: String) throws {
        guard !vectors.isEmpty else { return }
        let statement = try connection.prepare("""
        INSERT INTO vectors (snip_id, model, content_hash, dim, vector) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(snip_id, model) DO UPDATE SET
            content_hash = excluded.content_hash,
            dim = excluded.dim,
            vector = excluded.vector
        """)
        try connection.transaction {
            for v in vectors {
                try statement.run([
                    .text(v.snipID.uuidString),
                    .text(model),
                    .text(v.contentHash),
                    .integer(Int64(v.vector.count)),
                    .blob(VectorMath.encode(v.vector)),
                ])
            }
        }
    }

    /// Removes vectors for one model, or for every model when `model` is nil.
    public func deleteVectors(model: String?) throws {
        if let model {
            try connection.prepare("DELETE FROM vectors WHERE model = ?").run([.text(model)])
        } else {
            try connection.execute("DELETE FROM vectors")
        }
    }

    public func vectorCount(model: String) throws -> Int {
        let statement = try connection.prepare("SELECT COUNT(*) FROM vectors WHERE model = ?")
        try statement.bind([.text(model)])
        return try statement.step() ? statement.int(0) : 0
    }
}
