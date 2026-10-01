import Foundation
import SQLite3

/// SQLite-backed store for language-learning profiles and the spaced-repetition deck.
/// Lives at `~/Konishi/language/deck.sqlite`. All access is on the main actor (owned by AppModel).
@MainActor
final class LanguageStore {
    nonisolated(unsafe) private var db: OpaquePointer?

    /// Aggregate deck figures for a profile, for the UI header/stats.
    struct Stats: Sendable {
        var total = 0
        var due = 0
        var mastered = 0            // box == max
        var reviewedToday = 0
        var perKind: [LearnKind: Int] = [:]
    }

    // SQLite wants to copy bound strings rather than keep our transient pointers.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        try? FileManager.default.createDirectory(at: Paths.language, withIntermediateDirectories: true)
        open()
        createSchema()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func open() {
        if sqlite3_open(Paths.languageDB.path, &db) != SQLITE_OK {
            NSLog("LanguageStore: failed to open \(Paths.languageDB.path)")
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
    }

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS profiles (
            id TEXT PRIMARY KEY,
            targetLocale TEXT NOT NULL,
            targetName TEXT NOT NULL,
            baseLocale TEXT NOT NULL,
            baseName TEXT NOT NULL,
            level TEXT NOT NULL,
            romanization TEXT NOT NULL,
            scriptNotes TEXT NOT NULL,
            targetVoiceID TEXT NOT NULL DEFAULT '',
            baseVoiceID TEXT NOT NULL DEFAULT '',
            goals TEXT NOT NULL,
            createdAt REAL NOT NULL
        );
        """)
        // Migrations for existing installs (errors ignored if the column already exists).
        exec("ALTER TABLE profiles ADD COLUMN targetVoiceID TEXT NOT NULL DEFAULT '';")
        exec("ALTER TABLE profiles ADD COLUMN baseVoiceID TEXT NOT NULL DEFAULT '';")
        exec("""
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY,
            profileID TEXT NOT NULL,
            kind TEXT NOT NULL,
            term TEXT NOT NULL,
            reading TEXT NOT NULL,
            translation TEXT NOT NULL,
            partOfSpeech TEXT NOT NULL,
            register TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            examples TEXT NOT NULL,
            tags TEXT NOT NULL,
            box INTEGER NOT NULL,
            dueDate REAL NOT NULL,
            timesSeen INTEGER NOT NULL,
            timesCorrect INTEGER NOT NULL,
            timesWrong INTEGER NOT NULL,
            createdAt REAL NOT NULL,
            lastReviewedAt REAL,
            sourceConversationID TEXT
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_items_due ON items(profileID, dueDate);")
        exec("CREATE INDEX IF NOT EXISTS idx_items_kind ON items(profileID, kind);")
    }

    // MARK: - Profiles

    func allProfiles() -> [LanguageProfile] {
        var out: [LanguageProfile] = []
        query("SELECT id, targetLocale, targetName, baseLocale, baseName, level, romanization, scriptNotes, targetVoiceID, baseVoiceID, goals, createdAt FROM profiles ORDER BY createdAt;") { stmt in
            out.append(LanguageProfile(
                id: UUID(uuidString: Self.text(stmt, 0)) ?? UUID(),
                targetLocale: Self.text(stmt, 1),
                targetName: Self.text(stmt, 2),
                baseLocale: Self.text(stmt, 3),
                baseName: Self.text(stmt, 4),
                level: CEFRLevel(rawValue: Self.text(stmt, 5)) ?? .a1,
                romanization: RomanizationMode(rawValue: Self.text(stmt, 6)) ?? .whenNew,
                scriptNotes: Self.text(stmt, 7),
                targetVoiceID: Self.text(stmt, 8),
                baseVoiceID: Self.text(stmt, 9),
                goals: Self.text(stmt, 10),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
            ))
        }
        return out
    }

    func profile(id: UUID) -> LanguageProfile? {
        allProfiles().first { $0.id == id }
    }

