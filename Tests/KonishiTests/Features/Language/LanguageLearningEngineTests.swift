import Foundation
import Testing

@testable import Konishi

@Suite("LanguageLearningEngine")
struct LanguageLearningEngineTests {
    @Test("due queue is profile-scoped, bounded, and stable for equal due dates")
    func dueQueueSelection() {
        let profileID = UUID()
        let otherProfileID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tieDate = now.addingTimeInterval(-100)
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let items = [
            item(id: laterID, profileID: profileID, term: "later", dueDate: tieDate),
            item(profileID: profileID, term: "future", dueDate: now.addingTimeInterval(1)),
            item(profileID: otherProfileID, term: "other", dueDate: tieDate),
            item(id: earlierID, profileID: profileID, term: "earlier", dueDate: tieDate),
        ]

        #expect(LanguageLearningEngine.dueQueue(from: items, profileID: profileID, limit: 1, at: now).map(\.id) == [earlierID])
        #expect(LanguageLearningEngine.dueQueue(from: items, profileID: profileID, limit: 0, at: now).isEmpty)
    }

    @Test("multiple choice excludes same-profile answer collisions and grades by option id")
    func multipleChoiceDistractorsAndGrade() throws {
        let profileID = UUID()
        let target = item(profileID: profileID, term: "猫", translation: "cat")
        let duplicate = item(profileID: profileID, term: "ねこ", translation: "cat")
        let distractor = item(profileID: profileID, term: "犬", translation: "dog")
        let foreign = item(profileID: UUID(), term: "鳥", translation: "cat")

        let question = try #require(LanguageLearningEngine.multipleChoice(
            for: target, from: [target, duplicate, distractor, foreign], direction: .targetToBase))
        #expect(question.choices.map(\.text).sorted() == ["cat", "dog"])
        #expect(LanguageLearningEngine.evaluate(.choice(question.correctChoiceID!), for: question).allCorrect)
        let wrong = try #require(question.choices.first { $0.id != question.correctChoiceID })
        #expect(LanguageLearningEngine.evaluate(.choice(wrong.id), for: question).allCorrect == false)
        #expect(LanguageLearningEngine.evaluate(.choice(UUID()), for: question) == .invalid)
    }

    @Test("multiple choice falls back when there are not enough distinct distractors")
    func multipleChoiceFallback() {
        let profileID = UUID()
        let first = item(profileID: profileID, term: "猫", translation: "cat")
        let ambiguous = item(profileID: profileID, term: "ねこ", translation: "cat")
        #expect(LanguageLearningEngine.multipleChoice(
            for: first, from: [first, ambiguous], direction: .targetToBase) == nil)
    }

    @Test("typed recall uses canonical Unicode, collapsed whitespace, and case folding only")
    func typedRecallNormalization() throws {
        let item = item(profileID: UUID(), term: "café", translation: "coffee")
        let question = try #require(LanguageLearningEngine.typedRecall(for: item, direction: .targetToBase))
        #expect(LanguageLearningEngine.evaluate(.text("  COFFEE  "), for: question).allCorrect)
        #expect(LanguageLearningEngine.normalizeAnswer("cafe\u{301}") == LanguageLearningEngine.normalizeAnswer("café"))
        #expect(LanguageLearningEngine.evaluate(.text("coffee!"), for: question).allCorrect == false)
        #expect(LanguageLearningEngine.evaluate(.text("コーヒー"), for: question).allCorrect == false)
    }

    @Test("learner-approved alternatives apply only when recalling the target term")
    func acceptedAnswersAreDirectionScoped() throws {
        let card = LearnItem(
            profileID: UUID(), kind: .vocab, term: "猫", translation: "cat", acceptedAnswers: ["ねこ"])
        let targetToBase = try #require(LanguageLearningEngine.typedRecall(for: card, direction: .targetToBase))
        let baseToTarget = try #require(LanguageLearningEngine.typedRecall(for: card, direction: .baseToTarget))

        #expect(LanguageLearningEngine.evaluate(.text("ねこ"), for: targetToBase).allCorrect == false)
        #expect(LanguageLearningEngine.evaluate(.text("ねこ"), for: baseToTarget).allCorrect)
    }

    @Test("matching builds unambiguous pairs and grades every known card")
    func matching() throws {
        let profileID = UUID()
        let first = item(profileID: profileID, term: "猫", translation: "cat")
        let second = item(profileID: profileID, term: "犬", translation: "dog")
        let question = try #require(LanguageLearningEngine.matching(
            from: [first, second], profileID: profileID, direction: .targetToBase))
        let allCorrect = LanguageLearningEngine.evaluate(.matches(question.correctMatches), for: question)
        #expect(allCorrect.allCorrect)
        #expect(allCorrect.outcomes?.count == 2)
        #expect(LanguageLearningEngine.evaluate(.matches(Array(question.correctMatches.dropLast())), for: question) == .invalid)
        #expect(LanguageLearningEngine.matching(from: [first], profileID: profileID, direction: .targetToBase) == nil)
    }

    @Test("cloze blanks the first exact example occurrence; absent examples are unavailable")
    func cloze() throws {
        let withExample = item(profileID: UUID(), term: "猫", translation: "cat", examples: ["猫と猫です"])
        let question = try #require(LanguageLearningEngine.cloze(for: withExample))
        #expect(question.prompt == "____と猫です")
        #expect(LanguageLearningEngine.evaluate(.text("猫"), for: question).allCorrect)
        #expect(LanguageLearningEngine.cloze(for: item(profileID: UUID(), term: "cat")) == nil)
    }

    @Test("session advances only after a recorded result and completes at its bound")
    func boundedProgression() throws {
        let profileID = UUID()
        let first = try #require(LanguageLearningEngine.flashcard(
            for: item(profileID: profileID, term: "猫", translation: "cat"), direction: .targetToBase))
        let session = LanguagePracticeSession(profileID: profileID, activity: .flashcards, questions: [first])

        let next = try #require(LanguageLearningEngine.advancing(
            session, outcomes: [first.itemIDs[0]: .remembered]))
        #expect(next.isComplete)
        #expect(next.completedCount == 1)
        #expect(LanguageLearningEngine.advancing(next, outcomes: [:]) == nil)
    }

    private func item(
        id: UUID = UUID(), profileID: UUID, term: String, translation: String = "meaning",
        examples: [String] = [], dueDate: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> LearnItem {
        LearnItem(
            id: id, profileID: profileID, kind: .vocab, term: term, translation: translation,
            examples: examples, dueDate: dueDate)
    }
}