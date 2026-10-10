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

    @Test("Tutor context estimate includes the unsent draft")
    @MainActor
    func tutorContextEstimateIncludesDraft() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        store.upsertProfile(profile)
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: profile.id.uuidString)
        let emptyEstimate = workspace.tutorContextEstimate

        workspace.tutorDraft = String(repeating: "猫", count: 400)

        #expect(workspace.tutorContextEstimate > emptyEstimate)
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

    @Test("pausing and resuming preserves the answered question without recording it twice")
    @MainActor
    func pausedReviewResumes() throws {
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
        let questionID = workspace.practiceSession?.currentQuestion?.id

        workspace.pausePractice()
        #expect(workspace.destination == .practice)
        #expect(workspace.canResumePractice)
        workspace.resumePractice()

        #expect(workspace.destination == .session)
        #expect(workspace.practiceSession?.currentQuestion?.id == questionID)
        #expect(workspace.answerRecorded)
        #expect(store.reviewAttempts(profileID: profile.id).count == 1)
        workspace.continuePractice()
        #expect(workspace.practiceSession?.isComplete == true)
        #expect(store.reviewAttempts(profileID: profile.id).count == 1)
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
            targetTerm: "学校", translation: "school", acceptedTranslations: ["school building", "academy"],
            reading: "がっこう",
            partOfSpeech: "noun", example: "学校へ行きます", tags: ["places"])
        workspace.studyProposals = [proposal]

        #expect(store.items(profileID: profile.id).isEmpty)
        #expect(!workspace.isDuplicateProposal(proposal))
        #expect(workspace.saveProposal(proposal))
        #expect(workspace.studyProposals.isEmpty)
        let savedItem = try #require(store.findByTerm(profileID: profile.id, kind: .vocab, term: "学校"))
        #expect(savedItem.translation == "school")
        #expect(savedItem.acceptedTranslations == ["school building", "academy"])
        #expect(workspace.isDuplicateProposal(proposal))
        #expect(!workspace.saveProposal(proposal))
        #expect(store.items(profileID: profile.id).count == 1)
    }

    @Test("tutor add_vocabulary tool saves cards and reports duplicates")
    @MainActor
    func tutorCanAddVocabulary() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        store.upsertProfile(profile)
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: profile.id.uuidString)
        let call = ToolCall(
            id: "call-1", type: "function",
            function: FunctionCall(
                name: "add_vocabulary",
                arguments: #"{"items":[{"target_term":"学校","translation":"school","reading":"がっこう","accepted_translations":["school building"]}]}"#))

        let result = workspace.performTutorTool(call, profileID: profile.id)

        let saved = try #require(store.findByTerm(profileID: profile.id, kind: .vocab, term: "学校"))
        #expect(saved.translation == "school")
        #expect(saved.reading == "がっこう")
        #expect(saved.acceptedTranslations == ["school building"])
        #expect(result.contains("Added 1 vocabulary card"))
        #expect(workspace.deckRevision == 1)

        let duplicateResult = workspace.performTutorTool(call, profileID: profile.id)
        #expect(duplicateResult.contains("Skipped"))
        #expect(store.items(profileID: profile.id).count == 1)
    }

    @Test("tutor read tools expose deck cards, due queue, summary, and review history")
    @MainActor
    func tutorCanReadDeckAndReviews() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        let dueCard = LearnItem(
            profileID: profile.id, kind: .vocab, term: "猫", reading: "ねこ", translation: "cat",
            dueDate: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_600_000_000))
        let futureCard = LearnItem(
            profileID: profile.id, kind: .phrase, term: "またね", translation: "see you",
            dueDate: Date(timeIntervalSince1970: 2_000_000_000),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        store.upsertProfile(profile)
        store.upsert(dueCard)
        store.upsert(futureCard)
        let attempt = LanguageReviewAttempt(
            profileID: profile.id, itemID: dueCard.id, activity: .typedRecall, outcome: .correct,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), submittedAnswer: "cat")
        guard case .recorded = store.recordReview(attempt) else {
            Issue.record("Could not seed review history for the tutor tool test.")
            return
        }
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: profile.id.uuidString)

        let summary = workspace.performTutorTool(tutorCall("language_deck_summary"), profileID: profile.id)
        let page = workspace.performTutorTool(
            tutorCall("language_deck_list", #"{"limit":1,"offset":1}"#), profileID: profile.id)
        let search = workspace.performTutorTool(
            tutorCall("language_deck_search", #"{"query":"ねこ"}"#), profileID: profile.id)
        let due = workspace.performTutorTool(tutorCall("language_due_items"), profileID: profile.id)
        let history = workspace.performTutorTool(tutorCall("language_review_history"), profileID: profile.id)

        #expect(summary.contains("total=2"))
        #expect(summary.contains("due=1"))
        #expect(page.contains("猫"))
        #expect(search.contains("cat"))
        #expect(due.contains("猫"))
        #expect(!due.contains("またね"))
        #expect(history.contains("猫 — correct"))
        #expect(history.contains("answer: cat"))
    }

    @Test("manual card creation and editing preserve scheduling and reject duplicate terms")
    @MainActor
    func manualCardSave() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        store.upsertProfile(profile)
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: profile.id.uuidString)
        let dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        let card = LearnItem(
            profileID: profile.id, kind: .vocab, term: "  猫  ", translation: "  cat  ",
            acceptedTranslations: ["kitty", " kitty "], box: 3, dueDate: dueDate,
            timesSeen: 4, timesCorrect: 3, timesWrong: 1)

        #expect(workspace.saveDeckItem(card) == nil)
        var saved = try #require(store.item(id: card.id))
        #expect(saved.term == "猫")
        #expect(saved.translation == "cat")
        #expect(saved.acceptedTranslations == ["kitty"])

        saved.translation = "feline"
        saved.examples = ["猫がいます"]
        #expect(workspace.saveDeckItem(saved) == nil)
        let edited = try #require(store.item(id: card.id))
        #expect(edited.translation == "feline")
        #expect(edited.examples == ["猫がいます"])
        #expect(edited.box == 3)
        #expect(edited.dueDate == dueDate)
        #expect(edited.timesSeen == 4)

        let duplicate = LearnItem(profileID: profile.id, kind: .vocab, term: "猫", translation: "cat")
        #expect(workspace.saveDeckItem(duplicate) != nil)
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

    @Test("accepted translation alternatives persist and grade translation recall")
    @MainActor
    func acceptedTranslationRoundTrip() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        let card = makeCard(profileID: profile.id, term: "움직이다", translation: "to move")
        store.upsertProfile(profile)
        store.upsert(card)
        let workspace = LanguageWorkspaceModel(store: store, activeProfileID: profile.id.uuidString)

        #expect(workspace.saveAcceptedTranslations(
            for: card.id, values: ["to be moving", " TO MOVE ", "to shift"]))
        #expect(store.item(id: card.id)?.acceptedTranslations == ["to be moving", "to shift"])

        workspace.selectedActivity = .typedRecall
        workspace.questionDirection = .targetToBase
        workspace.sessionLength = 1
        workspace.startPractice()
        workspace.submitAnswer(.text("to be moving"))

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

    private func tutorCall(_ name: String, _ arguments: String = "{}") -> ToolCall {
        ToolCall(id: "call-\(name)", type: "function",
                 function: FunctionCall(name: name, arguments: arguments))
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