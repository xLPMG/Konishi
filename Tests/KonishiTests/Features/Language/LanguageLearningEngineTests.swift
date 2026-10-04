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
        #expect(LanguageLearningEngine.evaluate(.dontKnow, for: question).outcomes?[target.id] == .incorrect)
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
        #expect(LanguageLearningEngine.evaluate(.dontKnow, for: question).outcomes?[item.id] == .incorrect)
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
        let items = [first, second]

        for direction in LanguageQuestionDirection.allCases {
            let question = try #require(LanguageLearningEngine.matching(
                from: items, profileID: profileID, direction: direction))
            let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

            for (itemID, correctMatch) in zip(question.itemIDs, question.correctMatches) {
                let item = try #require(itemByID[itemID])
                let term = try #require(question.matchTerms.first { $0.id == correctMatch.termOptionID })
                let meaning = try #require(question.matchMeanings.first { $0.id == correctMatch.meaningOptionID })
                #expect(term.text == (direction == .targetToBase ? item.term : item.translation))
                #expect(meaning.text == (direction == .targetToBase ? item.translation : item.term))
            }

            let allCorrect = LanguageLearningEngine.evaluate(.matches(question.correctMatches), for: question)
            #expect(allCorrect.allCorrect)
            #expect(allCorrect.outcomes?.count == 2)
            #expect(LanguageLearningEngine.evaluate(.matches(Array(question.correctMatches.dropLast())), for: question) == .invalid)
        }

        #expect(LanguageLearningEngine.matching(from: [first], profileID: profileID, direction: .targetToBase) == nil)
    }

    @Test("cloze blanks the first exact example occurrence; absent examples are unavailable")
    func cloze() throws {
        let withExample = item(profileID: UUID(), term: "猫", translation: "cat", examples: ["猫と猫です"])
        let question = try #require(LanguageLearningEngine.cloze(for: withExample))
        #expect(question.prompt == "____と猫です")
        #expect(LanguageLearningEngine.evaluate(.text("猫"), for: question).allCorrect)
        #expect(LanguageLearningEngine.evaluate(.dontKnow, for: question).outcomes?[withExample.id] == .incorrect)
        #expect(LanguageLearningEngine.cloze(for: item(profileID: UUID(), term: "cat")) == nil)
    }

    @Test("mixed review includes each available activity and both directions")
    func mixedReview() throws {
        let profileID = UUID()
        let cards = (0..<30).map { index in
            let term = "term\(index)"
            return item(
                profileID: profileID, term: term, translation: "meaning\(index)",
                examples: ["I used \(term) today"])
        }

        let session = LanguageLearningEngine.makeSession(
            from: cards, profileID: profileID, activity: .mixedReview,
            direction: .targetToBase, count: cards.count, at: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(Set(session.questions.map(\.activity)) == Set([
            .flashcards, .multipleChoice, .matching, .typedRecall, .cloze,
        ]))
        #expect(session.questions.contains { $0.direction == .targetToBase })
        #expect(session.questions.contains { $0.direction == .baseToTarget })
        let reviewedIDs = session.questions.flatMap(\.itemIDs)
        #expect(reviewedIDs.count == cards.count)
        #expect(Set(reviewedIDs).count == cards.count)
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