    func upsertProfile(_ p: LanguageProfile) {
        let sql = """
        INSERT INTO profiles (id, targetLocale, targetName, baseLocale, baseName, level, romanization, scriptNotes, targetVoiceID, baseVoiceID, goals, createdAt)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            targetLocale=excluded.targetLocale, targetName=excluded.targetName,
            baseLocale=excluded.baseLocale, baseName=excluded.baseName,
            level=excluded.level, romanization=excluded.romanization,
            scriptNotes=excluded.scriptNotes, targetVoiceID=excluded.targetVoiceID,
            baseVoiceID=excluded.baseVoiceID, goals=excluded.goals;
        """
        prepared(sql) { stmt in
            bind(stmt, 1, p.id.uuidString)
            bind(stmt, 2, p.targetLocale)
            bind(stmt, 3, p.targetName)
            bind(stmt, 4, p.baseLocale)
            bind(stmt, 5, p.baseName)
            bind(stmt, 6, p.level.rawValue)
            bind(stmt, 7, p.romanization.rawValue)
            bind(stmt, 8, p.scriptNotes)
            bind(stmt, 9, p.targetVoiceID)
            bind(stmt, 10, p.baseVoiceID)
            bind(stmt, 11, p.goals)
            sqlite3_bind_double(stmt, 12, p.createdAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func deleteProfile(id: UUID) {
        prepared("DELETE FROM items WHERE profileID = ?;") { stmt in
            bind(stmt, 1, id.uuidString); sqlite3_step(stmt)
        }
        prepared("DELETE FROM profiles WHERE id = ?;") { stmt in
            bind(stmt, 1, id.uuidString); sqlite3_step(stmt)
        }
    }

    // MARK: - Items

    func upsert(_ item: LearnItem) {
        let sql = """
        INSERT INTO items (id, profileID, kind, term, reading, translation, partOfSpeech, register, notes, examples, tags, box, dueDate, timesSeen, timesCorrect, timesWrong, createdAt, lastReviewedAt, sourceConversationID)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            kind=excluded.kind, term=excluded.term, reading=excluded.reading, translation=excluded.translation,
            partOfSpeech=excluded.partOfSpeech, register=excluded.register, notes=excluded.notes,
            examples=excluded.examples, tags=excluded.tags,
            box=excluded.box, dueDate=excluded.dueDate, timesSeen=excluded.timesSeen,
            timesCorrect=excluded.timesCorrect, timesWrong=excluded.timesWrong,
            lastReviewedAt=excluded.lastReviewedAt, sourceConversationID=excluded.sourceConversationID;
        """
        prepared(sql) { stmt in
            bind(stmt, 1, item.id.uuidString)
            bind(stmt, 2, item.profileID.uuidString)
            bind(stmt, 3, item.kind.rawValue)
            bind(stmt, 4, item.term)
            bind(stmt, 5, item.reading)
            bind(stmt, 6, item.translation)
            bind(stmt, 7, item.partOfSpeech)
            bind(stmt, 8, item.register)
            bind(stmt, 9, item.notes)
            bind(stmt, 10, Self.encodeArray(item.examples))
            bind(stmt, 11, Self.encodeArray(item.tags))
            sqlite3_bind_int(stmt, 12, Int32(item.box))
            sqlite3_bind_double(stmt, 13, item.dueDate.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 14, Int32(item.timesSeen))
            sqlite3_bind_int(stmt, 15, Int32(item.timesCorrect))
            sqlite3_bind_int(stmt, 16, Int32(item.timesWrong))
            sqlite3_bind_double(stmt, 17, item.createdAt.timeIntervalSince1970)
            if let r = item.lastReviewedAt { sqlite3_bind_double(stmt, 18, r.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 18) }
            if let c = item.sourceConversationID { bind(stmt, 19, c.uuidString) } else { sqlite3_bind_null(stmt, 19) }
            sqlite3_step(stmt)
        }
    }

    func item(id: UUID) -> LearnItem? {
        var out: LearnItem?
        prepared("\(Self.itemSelect) WHERE id = ?;") { stmt in
            bind(stmt, 1, id.uuidString)
            if sqlite3_step(stmt) == SQLITE_ROW { out = Self.readItem(stmt) }
        }
        return out
    }

    func delete(id: UUID) {
        prepared("DELETE FROM items WHERE id = ?;") { stmt in
            bind(stmt, 1, id.uuidString); sqlite3_step(stmt)
        }
    }

    /// All items for a profile, optionally filtered by kind, newest first.
    func items(profileID: UUID, kind: LearnKind? = nil) -> [LearnItem] {
        var out: [LearnItem] = []
        let filter = kind == nil ? "" : " AND kind = ?"
        prepared("\(Self.itemSelect) WHERE profileID = ?\(filter) ORDER BY createdAt DESC;") { stmt in
            bind(stmt, 1, profileID.uuidString)
            if let kind { bind(stmt, 2, kind.rawValue) }
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(Self.readItem(stmt)) }
        }
        return out
    }

    /// Cards whose review date has passed, soonest-due first.
    func dueItems(profileID: UUID, limit: Int = 20, at now: Date = Date()) -> [LearnItem] {
        var out: [LearnItem] = []
        prepared("\(Self.itemSelect) WHERE profileID = ? AND dueDate <= ? ORDER BY dueDate ASC LIMIT ?;") { stmt in
            bind(stmt, 1, profileID.uuidString)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(max(1, limit)))
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(Self.readItem(stmt)) }
        }
        return out
    }

