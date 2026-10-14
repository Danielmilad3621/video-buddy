// Minimal wrapper over the SQLite C API: open, exec, parameterised queries, transactions.
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct Row {
    var values: [String: Any] = [:]
    func string(_ k: String) -> String? { values[k] as? String }
    func int64(_ k: String) -> Int64? { (values[k] as? Int64) ?? (values[k] as? Double).map { Int64($0) } }
    func int(_ k: String) -> Int? { int64(k).map { Int($0) } }
    func double(_ k: String) -> Double? { (values[k] as? Double) ?? (values[k] as? Int64).map { Double($0) } }
    func date(_ k: String) -> Date? { double(k).map { Date(timeIntervalSince1970: $0) } }
    func bool(_ k: String) -> Bool { int64(k) == 1 }
}

final class SQLite {
    let handle: OpaquePointer

    init(path: String, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            sqlite3_close(db)
            throw SQLiteError(message: "\(path): \(msg)")
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { sqlite3_close_v2(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    /// Runs a statement that returns no rows. Returns the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> Int {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(message: lastError) }
        return Int(sqlite3_changes(handle))
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func query(_ sql: String, _ args: [Any?] = []) throws -> [Row] {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(message: lastError) }
            var row = Row()
            for i in 0..<sqlite3_column_count(st) {
                let name = String(cString: sqlite3_column_name(st, i))
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: row.values[name] = sqlite3_column_int64(st, i)
                case SQLITE_FLOAT: row.values[name] = sqlite3_column_double(st, i)
                case SQLITE_TEXT: row.values[name] = String(cString: sqlite3_column_text(st, i))
                default: break // NULL; blobs are never stored
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// All-or-nothing: any error rolls back every change made inside `body`.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw SQLiteError(message: "\(lastError) in: \(sql.prefix(120))")
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(st, idx)
            case let v as Bool: sqlite3_bind_int64(st, idx, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Double: sqlite3_bind_double(st, idx, v)
            case let v as Date: sqlite3_bind_double(st, idx, v.timeIntervalSince1970)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, SQLITE_TRANSIENT)
            case let v?: sqlite3_bind_text(st, idx, "\(v)", -1, SQLITE_TRANSIENT)
            }
        }
        return st
    }
}
