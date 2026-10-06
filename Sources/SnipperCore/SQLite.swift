import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

public enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

// SQLITE_TRANSIENT is a macro Swift cannot import: it tells SQLite to copy bound buffers.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal wrapper around one SQLite connection. Not thread-safe on its own:
/// it is owned by `SnipDatabase`, an actor that serializes access.
public final class SQLiteConnection: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// Runs one or more statements that return no rows we care about.
    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw SQLiteError(code: rc, message: message)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw SQLiteError(code: rc, message: errorMessage)
        }
        return SQLiteStatement(statement: statement, connection: self)
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let result = try body()
            try execute("COMMIT TRANSACTION")
            return result
        } catch {
            try? execute("ROLLBACK TRANSACTION")
            throw error
        }
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    public func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        return try statement.step() ? statement.int(0) : 0
    }
}

public final class SQLiteStatement {
    private let statement: OpaquePointer
    private let connection: SQLiteConnection

    fileprivate init(statement: OpaquePointer, connection: SQLiteConnection) {
        self.statement = statement
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(statement)
    }

    /// Resets the statement and binds `values` to its parameters, in order.
    public func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(statement, index)
            case .integer(let v):
                rc = sqlite3_bind_int64(statement, index, v)
            case .real(let v):
                rc = sqlite3_bind_double(statement, index, v)
            case .text(let v):
                rc = sqlite3_bind_text(statement, index, v, -1, transient)
            case .blob(let v):
                if v.isEmpty {
                    rc = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    rc = v.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
                    }
                }
            }
            guard rc == SQLITE_OK else {
                throw SQLiteError(code: rc, message: connection.errorMessage)
            }
        }
    }

    /// Advances to the next row. Returns false when the statement is done.
    @discardableResult
    public func step() throws -> Bool {
        let rc = sqlite3_step(statement)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: rc, message: connection.errorMessage)
        }
    }

    /// Binds and runs a statement that returns no rows.
    public func run(_ values: [SQLiteValue] = []) throws {
        try bind(values)
        while try step() {}
    }

    public func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    public func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    public func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    public func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    public func data(_ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
