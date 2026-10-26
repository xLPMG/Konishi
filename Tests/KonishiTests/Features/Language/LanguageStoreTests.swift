import Foundation
import SQLite3
import Testing

@testable import Konishi

@Suite("LanguageStore")
struct LanguageStoreTests {
    @Test("correct and incorrect reviews preserve the Leitner policy")
    func recordReview() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var item = LearnItem(profileID: UUID(), kind: .vocab, term: "言葉", box: 2)

        item.recordReview(correct: true, at: now)
        #expect(item.box == 3)
        #expect(item.timesSeen == 1)
        #expect(item.timesCorrect == 1)
        #expect(item.timesWrong == 0)
        #expect(item.lastReviewedAt == now)
        #expect(item.dueDate == Calendar.current.date(byAdding: .day, value: 7, to: now))

        item.recordReview(correct: false, at: now)
        #expect(item.box == 1)
        #expect(item.timesSeen == 2)
        #expect(item.timesCorrect == 1)
        #expect(item.timesWrong == 1)
        #expect(item.dueDate == Calendar.current.date(byAdding: .day, value: 1, to: now))
    }

    @Test("profiles and populated cards round-trip through SQLite")
    @MainActor
    func populatedRoundTrip() throws {
        let (databaseURL, directory) = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let profile = LanguageProfile(
            targetLocale: "ja-JP", targetName: "Japanese", baseLocale: "en-US", baseName: "English",
            level: .b1, romanization: .never, scriptNotes: "Kanji", targetVoiceID: "target",
            baseVoiceID: "base", goals: "Read novels", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let item = LearnItem(
            profileID: profile.id, kind: .vocab, term: "言葉", reading: "ことば", translation: "word",
            partOfSpeech: "noun", register: "neutral", notes: "A note", examples: ["新しい言葉"],
            tags: ["reading", "daily"], acceptedAnswers: ["term"], box: 3,
            dueDate: Date(timeIntervalSince1970: 1_800_000_000),
            timesSeen: 8, timesCorrect: 6, timesWrong: 2, createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            lastReviewedAt: Date(timeIntervalSince1970: 1_750_000_000))

        let store = LanguageStore(databaseURL: databaseURL)
        store.upsertProfile(profile)
        store.upsert(item)

        let reopened = LanguageStore(databaseURL: databaseURL)
        #expect(reopened.profile(id: profile.id) == profile)
        #expect(reopened.item(id: item.id) == item)
        #expect(try userVersion(at: databaseURL) == 6)
    }

    @Test("legacy profile and item rows survive opening the store")
    @MainActor
    func legacyRowsSurviveSchemaUpgrade() throws {
        let (databaseURL, directory) = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createLegacyDatabase(at: databaseURL)

        let store = LanguageStore(databaseURL: databaseURL)
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let profile = store.profile(id: profileID)
        let item = store.item(id: itemID)

        #expect(profile?.targetName == "Japanese")
        #expect(profile?.targetVoiceID == "")
        #expect(profile?.baseVoiceID == "")
        #expect(item?.term == "言葉")
        #expect(item?.reading == "ことば")
        #expect(item?.translation == "word")
        #expect(item?.timesSeen == 4)
        #expect(item?.timesCorrect == 3)
        #expect(item?.timesWrong == 1)
        #expect(item?.tags == ["legacy"])
        #expect(item?.acceptedAnswers == [])
    }

    @Test("review attempts are atomic and idempotent by attempt UUID")
    @MainActor
    func reviewAttemptIsIdempotent() throws {
        let (databaseURL, directory) = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LanguageStore(databaseURL: databaseURL)
        let profileID = UUID()
        let item = LearnItem(profileID: profileID, kind: .vocab, term: "猫", translation: "cat")
        store.upsertProfile(LanguageProfile(targetLocale: "ja-JP", targetName: "Japanese"))
        store.upsert(item)
        let attempt = LanguageReviewAttempt(
            profileID: profileID, itemID: item.id, activity: .multipleChoice, outcome: .correct,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), submittedAnswer: "cat", sessionID: UUID())

        guard case .recorded(let saved) = store.recordReview(attempt) else {
            Issue.record("The first review attempt should be persisted.")
            return
        }
        #expect(saved.timesSeen == 1)
        #expect(saved.timesCorrect == 1)
        #expect(store.reviewAttempts(profileID: profileID) == [attempt])

        guard case .alreadyRecorded(let unchanged) = store.recordReview(attempt) else {
            Issue.record("Retrying a persisted attempt should be recognized as a duplicate.")
            return
        }
        #expect(unchanged.timesSeen == 1)
        #expect(store.item(id: item.id)?.timesSeen == 1)
        #expect(store.reviewAttempts(profileID: profileID) == [attempt])
    }

    @Test("review rejects profile mismatches and invalid flashcard outcomes")
    @MainActor
    func reviewValidation() {
        let (databaseURL, directory) = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LanguageStore(databaseURL: databaseURL)
        let profileID = UUID()
        let item = LearnItem(profileID: profileID, kind: .vocab, term: "猫", translation: "cat")
        store.upsert(item)

        let mismatch = LanguageReviewAttempt(
            profileID: UUID(), itemID: item.id, activity: .multipleChoice, outcome: .correct)
        #expect(store.recordReview(mismatch) == .profileMismatch)
        let invalid = LanguageReviewAttempt(
            profileID: profileID, itemID: item.id, activity: .flashcards, outcome: .incorrect)
        #expect(store.recordReview(invalid) == .invalidAttempt)
        #expect(store.item(id: item.id)?.timesSeen == 0)
        #expect(store.reviewAttempts(profileID: profileID).isEmpty)
    }

    @Test("failed schedule writes roll back the inserted attempt")
    @MainActor
    func failedScheduleWriteRollsBack() throws {
        let (databaseURL, directory) = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LanguageStore(databaseURL: databaseURL)
        let profileID = UUID()
        let item = LearnItem(profileID: profileID, kind: .vocab, term: "猫", translation: "cat")
        store.upsert(item)
        try executeSQL("""
            CREATE TRIGGER reject_language_review BEFORE UPDATE ON items
            BEGIN SELECT RAISE(ABORT, 'forced review write failure'); END;
            """, at: databaseURL)
        let attempt = LanguageReviewAttempt(
            profileID: profileID, itemID: item.id, activity: .typedRecall, outcome: .incorrect)

        guard case .failed = store.recordReview(attempt) else {
            Issue.record("The injected SQLite failure should be reported to the caller.")
            return
        }
        #expect(store.item(id: item.id)?.timesSeen == 0)
        #expect(store.reviewAttempts(profileID: profileID).isEmpty)
    }

    @Test("tutor threads and messages persist independently per profile")
    @MainActor
    func tutorThreadsRoundTrip() throws {
        let (databaseURL, directory) = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LanguageStore(databaseURL: databaseURL)
        let profile = LanguageProfile(targetLocale: "ja-JP", targetName: "Japanese")
        let otherProfile = LanguageProfile(targetLocale: "ko-KR", targetName: "Korean")
        store.upsertProfile(profile)
        store.upsertProfile(otherProfile)
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let thread = try #require(store.createTutorThread(profileID: profile.id, at: createdAt))
        let userMessage = LanguageTutorMessage(role: .user, content: "こんにちは", createdAt: createdAt)
        let assistantMessage = LanguageTutorMessage(
            role: .assistant, content: "こんにちは。", createdAt: createdAt.addingTimeInterval(1))
        #expect(store.appendTutorMessage(userMessage, to: thread.id))
        #expect(store.appendTutorMessage(assistantMessage, to: thread.id))
        #expect(store.updateTutorThreadTitle("Greetings", threadID: thread.id))

        let reopened = LanguageStore(databaseURL: databaseURL)
        let loaded = try #require(reopened.tutorThreads(profileID: profile.id).first)
        #expect(loaded.id == thread.id)
        #expect(loaded.title == "Greetings")
        #expect(loaded.messages == [userMessage, assistantMessage])
        #expect(reopened.tutorThreads(profileID: otherProfile.id).isEmpty)

        reopened.deleteProfile(id: profile.id)
        #expect(reopened.tutorThreads(profileID: profile.id).isEmpty)
    }

    private func temporaryDatabase() -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("konishi-language-tests-\(UUID().uuidString)", isDirectory: true)
        return (directory.appendingPathComponent("deck.sqlite"), directory)
    }

    private func createLegacyDatabase(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE profiles (
            id TEXT PRIMARY KEY, targetLocale TEXT NOT NULL, targetName TEXT NOT NULL,
            baseLocale TEXT NOT NULL, baseName TEXT NOT NULL, level TEXT NOT NULL,
            romanization TEXT NOT NULL, scriptNotes TEXT NOT NULL, goals TEXT NOT NULL,
            createdAt REAL NOT NULL
        );
        CREATE TABLE items (
            id TEXT PRIMARY KEY, profileID TEXT NOT NULL, kind TEXT NOT NULL, term TEXT NOT NULL,
            reading TEXT NOT NULL, translation TEXT NOT NULL, partOfSpeech TEXT NOT NULL,
            register TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '', examples TEXT NOT NULL,
            tags TEXT NOT NULL, box INTEGER NOT NULL, dueDate REAL NOT NULL, timesSeen INTEGER NOT NULL,
            timesCorrect INTEGER NOT NULL, timesWrong INTEGER NOT NULL, createdAt REAL NOT NULL,
            lastReviewedAt REAL, sourceConversationID TEXT
        );
        INSERT INTO profiles VALUES (
            '00000000-0000-0000-0000-000000000001', 'ja-JP', 'Japanese', 'en-US', 'English',
            'b1', 'never', 'Kanji', 'Read novels', 1700000000
        );
        INSERT INTO items VALUES (
            '00000000-0000-0000-0000-000000000002',
            '00000000-0000-0000-0000-000000000001', 'vocab', '言葉', 'ことば', 'word', 'noun',
            'neutral', 'legacy note', '["legacy example"]', '["legacy"]', 3, 1800000000,
            4, 3, 1, 1600000000, 1750000000, NULL
        );
        """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            let error = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            throw NSError(domain: "LanguageStoreTests", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw NSError(domain: "LanguageStoreTests", code: 1)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            throw NSError(domain: "LanguageStoreTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    private func userVersion(at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw NSError(domain: "LanguageStoreTests", code: 3)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "LanguageStoreTests", code: 4)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "LanguageStoreTests", code: 5)
        }
        return Int(sqlite3_column_int(statement, 0))
    }
}