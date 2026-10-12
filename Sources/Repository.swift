import Foundation
import SQLite3

/// Один запис на сутність; JSON payload версії 1 допускає незалежну міграцію моделей.
/// Усі таблиці оновлюються в одній транзакції. UI не працює з SQLite напряму.
final class Repository {
    private var db: OpaquePointer?
    init(directory: URL? = nil) throws {
        let folder: URL
        if let directory { folder = directory }
        else { folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Atelier", isDirectory: true) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        let path = folder.appendingPathComponent("atelier.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw AppError.message("Не вдалося відкрити базу") }
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
        sqlite3_finalize(statement)
        guard version <= 1 && version >= 0 else { throw AppError.message("База потребує новішої версії застосунку") }
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["clients", "orders", "payments", "expenses", "services", "drafts", "metadata"] {
                try execute("CREATE TABLE IF NOT EXISTS \(table) (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
            }
            try execute("PRAGMA user_version=1; COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    deinit { sqlite3_close(db) }
    private func failure() -> AppError { .message(String(cString: sqlite3_errmsg(db))) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func read<T: Decodable>(_ table: String, as: T.Type) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table) ORDER BY rowid", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            values.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
        return values
    }
    private func write<T: Encodable>(_ table: String, _ values: [(String, T)]) throws {
        try execute("DELETE FROM \(table)")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO \(table) (id,payload) VALUES (?,?)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (id, value) in values {
            let data = try JSONEncoder().encode(value)
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let result = id.withCString { key in
                data.withUnsafeBytes { bytes -> Int32 in
                    guard sqlite3_bind_text(statement, 1, key, -1, nil) == SQLITE_OK,
                          sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), nil) == SQLITE_OK else { return SQLITE_ERROR }
                    return sqlite3_step(statement)
                }
            }
            guard result == SQLITE_DONE else { throw failure() }
        }
    }
    struct Metadata: Codable { var nextNumber: Int; var settings: Settings; var formatVersion: Int }
    func load() throws -> Database {
        var result = Database()
        result.clients = try read("clients", as: Client.self)
        result.orders = try read("orders", as: Order.self)
        result.payments = try read("payments", as: Payment.self)
        result.expenses = try read("expenses", as: Expense.self)
        result.services = try read("services", as: Service.self)
        result.drafts = try read("drafts", as: Draft.self)
        if let meta = try read("metadata", as: Metadata.self).first {
            result.nextNumber = meta.nextNumber; result.settings = meta.settings; result.formatVersion = meta.formatVersion
        }
        try result.validate()
        return result
    }
    func save(_ value: Database) throws {
        try value.validate()
        try execute("BEGIN IMMEDIATE")
        do {
            try write("clients", value.clients.map { ($0.id.uuidString, $0) })
            try write("orders", value.orders.map { ($0.id.uuidString, $0) })
            try write("payments", value.payments.map { ($0.id.uuidString, $0) })
            try write("expenses", value.expenses.map { ($0.id.uuidString, $0) })
            try write("services", value.services.map { ($0.id.uuidString, $0) })
            try write("drafts", value.drafts.map { ($0.id.uuidString, $0) })
            try write("metadata", [("state", Metadata(nextNumber: value.nextNumber, settings: value.settings, formatVersion: value.formatVersion))])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
}
