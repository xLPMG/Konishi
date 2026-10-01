import Foundation
import SQLite3

/// Rebuildable full-text index; conversation JSON files remain the source of truth.
struct ConversationSearchIndex: Sendable {
    struct Record: Sendable {
        let id: UUID
        let content: String

        init(_ conversation: Conversation) {
            id = conversation.id
            content = conversation.messages.map(\.content).joined(separator: "\n")
        }
    }

    private let databaseURL: URL
    private static let schemaVersion: Int32 = 1
    private static let table = "conversation_search"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let tokenRegex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)

    init(databaseURL: URL = Paths.conversationSearchIndex) {
        self.databaseURL = databaseURL
    }

    /// Create the index once from existing conversations. Later saves keep it current.
    func rebuildIfNeeded(conversationsDirectory: URL) throws {
        try withDatabase { db in
            guard try Self.userVersion(db) != Self.schemaVersion else { return }
            try Self.execute("BEGIN IMMEDIATE;", on: db)
            do {
                try Self.execute("DROP TABLE IF EXISTS \(Self.table);", on: db)
                try Self.execute(
                    "CREATE VIRTUAL TABLE \(Self.table) USING fts5(conversationID UNINDEXED, content, tokenize='unicode61 remove_diacritics 2');",
                    on: db)
                let urls = ((try? FileManager.default.contentsOfDirectory(
                    at: conversationsDirectory, includingPropertiesForKeys: nil
                )) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
                for url in urls {
                    guard let data = try? Data(contentsOf: url),
                        let conversation = try? JSONDecoder().decode(Conversation.self, from: data)
                    else { continue }
                    try Self.insert(Record(conversation), into: db)
                }
                try Self.execute("PRAGMA user_version = \(Self.schemaVersion);", on: db)
                try Self.execute("COMMIT;", on: db)
            } catch {
                try? Self.execute("ROLLBACK;", on: db)
                throw error
            }
        }
    }

    func upsert(_ record: Record) throws {
        try withDatabase { db in
            try Self.execute("BEGIN IMMEDIATE;", on: db)
            do {
                try Self.delete(record.id, from: db)
                try Self.insert(record, into: db)
                try Self.execute("COMMIT;", on: db)
            } catch {
                try? Self.execute("ROLLBACK;", on: db)
                throw error
            }
        }
    }

    func delete(_ id: UUID) throws {
        try withDatabase { db in
            try Self.execute("BEGIN IMMEDIATE;", on: db)
            do {
                try Self.delete(id, from: db)
                try Self.execute("COMMIT;", on: db)
            } catch {
                try? Self.execute("ROLLBACK;", on: db)
                throw error
            }
        }
    }

    func search(query: String) throws -> Set<UUID> {
        let match = Self.matchQuery(query)
        guard !match.isEmpty else { return [] }
        return try withDatabase { db in
            let sql = "SELECT conversationID FROM \(Self.table) WHERE \(Self.table) MATCH ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                let statement
            else { throw Self.databaseError(db) }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, match, -1, Self.transient)

            var ids: Set<UUID> = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw Self.databaseError(db) }
                guard let text = sqlite3_column_text(statement, 0),
                    let id = UUID(uuidString: String(cString: text))
                else { continue }
                ids.insert(id)
            }
            return ids
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil)
        guard result == SQLITE_OK, let db else {
            let error = db.map(Self.databaseError) ?? SearchIndexError.openFailed
            if let db { sqlite3_close(db) }
            throw error
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private static func userVersion(_ db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw databaseError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(db) }
        return sqlite3_column_int(statement, 0)
    }

    private static func insert(_ record: Record, into db: OpaquePointer) throws {
        let sql = "INSERT INTO \(table) (conversationID, content) VALUES (?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw databaseError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, record.id.uuidString, -1, transient)
        sqlite3_bind_text(statement, 2, record.content, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
    }

    private static func delete(_ id: UUID, from db: OpaquePointer) throws {
        let sql = "DELETE FROM \(table) WHERE conversationID = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw databaseError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id.uuidString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
    }

    private static func matchQuery(_ query: String) -> String {
        let normalized = query.lowercased()
        let range = NSRange(normalized.startIndex..., in: normalized)
        let terms = tokenRegex.matches(in: normalized, range: range)
            .compactMap { Range($0.range, in: normalized).map { String(normalized[$0]) } }
            .prefix(12)
        return terms.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    private static func execute(_ sql: String, on db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw SearchIndexError.sqlite(message)
        }
    }

    private static func databaseError(_ db: OpaquePointer) -> SearchIndexError {
        SearchIndexError.sqlite(String(cString: sqlite3_errmsg(db)))
    }

    private enum SearchIndexError: Error {
        case openFailed
        case sqlite(String)
    }
}