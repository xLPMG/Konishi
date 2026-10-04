import Foundation
import SQLite3
import Testing

@testable import Konishi

@Suite("LanguageWorkspaceModel")
struct LanguageWorkspaceModelTests {
    @Test("recent progress timestamps use minutes, then hours, then days")
    @MainActor
    func progressTimestampUnits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LanguageProgressTimeFormatter.text(for: now, now: now) == "Just now")
        #expect(LanguageProgressTimeFormatter.text(for: now.addingTimeInterval(-59 * 60), now: now) == "59 minutes ago")
        #expect(LanguageProgressTimeFormatter.text(for: now.addingTimeInterval(-60 * 60), now: now) == "1 hour ago")
        #expect(LanguageProgressTimeFormatter.text(for: now.addingTimeInterval(-23 * 60 * 60), now: now) == "23 hours ago")
        #expect(LanguageProgressTimeFormatter.text(for: now.addingTimeInterval(-24 * 60 * 60), now: now) == "1 day ago")
        #expect(LanguageProgressTimeFormatter.text(for: now.addingTimeInterval(-400 * 24 * 60 * 60), now: now) == "400 days ago")
    }

    @Test("skip advances without writing an attempt or changing the schedule")
    @MainActor
    func skipDoesNotReview() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        let card = makeCard(profileID: profile.id, term: "猫", translation: "cat")
        store.upsertProfile(profile)
        store.upsert(card)
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: profile.id.uuidString)
        workspace.selectedActivity = .flashcards
        workspace.sessionLength = 1

        workspace.startPractice()
        workspace.skipQuestion()

        #expect(workspace.practiceSession?.isComplete == true)
        #expect(workspace.practiceSession?.outcomes.isEmpty == true)
        #expect(store.reviewAttempts(profileID: profile.id).isEmpty)
        #expect(store.item(id: card.id)?.timesSeen == 0)
        #expect(store.item(id: card.id)?.box == 1)
    }

    @Test("a session advances only after its review is persisted")
    @MainActor
    func savedReviewAdvancesAfterContinue() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        let card = makeCard(profileID: profile.id, term: "猫", translation: "cat")
        store.upsertProfile(profile)
        store.upsert(card)
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: profile.id.uuidString)
        workspace.selectedActivity = .flashcards
        workspace.sessionLength = 1

        workspace.startPractice()
        workspace.revealFlashcard()
        workspace.submitAnswer(.selfRating(remembered: true))

        #expect(workspace.answerRecorded)
        #expect(workspace.practiceSession?.completedCount == 0)
        #expect(store.item(id: card.id)?.timesSeen == 1)
        #expect(store.reviewAttempts(profileID: profile.id).count == 1)

        workspace.continuePractice()
        #expect(workspace.practiceSession?.isComplete == true)
        #expect(workspace.practiceSession?.outcomes == [.remembered])
    }

    @Test("failed writes block progress and retry the same attempt exactly once")
    @MainActor
    func failedWriteCanRetry() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        let card = makeCard(profileID: profile.id, term: "猫", translation: "cat")
        store.upsertProfile(profile)
        store.upsert(card)
        try executeSQL("""
            CREATE TRIGGER reject_language_review BEFORE UPDATE ON items
            BEGIN SELECT RAISE(ABORT, 'temporary write failure'); END;
            """, at: directory.appendingPathComponent("deck.sqlite"))
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: profile.id.uuidString)
        workspace.selectedActivity = .flashcards
        workspace.sessionLength = 1

        workspace.startPractice()
        workspace.revealFlashcard()
        workspace.submitAnswer(.selfRating(remembered: true))
        #expect(!workspace.answerRecorded)
        #expect(workspace.practiceSession?.completedCount == 0)
        #expect(workspace.reviewError != nil)
        #expect(store.reviewAttempts(profileID: profile.id).isEmpty)

        try executeSQL("DROP TRIGGER reject_language_review;", at: directory.appendingPathComponent("deck.sqlite"))
        workspace.submitAnswer(.selfRating(remembered: true))
        #expect(workspace.answerRecorded)
        #expect(store.item(id: card.id)?.timesSeen == 1)
        #expect(store.reviewAttempts(profileID: profile.id).count == 1)
    }

    @Test("matching persists the result for each card")
    @MainActor
    func matchingRecordsEveryCard() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        let first = makeCard(profileID: profile.id, term: "猫", translation: "cat")
        let second = makeCard(profileID: profile.id, term: "犬", translation: "dog")
        store.upsertProfile(profile)
        store.upsert(first)
        store.upsert(second)
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: profile.id.uuidString)
        workspace.selectedActivity = .matching
        workspace.sessionLength = 2

        workspace.startPractice()
        let question = try #require(workspace.practiceSession?.currentQuestion)
        workspace.submitAnswer(.matches(question.correctMatches))

        #expect(workspace.answerRecorded)
        #expect(workspace.recordedAttemptCount == 2)
        #expect(workspace.recordedCorrectCount == 2)
        #expect(store.reviewAttempts(profileID: profile.id).count == 2)
    }

    @Test("I don't know records an incorrect multiple-choice review")
    @MainActor
    func dontKnowRecordsIncorrectAttempt() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        let first = makeCard(profileID: profile.id, term: "猫", translation: "cat")
        let second = makeCard(profileID: profile.id, term: "犬", translation: "dog")
        let third = makeCard(profileID: profile.id, term: "鳥", translation: "bird")
        store.upsertProfile(profile)
        store.upsert(first)
        store.upsert(second)
        store.upsert(third)
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: profile.id.uuidString)
        workspace.selectedActivity = .multipleChoice
        workspace.sessionLength = 1

        workspace.startPractice()
        workspace.submitAnswer(.dontKnow)

        let attempt = try #require(store.reviewAttempts(profileID: profile.id).first)
        #expect(attempt.outcome == .incorrect)
        #expect(attempt.submittedAnswer == "I don't know")
        #expect(workspace.answerRecorded)
    }

    @Test("vocabulary proposals do not write until learner approval")
    @MainActor
    func proposalRequiresApproval() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        store.upsertProfile(profile)
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: profile.id.uuidString)
        let proposal = VocabularyProposal(
            targetTerm: "学校", translation: "school", reading: "がっこう",
            partOfSpeech: "noun", example: "学校へ行きます", tags: ["places"])
        workspace.studyProposals = [proposal]

        #expect(store.items(profileID: profile.id).isEmpty)
        #expect(!workspace.isDuplicateProposal(proposal))
        #expect(workspace.saveProposal(proposal))
        #expect(workspace.studyProposals.isEmpty)
        #expect(store.findByTerm(profileID: profile.id, kind: .vocab, term: "学校")?.translation == "school")
        #expect(workspace.isDuplicateProposal(proposal))
        #expect(!workspace.saveProposal(proposal))
        #expect(store.items(profileID: profile.id).count == 1)
    }

    @Test("learner-approved alternate answers persist and grade target-term recall")
    @MainActor
    func acceptedAnswerRoundTrip() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        let card = makeCard(profileID: profile.id, term: "猫", translation: "cat")
        store.upsertProfile(profile)
        store.upsert(card)
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: profile.id.uuidString)

        #expect(workspace.saveAcceptedAnswers(for: card.id, values: ["ねこ", " ねこ ", "猫", ""]))
        #expect(store.item(id: card.id)?.acceptedAnswers == ["ねこ"])

        workspace.selectedActivity = .typedRecall
        workspace.questionDirection = .baseToTarget
        workspace.sessionLength = 1
        workspace.startPractice()
        workspace.submitAnswer(.text("ねこ"))

        #expect(workspace.answerRecorded)
        #expect(store.item(id: card.id)?.timesCorrect == 1)
    }

    @Test("profile switching clears transient proposals and reloads only that profile's tutor threads")
    @MainActor
    func profileSwitchIsolatesWorkspaceState() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstProfile = makeProfile()
        let secondProfile = LanguageProfile(targetLocale: "ko-KR", targetName: "Korean")
        store.upsertProfile(firstProfile)
        store.upsertProfile(secondProfile)
        let firstThread = try #require(store.createTutorThread(profileID: firstProfile.id))
        let secondThread = try #require(store.createTutorThread(profileID: secondProfile.id))
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: firstProfile.id.uuidString)
        workspace.studyProposals = [VocabularyProposal(targetTerm: "学校", translation: "school")]
        workspace.proposalTopic = "travel"

        workspace.selectProfile(secondProfile.id)

        #expect(workspace.activeProfile?.id == secondProfile.id)
        #expect(workspace.studyProposals.isEmpty)
        #expect(workspace.proposalTopic.isEmpty)
        #expect(workspace.tutorThreads.map(\.id) == [secondThread.id])
        #expect(workspace.tutorThreads.first?.id != firstThread.id)
    }

    @MainActor
    private func makeStore() throws -> (LanguageStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("language-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (LanguageStore(databaseURL: directory.appendingPathComponent("deck.sqlite")), directory)
    }

    private func makeProfile() -> LanguageProfile {
        LanguageProfile(targetLocale: "ja-JP", targetName: "Japanese")
    }

    private func makeCard(profileID: UUID, term: String, translation: String) -> LearnItem {
        LearnItem(
            profileID: profileID, kind: .vocab, term: term, translation: translation,
            dueDate: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw NSError(domain: "LanguageWorkspaceModelTests", code: 1)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            throw NSError(domain: "LanguageWorkspaceModelTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }
}