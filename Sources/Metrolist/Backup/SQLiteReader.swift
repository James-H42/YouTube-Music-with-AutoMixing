import Foundation
import SQLite3

enum SQLiteValue {
    case null, integer(Int64), real(Double), text(String), blob(Data)

    var string: String? {
        switch self {
        case .text(let value): value
        case .integer(let value): String(value)
        case .real(let value): String(value)
        default: nil
        }
    }

    var int: Int64? {
        switch self {
        case .integer(let value): value
        case .real(let value): Int64(value)
        case .text(let value): Int64(value)
        default: nil
        }
    }
}

typealias SQLiteRow = [String: SQLiteValue]

/// Reads a SQLite file with the system's libsqlite3, read-only. Backups are opened from a
/// temporary copy, so the original is never touched and a hostile file only ever meets a
/// connection that can't write.
final class SQLiteReader {
    private var handle: OpaquePointer?

    /// The first 16 bytes of every SQLite file.
    static let header = Data("SQLite format 3\0".utf8)

    init?(path: String) {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_exec(handle, "PRAGMA query_only = ON", nil, nil, nil)
        sqlite3_busy_timeout(handle, 1_000)
    }

    deinit { sqlite3_close(handle) }

    /// Runs a query and returns its rows with columns by name; nil when the query is invalid.
    func rows(_ sql: String, limit: Int = 500_000) -> [SQLiteRow]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let columns = (0 ..< sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
        var result: [SQLiteRow] = []
        while sqlite3_step(statement) == SQLITE_ROW, result.count < limit {
            var row: SQLiteRow = [:]
            for (index, name) in columns.enumerated() {
                let column = Int32(index)
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_blob(statement, column)
                    row[name] = .blob(bytes.map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, column))) } ?? Data())
                default: row[name] = SQLiteValue.null
                }
            }
            result.append(row)
        }
        return result
    }

    /// Tables and their column names, lower-cased.
    func tables() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for row in rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") ?? [] {
            guard let name = row["name"]?.string else { continue }
            let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
            let columns = (rows("PRAGMA table_info(\"\(escaped)\")") ?? []).compactMap { $0["name"]?.string?.lowercased() }
            result[name.lowercased()] = Set(columns)
        }
        return result
    }
}