    /// Case-insensitive substring match over term, reading, and translation.
    func search(profileID: UUID, query: String, limit: Int = 20) -> [LearnItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [LearnItem] = []
        // Escape LIKE wildcards so a query containing % or _ matches literally.
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let like = "%\(escaped)%"
        prepared("\(Self.itemSelect) WHERE profileID = ? AND (term LIKE ? ESCAPE '\\' OR reading LIKE ? ESCAPE '\\' OR translation LIKE ? ESCAPE '\\') ORDER BY createdAt DESC LIMIT ?;") { stmt in
            bind(stmt, 1, profileID.uuidString)
            bind(stmt, 2, like)
            bind(stmt, 3, like)
            bind(stmt, 4, like)
            sqlite3_bind_int(stmt, 5, Int32(max(1, limit)))
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(Self.readItem(stmt)) }
        }
        return out
    }

    /// An existing card with the same kind and term (case-insensitive), for dedup on add.
    func findByTerm(profileID: UUID, kind: LearnKind, term: String) -> LearnItem? {
        var out: LearnItem?
        prepared("\(Self.itemSelect) WHERE profileID = ? AND kind = ? AND term = ? COLLATE NOCASE LIMIT 1;") { stmt in
            bind(stmt, 1, profileID.uuidString)
            bind(stmt, 2, kind.rawValue)
            bind(stmt, 3, term)
            if sqlite3_step(stmt) == SQLITE_ROW { out = Self.readItem(stmt) }
        }
        return out
    }

    /// Most common tags across a profile's cards, for a compact "topics covered" summary.
    func topTags(profileID: UUID, limit: Int = 6) -> [String] {
        var counts: [String: Int] = [:]
        prepared("SELECT tags FROM items WHERE profileID = ?;") { stmt in
            bind(stmt, 1, profileID.uuidString)
            while sqlite3_step(stmt) == SQLITE_ROW {
                for t in Self.decodeArray(Self.text(stmt, 0)) where !t.isEmpty {
                    counts[t, default: 0] += 1
                }
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// Card totals per profile in a single query, for the profile menu (avoids a scan per profile).
    func cardCounts() -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        query("SELECT profileID, COUNT(*) FROM items GROUP BY profileID;") { stmt in
            if let id = UUID(uuidString: Self.text(stmt, 0)) {
                out[id] = Int(sqlite3_column_int(stmt, 1))
            }
        }
        return out
    }

    func stats(profileID: UUID, at now: Date = Date()) -> Stats {
        var s = Stats()
        let startOfDay = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        prepared("SELECT box, kind, dueDate, lastReviewedAt FROM items WHERE profileID = ?;") { stmt in
            bind(stmt, 1, profileID.uuidString)
            while sqlite3_step(stmt) == SQLITE_ROW {
                s.total += 1
                let box = Int(sqlite3_column_int(stmt, 0))
                if box >= LearnItem.boxCount { s.mastered += 1 }
                if let kind = LearnKind(rawValue: Self.text(stmt, 1)) {
                    s.perKind[kind, default: 0] += 1
                }
                if sqlite3_column_double(stmt, 2) <= now.timeIntervalSince1970 { s.due += 1 }
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL,
                    sqlite3_column_double(stmt, 3) >= startOfDay
                {
                    s.reviewedToday += 1
                }
            }
        }
        return s
    }

    /// Stats and top tags in a single table scan, for the per-turn deck summary.
    func deckSummary(profileID: UUID, tagLimit: Int = 6, at now: Date = Date()) -> (stats: Stats, topTags: [String]) {
        var s = Stats()
        var tagCounts: [String: Int] = [:]
        let startOfDay = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        prepared("SELECT box, kind, dueDate, tags, lastReviewedAt FROM items WHERE profileID = ?;") { stmt in
            bind(stmt, 1, profileID.uuidString)
            while sqlite3_step(stmt) == SQLITE_ROW {
                s.total += 1
                let box = Int(sqlite3_column_int(stmt, 0))
                if box >= LearnItem.boxCount { s.mastered += 1 }
                if let kind = LearnKind(rawValue: Self.text(stmt, 1)) {
                    s.perKind[kind, default: 0] += 1
                }
                if sqlite3_column_double(stmt, 2) <= now.timeIntervalSince1970 { s.due += 1 }
                for t in Self.decodeArray(Self.text(stmt, 3)) where !t.isEmpty {
                    tagCounts[t, default: 0] += 1
                }
                if sqlite3_column_type(stmt, 4) != SQLITE_NULL,
                    sqlite3_column_double(stmt, 4) >= startOfDay
                {
                    s.reviewedToday += 1
                }
            }
        }
        let tags = tagCounts.sorted { $0.value > $1.value }.prefix(tagLimit).map(\.key)
        return (s, tags)
    }

    // MARK: - Row mapping

    private static let itemSelect = """
    SELECT id, profileID, kind, term, reading, translation, partOfSpeech, register, notes, examples, tags, box, dueDate, timesSeen, timesCorrect, timesWrong, createdAt, lastReviewedAt, sourceConversationID FROM items
    """

    private static func readItem(_ stmt: OpaquePointer?) -> LearnItem {
        LearnItem(
            id: UUID(uuidString: text(stmt, 0)) ?? UUID(),
            profileID: UUID(uuidString: text(stmt, 1)) ?? UUID(),
            kind: LearnKind(rawValue: text(stmt, 2)) ?? .vocab,
            term: text(stmt, 3),
            reading: text(stmt, 4),
            translation: text(stmt, 5),
            partOfSpeech: text(stmt, 6),
            register: text(stmt, 7),
            notes: text(stmt, 8),
            examples: decodeArray(text(stmt, 9)),
            tags: decodeArray(text(stmt, 10)),
            box: Int(sqlite3_column_int(stmt, 11)),
            dueDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)),
            timesSeen: Int(sqlite3_column_int(stmt, 13)),
            timesCorrect: Int(sqlite3_column_int(stmt, 14)),
            timesWrong: Int(sqlite3_column_int(stmt, 15)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 16)),
            lastReviewedAt: sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 17)),
            sourceConversationID: sqlite3_column_type(stmt, 18) == SQLITE_NULL ? nil : UUID(uuidString: text(stmt, 18))
        )
    }

    // MARK: - Low-level helpers

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepared(_ sql: String, _ body: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("LanguageStore: prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        body(stmt)
    }

    private func query(_ sql: String, _ row: (OpaquePointer?) -> Void) {
        prepared(sql) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private static func encodeArray(_ arr: [String]) -> String {
        guard !arr.isEmpty, let data = try? JSONEncoder().encode(arr), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private static func decodeArray(_ s: String) -> [String] {
        guard let data = s.data(using: .utf8), let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }
}
