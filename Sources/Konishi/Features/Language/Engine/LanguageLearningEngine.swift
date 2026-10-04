import Foundation

enum LanguageLearningEngine {
    static func dueQueue(
        from items: [LearnItem], profileID: UUID, limit: Int, at now: Date = Date()
    ) -> [LearnItem] {
        guard limit > 0 else { return [] }
        return items
            .filter { $0.profileID == profileID && $0.dueDate <= now }
            .sorted {
                if $0.dueDate != $1.dueDate { return $0.dueDate < $1.dueDate }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(limit)
            .map { $0 }
    }

    static func makeSession(
        from items: [LearnItem], profileID: UUID, activity: LanguageActivity,
        direction: LanguageQuestionDirection, count: Int, at now: Date = Date()
    ) -> LanguagePracticeSession {
        let queue = dueQueue(from: items, profileID: profileID, limit: max(0, count), at: now)
        let questions: [LanguageQuestion]
        if activity == .matching {
            questions = matching(from: queue, profileID: profileID, direction: direction, limit: count)
                .map { [$0] } ?? []
        } else {
            questions = queue.compactMap { item in
                switch activity {
                case .flashcards:
                    return flashcard(for: item, direction: direction)
                case .multipleChoice:
                    return multipleChoice(for: item, from: items, direction: direction)
                        ?? typedRecall(for: item, direction: direction)
                case .typedRecall:
                    return typedRecall(for: item, direction: direction)
                case .cloze:
                    return cloze(for: item) ?? typedRecall(for: item, direction: direction)
                case .matching:
                    return nil
                }
            }
        }
        return LanguagePracticeSession(profileID: profileID, activity: activity, questions: questions)
    }

    static func flashcard(
        for item: LearnItem, direction: LanguageQuestionDirection
    ) -> LanguageQuestion? {
        guard let pair = promptAndAnswer(for: item, direction: direction) else { return nil }
        return LanguageQuestion(
            activity: .flashcards, direction: direction, prompt: pair.prompt, itemIDs: [item.id],
            answer: pair.answer, acceptedAnswers: acceptedAnswers(for: item, primary: pair.answer))
    }

    static func multipleChoice(
        for item: LearnItem,
        from candidates: [LearnItem],
        direction: LanguageQuestionDirection
    ) -> LanguageQuestion? {
        guard let pair = promptAndAnswer(for: item, direction: direction) else { return nil }
        let distractors = candidates
            .filter { $0.profileID == item.profileID && $0.id != item.id }
            .compactMap { promptAndAnswer(for: $0, direction: direction)?.answer }
            .filter { normalizeAnswer($0) != normalizeAnswer(pair.answer) }
        var unique: [String] = []
        var seen: Set<String> = [normalizeAnswer(pair.answer)]
        for distractor in distractors where seen.insert(normalizeAnswer(distractor)).inserted {
            unique.append(distractor)
        }
        guard !unique.isEmpty else { return nil }

        var options = ([pair.answer] + Array(unique.prefix(3))).map { LanguageOption(text: $0) }
        options.shuffle()
        guard let correct = options.first(where: { normalizeAnswer($0.text) == normalizeAnswer(pair.answer) }) else {
            return nil
        }
        return LanguageQuestion(
            activity: .multipleChoice, direction: direction, prompt: pair.prompt, itemIDs: [item.id],
            answer: pair.answer, acceptedAnswers: acceptedAnswers(for: item, primary: pair.answer),
            choices: options, correctChoiceID: correct.id)
    }

    static func matching(
        from items: [LearnItem], profileID: UUID, direction: LanguageQuestionDirection, limit: Int = 4
    ) -> LanguageQuestion? {
        guard limit >= 2 else { return nil }
        var uniqueItems: [LearnItem] = []
        var seenTerms: Set<String> = []
        var seenMeanings: Set<String> = []
        for item in items where item.profileID == profileID {
            guard let pair = promptAndAnswer(for: item, direction: direction) else { continue }
            let termKey = normalizeAnswer(direction == .targetToBase ? item.term : item.translation)
            let meaningKey = normalizeAnswer(pair.answer)
            guard seenTerms.insert(termKey).inserted, seenMeanings.insert(meaningKey).inserted else { continue }
            uniqueItems.append(item)
            if uniqueItems.count == limit { break }
        }
        guard uniqueItems.count >= 2 else { return nil }

        let termOptions = uniqueItems.map { item in
            LanguageOption(text: direction == .targetToBase ? item.term : item.translation)
        }.shuffled()
        let meaningOptions = uniqueItems.map { item in
            LanguageOption(text: direction == .targetToBase ? item.translation : item.term)
        }.shuffled()
        let meaningsByItem = Dictionary(uniqueKeysWithValues: zip(uniqueItems.map(\.id), meaningOptions))
        let termsByItem = Dictionary(uniqueKeysWithValues: zip(uniqueItems.map(\.id), termOptions))
        let matches = uniqueItems.compactMap { item -> LanguageMatch? in
            guard let term = termsByItem[item.id], let meaning = meaningsByItem[item.id] else { return nil }
            return LanguageMatch(termOptionID: term.id, meaningOptionID: meaning.id)
        }
        return LanguageQuestion(
            activity: .matching, direction: direction,
            prompt: "Match each term with its meaning.", itemIDs: uniqueItems.map(\.id), answer: "",
            matchTerms: termOptions, matchMeanings: meaningOptions, correctMatches: matches)
    }

    static func typedRecall(
        for item: LearnItem, direction: LanguageQuestionDirection
    ) -> LanguageQuestion? {
        guard let pair = promptAndAnswer(for: item, direction: direction) else { return nil }
        return LanguageQuestion(
            activity: .typedRecall, direction: direction, prompt: pair.prompt, itemIDs: [item.id],
            answer: pair.answer, acceptedAnswers: acceptedAnswers(for: item, primary: pair.answer))
    }

    static func cloze(for item: LearnItem) -> LanguageQuestion? {
        guard !item.term.isEmpty,
              let example = item.examples.first(where: { $0.range(of: item.term) != nil }),
              let range = example.range(of: item.term)
        else { return nil }
        let prompt = example.replacingCharacters(in: range, with: "____")
        return LanguageQuestion(
            activity: .cloze, direction: .targetToBase, prompt: prompt, itemIDs: [item.id],
            answer: item.term, acceptedAnswers: acceptedAnswers(for: item, primary: item.term))
    }

    static func evaluate(_ answer: LanguageAnswer, for question: LanguageQuestion) -> LanguageAnswerResult {
        switch (question.activity, answer) {
        case let (.flashcards, .selfRating(remembered)):
            guard question.itemIDs.count == 1 else { return .invalid }
            return .graded([question.itemIDs[0]: remembered ? .remembered : .again])
        case let (.multipleChoice, .choice(choiceID)):
            guard question.itemIDs.count == 1,
                  question.choices.count >= 2,
                  Set(question.choices.map(\.id)).count == question.choices.count,
                  let correctID = question.correctChoiceID,
                  question.choices.contains(where: { $0.id == correctID }),
                  question.choices.contains(where: { $0.id == choiceID })
            else { return .invalid }
            return .graded([question.itemIDs[0]: choiceID == correctID ? .correct : .incorrect])
        case let (.typedRecall, .text(text)), let (.cloze, .text(text)):
            let expected = question.acceptedAnswers + [question.answer]
            guard question.itemIDs.count == 1,
                  !expected.isEmpty, expected.allSatisfy({ !normalizeAnswer($0).isEmpty })
            else { return .invalid }
            let outcome: LanguageReviewOutcome = expected.contains {
                normalizeAnswer($0) == normalizeAnswer(text)
            } ? .correct : .incorrect
            return .graded([question.itemIDs[0]: outcome])
        case let (.matching, .matches(matches)):
            let termIDs = Set(question.matchTerms.map(\.id))
            let meaningIDs = Set(question.matchMeanings.map(\.id))
            guard question.itemIDs.count >= 2,
                  termIDs.count == question.matchTerms.count,
                  meaningIDs.count == question.matchMeanings.count,
                  question.matchTerms.count == question.matchMeanings.count,
                  question.correctMatches.count == question.itemIDs.count,
                  matches.count == question.itemIDs.count,
                  Set(matches.map(\.termOptionID)).count == matches.count,
                  Set(matches.map(\.meaningOptionID)).count == matches.count,
                  matches.allSatisfy({ termIDs.contains($0.termOptionID) && meaningIDs.contains($0.meaningOptionID) })
            else { return .invalid }
            var outcomes: [UUID: LanguageReviewOutcome] = [:]
            for (itemID, correctPair) in zip(question.itemIDs, question.correctMatches) {
                outcomes[itemID] = matches.contains(correctPair) ? .correct : .incorrect
            }
            return .graded(outcomes)
        default:
            return .invalid
        }
    }

    static func advancing(
        _ session: LanguagePracticeSession, outcomes: [UUID: LanguageReviewOutcome]
    ) -> LanguagePracticeSession? {
        guard !session.isComplete else { return nil }
        guard let question = session.currentQuestion,
              Set(outcomes.keys).isSubset(of: Set(question.itemIDs))
        else { return nil }
        var next = session
        next.appendOutcomes(question.itemIDs.compactMap { outcomes[$0] })
        return next
    }

    static func normalizeAnswer(_ answer: String) -> String {
        answer.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func promptAndAnswer(
        for item: LearnItem, direction: LanguageQuestionDirection
    ) -> (prompt: String, answer: String)? {
        let prompt = direction == .targetToBase ? item.term : item.translation
        let answer = direction == .targetToBase ? item.translation : item.term
        guard !normalizeAnswer(prompt).isEmpty, !normalizeAnswer(answer).isEmpty else { return nil }
        return (prompt, answer)
    }

    private static func acceptedAnswers(for item: LearnItem, primary: String) -> [String] {
        let approvedAlternatives = primary == item.term ? item.acceptedAnswers : []
        return ([primary] + approvedAlternatives)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}