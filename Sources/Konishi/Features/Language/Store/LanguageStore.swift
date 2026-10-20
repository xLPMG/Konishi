import Foundation
import SQLite3

/// SQLite-backed store for language-learning profiles and the spaced-repetition deck.
/// Lives at `~/Konishi/language/deck.sqlite`. All access is on the main actor (owned by AppModel).
@MainActor
final class LanguageStore {
    nonisolated(unsafe) private var db: OpaquePointer?
    private let databaseURL: URL
    private(set) var initializationError: String?

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

    init(databaseURL: URL = Paths.languageDB) {
        self.databaseURL = databaseURL
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        open()
        if initializationError == nil { migrateSchema() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func open() {
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            initializationError = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open language database."
            NSLog("LanguageStore: failed to open \(databaseURL.path): \(initializationError ?? "unknown error")")
            return
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    }

    private func migrateSchema() {
        do {
            let version = try userVersion()
            if version < 1 {
                try transaction {
                    try execute("""
                    CREATE TABLE IF NOT EXISTS profiles (
                        id TEXT PRIMARY KEY, targetLocale TEXT NOT NULL, targetName TEXT NOT NULL,
                        baseLocale TEXT NOT NULL, baseName TEXT NOT NULL, level TEXT NOT NULL,
                        romanization TEXT NOT NULL, scriptNotes TEXT NOT NULL, goals TEXT NOT NULL,
                        createdAt REAL NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS items (
                        id TEXT PRIMARY KEY, profileID TEXT NOT NULL, kind TEXT NOT NULL,
                        term TEXT NOT NULL, reading TEXT NOT NULL, translation TEXT NOT NULL,
                        partOfSpeech TEXT NOT NULL, register TEXT NOT NULL DEFAULT '',
                        notes TEXT NOT NULL DEFAULT '', examples TEXT NOT NULL, tags TEXT NOT NULL,
                        box INTEGER NOT NULL, dueDate REAL NOT NULL, timesSeen INTEGER NOT NULL,
                        timesCorrect INTEGER NOT NULL, timesWrong INTEGER NOT NULL, createdAt REAL NOT NULL,
                        lastReviewedAt REAL, sourceConversationID TEXT
                    );
                    CREATE INDEX IF NOT EXISTS idx_items_due ON items(profileID, dueDate);
                    CREATE INDEX IF NOT EXISTS idx_items_kind ON items(profileID, kind);
                    """)
                    try addColumn("targetVoiceID", definition: "TEXT NOT NULL DEFAULT ''", table: "profiles")
                    try addColumn("baseVoiceID", definition: "TEXT NOT NULL DEFAULT ''", table: "profiles")
                    try execute("PRAGMA user_version = 1;")
                }
            }
            if version < 2 {
                try transaction {
                    try addColumn("acceptedAnswers", definition: "TEXT NOT NULL DEFAULT '[]'", table: "items")
                    try execute("""
                    CREATE TABLE IF NOT EXISTS review_attempts (
                        id TEXT PRIMARY KEY, profileID TEXT NOT NULL, itemID TEXT NOT NULL,
                        activity TEXT NOT NULL, outcome TEXT NOT NULL, createdAt REAL NOT NULL,
                        submittedAnswer TEXT, sessionID TEXT
                    );
                    CREATE INDEX IF NOT EXISTS idx_review_attempts_profile_date
                        ON review_attempts(profileID, createdAt DESC);
                    CREATE INDEX IF NOT EXISTS idx_review_attempts_item
                        ON review_attempts(itemID, createdAt DESC);
                    """)
                    try execute("PRAGMA user_version = 2;")
                }
            }
            if version < 3 {
                try transaction {
                    try execute("""
                    CREATE TABLE IF NOT EXISTS tutor_threads (
                        id TEXT PRIMARY KEY, profileID TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                        title TEXT NOT NULL, createdAt REAL NOT NULL, updatedAt REAL NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS tutor_messages (
                        id TEXT PRIMARY KEY, threadID TEXT NOT NULL REFERENCES tutor_threads(id) ON DELETE CASCADE,
                        role TEXT NOT NULL, content TEXT NOT NULL, createdAt REAL NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS idx_tutor_threads_profile_updated
                        ON tutor_threads(profileID, updatedAt DESC);
                    CREATE INDEX IF NOT EXISTS idx_tutor_messages_thread_date
                        ON tutor_messages(threadID, createdAt);
                    """)
                    try execute("PRAGMA user_version = 3;")
                }
            }
            if version < 4 {
                try transaction {
                    try addColumn("acceptedTranslations", definition: "TEXT NOT NULL DEFAULT '[]'", table: "items")
                    try execute("PRAGMA user_version = 4;")
                }
            }
            if version < 5 {
                try transaction {
                    try addColumn("reasoning", definition: "TEXT", table: "tutor_messages")
                    try execute("PRAGMA user_version = 5;")
                }
            }
            if version < 6 {
                try transaction {
                    try addColumn("toolExchanges", definition: "TEXT", table: "tutor_messages")
                    try execute("PRAGMA user_version = 6;")
                }
            }
        } catch {
            initializationError = error.localizedDescription
            NSLog("LanguageStore: migration failed: \(error.localizedDescription)")
        }
    }

    private func userVersion() throws -> Int {
        try withStatement("PRAGMA user_version;") { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw storeError() }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    private func addColumn(_ name: String, definition: String, table: String) throws {
        let exists = try withStatement("PRAGMA table_info(\(table));") { stmt in
            var found = false
            while sqlite3_step(stmt) == SQLITE_ROW {
                if Self.text(stmt, 1) == name { found = true }
            }
            return found
        }
        if !exists { try execute("ALTER TABLE \(table) ADD COLUMN \(name) \(definition);") }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw storeError() }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw NSError(domain: "LanguageStore.SQLite", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let db else { throw storeError() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw storeError()
        }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func storeError() -> NSError {
        let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Language database is unavailable."
        return NSError(domain: "LanguageStore.SQLite", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: detail])
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
        prepared("DELETE FROM tutor_threads WHERE profileID = ?;") { stmt in
            bind(stmt, 1, id.uuidString); sqlite3_step(stmt)
        }
        prepared("DELETE FROM review_attempts WHERE profileID = ?;") { stmt in
            bind(stmt, 1, id.uuidString); sqlite3_step(stmt)
        }
        prepared("DELETE FROM items WHERE profileID = ?;") { stmt in
            bind(stmt, 1, id.uuidString); sqlite3_step(stmt)
        }
        prepared("DELETE FROM profiles WHERE id = ?;") { stmt in
            bind(stmt, 1, id.uuidString); sqlite3_step(stmt)
        }
    }

    // MARK: - Items

    @discardableResult
    func upsert(_ item: LearnItem) -> Bool {
        let sql = """
        INSERT INTO items (id, profileID, kind, term, reading, translation, partOfSpeech, register, notes, examples, tags, box, dueDate, timesSeen, timesCorrect, timesWrong, createdAt, lastReviewedAt, sourceConversationID, acceptedAnswers, acceptedTranslations)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            kind=excluded.kind, term=excluded.term, reading=excluded.reading, translation=excluded.translation,
            partOfSpeech=excluded.partOfSpeech, register=excluded.register, notes=excluded.notes,
            examples=excluded.examples, tags=excluded.tags,
            box=excluded.box, dueDate=excluded.dueDate, timesSeen=excluded.timesSeen,
            timesCorrect=excluded.timesCorrect, timesWrong=excluded.timesWrong,
            lastReviewedAt=excluded.lastReviewedAt, sourceConversationID=excluded.sourceConversationID,
            acceptedAnswers=excluded.acceptedAnswers, acceptedTranslations=excluded.acceptedTranslations;
        """
        var saved = false
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
            bind(stmt, 20, Self.encodeArray(item.acceptedAnswers))
            bind(stmt, 21, Self.encodeArray(item.acceptedTranslations))
            saved = sqlite3_step(stmt) == SQLITE_DONE
        }
        return saved
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

    /// Atomically inserts an idempotency key and applies the card's Leitner update.
    func recordReview(_ attempt: LanguageReviewAttempt) -> LanguageReviewRecordResult {
        guard initializationError == nil else { return .failed(initializationError ?? "Database unavailable.") }
        guard (attempt.activity == .flashcards) ==
            (attempt.outcome == .again || attempt.outcome == .remembered)
        else { return .invalidAttempt }

        do {
            try execute("BEGIN IMMEDIATE;")
            do {
                guard let original = item(id: attempt.itemID) else {
                    try execute("ROLLBACK;")
                    return .missingCard
                }
                guard original.profileID == attempt.profileID else {
                    try execute("ROLLBACK;")
                    return .profileMismatch
                }
                if let previous = reviewAttempt(id: attempt.id) {
                    try execute("COMMIT;")
                    return previous == attempt ? .alreadyRecorded(original) : .attemptIDConflict
                }

                var updated = original
                updated.recordReview(correct: attempt.outcome.isCorrect, at: attempt.createdAt)
                try withStatement("""
                    INSERT INTO review_attempts (id, profileID, itemID, activity, outcome, createdAt, submittedAnswer, sessionID)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """) { stmt in
                    bind(stmt, 1, attempt.id.uuidString)
                    bind(stmt, 2, attempt.profileID.uuidString)
                    bind(stmt, 3, attempt.itemID.uuidString)
                    bind(stmt, 4, attempt.activity.rawValue)
                    bind(stmt, 5, attempt.outcome.rawValue)
                    sqlite3_bind_double(stmt, 6, attempt.createdAt.timeIntervalSince1970)
                    if let answer = attempt.submittedAnswer { bind(stmt, 7, answer) }
                    else { sqlite3_bind_null(stmt, 7) }
                    if let sessionID = attempt.sessionID { bind(stmt, 8, sessionID.uuidString) }
                    else { sqlite3_bind_null(stmt, 8) }
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw storeError() }
                }
                try withStatement("""
                    UPDATE items SET box = ?, dueDate = ?, timesSeen = ?, timesCorrect = ?, timesWrong = ?, lastReviewedAt = ?
                    WHERE id = ? AND profileID = ?;
                    """) { stmt in
                    sqlite3_bind_int(stmt, 1, Int32(updated.box))
                    sqlite3_bind_double(stmt, 2, updated.dueDate.timeIntervalSince1970)
                    sqlite3_bind_int(stmt, 3, Int32(updated.timesSeen))
                    sqlite3_bind_int(stmt, 4, Int32(updated.timesCorrect))
                    sqlite3_bind_int(stmt, 5, Int32(updated.timesWrong))
                    sqlite3_bind_double(stmt, 6, attempt.createdAt.timeIntervalSince1970)
                    bind(stmt, 7, attempt.itemID.uuidString)
                    bind(stmt, 8, attempt.profileID.uuidString)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw storeError() }
                }
                guard sqlite3_changes(db) == 1 else {
                    try execute("ROLLBACK;")
                    return .missingCard
                }
                try execute("COMMIT;")
                return .recorded(updated)
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func reviewAttempts(profileID: UUID, limit: Int = 20) -> [LanguageReviewAttempt] {
        var out: [LanguageReviewAttempt] = []
        prepared("""
            SELECT id, profileID, itemID, activity, outcome, createdAt, submittedAnswer, sessionID
            FROM review_attempts WHERE profileID = ? ORDER BY createdAt DESC LIMIT ?;
            """) { stmt in
            bind(stmt, 1, profileID.uuidString)
            sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let attempt = Self.readReviewAttempt(stmt) { out.append(attempt) }
            }
        }
        return out
    }

    // MARK: - Tutor threads

    func tutorThreads(profileID: UUID) -> [LanguageTutorThread] {
        var threads: [LanguageTutorThread] = []
        prepared("""
            SELECT id, profileID, title, createdAt, updatedAt
            FROM tutor_threads WHERE profileID = ? ORDER BY updatedAt DESC;
            """) { stmt in
            bind(stmt, 1, profileID.uuidString)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let thread = Self.readTutorThread(stmt) { threads.append(thread) }
            }
        }
        for index in threads.indices {
            threads[index].messages = tutorMessages(threadID: threads[index].id)
        }
        return threads
    }

    func createTutorThread(
        profileID: UUID, title: String = "Tutor conversation", at now: Date = Date()
    ) -> LanguageTutorThread? {
        let thread = LanguageTutorThread(profileID: profileID, title: title, createdAt: now)
        do {
            try withStatement("""
                INSERT INTO tutor_threads (id, profileID, title, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?);
                """) { stmt in
                bind(stmt, 1, thread.id.uuidString)
                bind(stmt, 2, profileID.uuidString)
                bind(stmt, 3, thread.title)
                sqlite3_bind_double(stmt, 4, now.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw storeError() }
            }
            return thread
        } catch {
            return nil
        }
    }

    func appendTutorMessage(_ message: LanguageTutorMessage, to threadID: UUID) -> Bool {
        guard let db else { return false }
        do {
            try transaction {
                try withStatement("""
                    INSERT INTO tutor_messages (id, threadID, role, content, createdAt, reasoning, toolExchanges)
                    VALUES (?, ?, ?, ?, ?, ?, ?);
                    """) { stmt in
                    bind(stmt, 1, message.id.uuidString)
                    bind(stmt, 2, threadID.uuidString)
                    bind(stmt, 3, message.role.rawValue)
                    bind(stmt, 4, message.content)
                    sqlite3_bind_double(stmt, 5, message.createdAt.timeIntervalSince1970)
                    if let reasoning = message.reasoning { bind(stmt, 6, reasoning) }
                    else { sqlite3_bind_null(stmt, 6) }
                    if message.toolExchanges.isEmpty {
                        sqlite3_bind_null(stmt, 7)
                    } else {
                        let data = try JSONEncoder().encode(message.toolExchanges)
                        guard let encoded = String(data: data, encoding: .utf8) else { throw storeError() }
                        bind(stmt, 7, encoded)
                    }
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw storeError() }
                }
                try withStatement("UPDATE tutor_threads SET updatedAt = ? WHERE id = ?;") { stmt in
                    sqlite3_bind_double(stmt, 1, message.createdAt.timeIntervalSince1970)
                    bind(stmt, 2, threadID.uuidString)
                    guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                        throw storeError()
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    func deleteTutorMessage(id: UUID, threadID: UUID) -> Bool {
        guard let db else { return false }
        do {
            try transaction {
                try withStatement("DELETE FROM tutor_messages WHERE id = ? AND threadID = ?;") { stmt in
                    bind(stmt, 1, id.uuidString)
                    bind(stmt, 2, threadID.uuidString)
                    guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                        throw storeError()
                    }
                }
                try withStatement("""
                    UPDATE tutor_threads
                    SET updatedAt = COALESCE(
                        (SELECT MAX(createdAt) FROM tutor_messages WHERE threadID = ?), createdAt)
                    WHERE id = ?;
                    """) { stmt in
                    bind(stmt, 1, threadID.uuidString)
                    bind(stmt, 2, threadID.uuidString)
                    guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                        throw storeError()
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    func updateTutorThreadTitle(_ title: String, threadID: UUID, at now: Date = Date()) -> Bool {
        var changed = false
        prepared("UPDATE tutor_threads SET title = ?, updatedAt = ? WHERE id = ?;") { stmt in
            bind(stmt, 1, title)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            bind(stmt, 3, threadID.uuidString)
            if sqlite3_step(stmt) == SQLITE_DONE { changed = sqlite3_changes(db) == 1 }
        }
        return changed
    }

    func deleteTutorThread(id: UUID) {
        prepared("DELETE FROM tutor_threads WHERE id = ?;") { stmt in
            bind(stmt, 1, id.uuidString); sqlite3_step(stmt)
        }
    }

    private func tutorMessages(threadID: UUID) -> [LanguageTutorMessage] {
        var messages: [LanguageTutorMessage] = []
        prepared("""
            SELECT id, role, content, createdAt, reasoning, toolExchanges FROM tutor_messages
            WHERE threadID = ? ORDER BY createdAt, rowid;
            """) { stmt in
            bind(stmt, 1, threadID.uuidString)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let message = Self.readTutorMessage(stmt) { messages.append(message) }
            }
        }
        return messages
    }

    private static func readTutorThread(_ stmt: OpaquePointer?) -> LanguageTutorThread? {
        guard let id = UUID(uuidString: text(stmt, 0)),
              let profileID = UUID(uuidString: text(stmt, 1))
        else { return nil }
        return LanguageTutorThread(
            id: id, profileID: profileID, title: text(stmt, 2),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)))
    }

    private static func readTutorMessage(_ stmt: OpaquePointer?) -> LanguageTutorMessage? {
        guard let id = UUID(uuidString: text(stmt, 0)),
              let role = LanguageTutorRole(rawValue: text(stmt, 1))
        else { return nil }
        let toolExchanges: [LanguageTutorToolExchange]
        if sqlite3_column_type(stmt, 5) == SQLITE_NULL {
            toolExchanges = []
        } else {
            let data = Data(text(stmt, 5).utf8)
            toolExchanges = (try? JSONDecoder().decode([LanguageTutorToolExchange].self, from: data)) ?? []
        }
        return LanguageTutorMessage(
            id: id, role: role, content: text(stmt, 2),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
            reasoning: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : text(stmt, 4),
            toolExchanges: toolExchanges)
    }

    private func reviewAttempt(id: UUID) -> LanguageReviewAttempt? {
        var out: LanguageReviewAttempt?
        prepared("""
            SELECT id, profileID, itemID, activity, outcome, createdAt, submittedAnswer, sessionID
            FROM review_attempts WHERE id = ?;
            """) { stmt in
            bind(stmt, 1, id.uuidString)
            if sqlite3_step(stmt) == SQLITE_ROW { out = Self.readReviewAttempt(stmt) }
        }
        return out
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
    SELECT id, profileID, kind, term, reading, translation, partOfSpeech, register, notes, examples, tags, box, dueDate, timesSeen, timesCorrect, timesWrong, createdAt, lastReviewedAt, sourceConversationID, acceptedAnswers, acceptedTranslations FROM items
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
            acceptedAnswers: decodeArray(text(stmt, 19)),
            acceptedTranslations: decodeArray(text(stmt, 20)),
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

    private static func readReviewAttempt(_ stmt: OpaquePointer?) -> LanguageReviewAttempt? {
        guard let id = UUID(uuidString: text(stmt, 0)),
              let profileID = UUID(uuidString: text(stmt, 1)),
              let itemID = UUID(uuidString: text(stmt, 2)),
              let activity = LanguageActivity(rawValue: text(stmt, 3)),
              let outcome = LanguageReviewOutcome(rawValue: text(stmt, 4))
        else { return nil }
        return LanguageReviewAttempt(
            id: id, profileID: profileID, itemID: itemID, activity: activity, outcome: outcome,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
            submittedAnswer: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : text(stmt, 6),
            sessionID: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : UUID(uuidString: text(stmt, 7)))
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
