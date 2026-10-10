import Foundation

extension LanguageWorkspaceModel {
    func performTutorTool(_ call: ToolCall, profileID: UUID) -> String {
        guard activeProfile?.id == profileID else {
            return "The active language profile changed; no action was taken."
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let rawArguments = call.function.arguments.isEmpty ? "{}" : call.function.arguments
        guard let data = rawArguments.data(using: .utf8),
              let arguments = try? decoder.decode(LanguageTutorTools.Arguments.self, from: data)
        else { return "The tool arguments were invalid; no action was taken." }

        switch call.function.name {
        case "add_vocabulary":
            return addTutorVocabulary(arguments.items ?? [], profileID: profileID)
        case "language_deck_summary":
            return tutorDeckSummary(profileID: profileID)
        case "language_deck_list":
            return tutorDeckList(arguments, profileID: profileID)
        case "language_deck_search":
            return tutorDeckSearch(arguments, profileID: profileID)
        case "language_due_items":
            return tutorDueItems(limit: arguments.limit ?? 20, profileID: profileID)
        case "language_review_history":
            return tutorReviewHistory(limit: arguments.limit ?? 10, profileID: profileID)
        default:
            return "Unsupported language tutor tool: \(call.function.name ?? "(unnamed)")."
        }
    }

    private func addTutorVocabulary(_ items: [LanguageTutorTools.Arguments.Item], profileID: UUID) -> String {
        let proposals = VocabularyProposal.validatedBatch(items.map { item in
            VocabularyProposal(
                targetTerm: item.targetTerm, translation: item.translation,
                acceptedTranslations: item.acceptedTranslations ?? [], reading: item.reading ?? "",
                partOfSpeech: item.partOfSpeech ?? "", register: item.register ?? "",
                example: item.example ?? "", notes: item.notes ?? "", tags: item.tags ?? [])
        })
        guard !proposals.isEmpty else { return "Nothing was added: no valid vocabulary cards were provided." }

        var added: [String] = []
        var skipped: [String] = []
        for proposal in proposals {
            let item = LearnItem(
                profileID: profileID, kind: .vocab, term: proposal.targetTerm,
                reading: proposal.reading, translation: proposal.translation,
                partOfSpeech: proposal.partOfSpeech, register: proposal.register, notes: proposal.notes,
                examples: proposal.example.isEmpty ? [] : [proposal.example], tags: proposal.tags,
                acceptedTranslations: proposal.acceptedTranslations)
            if let error = saveDeckItem(item) {
                skipped.append("\(proposal.targetTerm): \(error)")
            } else {
                added.append("\(proposal.targetTerm) — \(proposal.translation)")
            }
        }
        let summary = added.isEmpty ? "Added no vocabulary cards." : "Added \(added.count) vocabulary card(s): \(added.joined(separator: "; "))."
        return skipped.isEmpty ? summary : "\(summary) Skipped: \(skipped.joined(separator: "; "))."
    }

    private func tutorDeckSummary(profileID: UUID) -> String {
        guard let profile = activeProfile else { return "No active language profile." }
        let summary = store.deckSummary(profileID: profileID)
        let stats = summary.stats
        let kinds = stats.perKind.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", ")
        let tags = summary.topTags.isEmpty ? "none" : summary.topTags.joined(separator: ", ")
        return "Deck for \(profile.targetName): total=\(stats.total), due=\(stats.due), mastered=\(stats.mastered), reviewed_today=\(stats.reviewedToday). Card types: \(kinds.isEmpty ? "none" : kinds). Common tags: \(tags)."
    }

    private func tutorDeckList(_ arguments: LanguageTutorTools.Arguments, profileID: UUID) -> String {
        let kind: LearnKind?
        if let value = arguments.kind {
            guard let parsed = LearnKind(rawValue: value.lowercased()) else {
                return "Invalid kind. Use vocab, grammar, or phrase."
            }
            kind = parsed
        } else {
            kind = nil
        }
        let allItems = store.items(profileID: profileID, kind: kind)
        let offset = max(0, arguments.offset ?? 0)
        let limit = min(max(arguments.limit ?? 20, 1), 30)
        let page = Array(allItems.dropFirst(offset).prefix(limit))
        return tutorCardList(page, total: allItems.count, offset: offset)
    }

    private func tutorDeckSearch(_ arguments: LanguageTutorTools.Arguments, profileID: UUID) -> String {
        guard let query = arguments.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return "A non-empty query is required."
        }
        let limit = min(max(arguments.limit ?? 20, 1), 30)
        let matches = store.search(profileID: profileID, query: query, limit: limit)
        guard !matches.isEmpty else { return "No deck cards matched \(query)." }
        return "Search results (up to \(limit); more may exist):\n" + matches.map(tutorCardLine).joined(separator: "\n")
    }

    private func tutorDueItems(limit requestedLimit: Int, profileID: UUID) -> String {
        let limit = min(max(requestedLimit, 1), 30)
        let totalDue = store.stats(profileID: profileID).due
        let dueItems = store.dueItems(profileID: profileID, limit: limit)
        guard !dueItems.isEmpty else { return "No cards are currently due for review." }
        return "Due cards (\(dueItems.count) shown; \(totalDue) total):\n" + dueItems.map(tutorCardLine).joined(separator: "\n")
    }

    private func tutorReviewHistory(limit requestedLimit: Int, profileID: UUID) -> String {
        let limit = min(max(requestedLimit, 1), 30)
        let attempts = store.reviewAttempts(profileID: profileID, limit: limit)
        guard !attempts.isEmpty else { return "No review attempts are recorded for this profile." }
        return attempts.map { attempt in
            let term = store.item(id: attempt.itemID)?.term ?? "(card deleted)"
            let answer = attempt.submittedAnswer.map { " | answer: \($0.prefix(120))" } ?? ""
            return "- \(attempt.createdAt.formatted(date: .abbreviated, time: .shortened)): \(term) — \(attempt.outcome.rawValue) (\(attempt.activity.rawValue))\(answer)"
        }.joined(separator: "\n")
    }

    private func tutorCardList(_ items: [LearnItem], total: Int, offset: Int) -> String {
        guard !items.isEmpty else { return "No cards in this deck page. Total matching cards: \(total)." }
        return "Cards (showing \(items.count), offset \(offset), total \(total)):\n" + items.map(tutorCardLine).joined(separator: "\n")
    }

    private func tutorCardLine(_ item: LearnItem) -> String {
        let reading = item.reading.isEmpty ? "" : " (\(item.reading))"
        let due = item.dueDate <= Date()
            ? "due now"
            : "due \(item.dueDate.formatted(date: .abbreviated, time: .omitted))"
        let example = item.examples.first.map { " | example: \($0.prefix(120))" } ?? ""
        return "- [\(item.kind.rawValue)] \(item.term)\(reading) — \(item.translation) | box \(item.box)/\(LearnItem.boxCount) | \(due)\(example)"
    }
}