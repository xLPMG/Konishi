import Foundation

extension AppModel {
    /// The active language profile, or the first one if the stored id is stale/empty.
    var activeLanguageProfile: LanguageProfile? {
        if let id = UUID(uuidString: settings.activeLanguageProfileID),
            let p = languageProfiles.first(where: { $0.id == id })
        {
            return p
        }
        return languageProfiles.first
    }

    func reloadLanguageProfiles() {
        languageProfiles = languageStore.allProfiles()
    }

    func saveLanguageProfile(_ profile: LanguageProfile, makeActive: Bool = false) {
        languageStore.upsertProfile(profile)
        reloadLanguageProfiles()
        if makeActive || settings.activeLanguageProfileID.isEmpty {
            settings.activeLanguageProfileID = profile.id.uuidString
        }
    }

    func deleteLanguageProfile(_ id: UUID) {
        languageStore.deleteProfile(id: id)
        reloadLanguageProfiles()
        if settings.activeLanguageProfileID == id.uuidString {
            settings.activeLanguageProfileID = languageProfiles.first?.id.uuidString ?? ""
        }
    }

    func setActiveLanguageProfile(_ id: UUID) {
        settings.activeLanguageProfileID = id.uuidString
    }

    /// System prompt for language mode: pedagogy + profile + session config.
    /// (Deck/tool instructions are appended once the language tools land.)
    func languageSystemPrompt(persona: Persona) -> String {
        var lines: [String] = []
        if let name = persona.assistantName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            lines.append("Your name is \(name).")
        }
        lines.append(PersonaStore.contextSourceInstruction)

        guard let p = activeLanguageProfile else {
            lines.append(
                "You are a friendly, patient language tutor. No language profile is set up yet — ask the user which language they want to learn, their native language, and their rough level, then help them get started."
            )
            if settings.injectDateContext {
                lines.append("For context, it is currently \(DateContext.current()).")
            }
            return lines.joined(separator: "\n\n")
        }

        let level = languageSession.difficulty ?? p.level
        lines.append(
            "You are a friendly, patient language tutor helping the user learn \(p.targetName). Give explanations in \(p.baseName)."
        )
        lines.append(
            "The user's self-rated level is \(level.code) (\(level.label)). Calibrate to it when the deck is sparse, but rely on what the user already knows (their deck) and their accuracy as the primary guide."
        )
        lines.append(p.romanization.guidance)
        if !p.scriptNotes.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Script notes: \(p.scriptNotes.trimmingCharacters(in: .whitespaces)).")
        }
        if !p.goals.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("The user's goals: \(p.goals.trimmingCharacters(in: .whitespaces)).")
        }
        lines.append(
            "Register: use a natural, appropriate register — you may choose it freely. Do not drill turning formal grammar into informal; the user finds that trivial. When a specific word is inherently formal, honorific, casual, or slang, mention it briefly."
        )

        let topic = languageSession.topic.trimmingCharacters(in: .whitespaces)
        lines.append(languageSession.kind.guidance)
        lines.append("Topic: \(topic.isEmpty ? "the user's choice" : topic).")
        lines.append(
            "You maintain a spaced-repetition deck of the words, grammar points, and phrases the user has learned."
        )

        if settings.injectDateContext {
            lines.append("For context, it is currently \(DateContext.current()).")
        }
        return lines.joined(separator: "\n\n")
    }

    /// Applies a Leitner review to a card and returns a short status for the model.
    func recordDeckReview(itemID: UUID, correct: Bool) -> String {
        guard var item = languageStore.item(id: itemID) else { return "Error: card not found" }
        item.recordReview(correct: correct)
        languageStore.upsert(item)
        languageDeckRevision &+= 1
        return
            "\(item.term): \(correct ? "correct" : "wrong"), now box \(item.box)/\(LearnItem.boxCount), due \(Self.dueString(item.dueDate))."
    }

    /// Adds a card to the active profile's deck (used by the add_vocab/add_grammar tools).
    func addDeckCard(_ item: LearnItem) {
        languageStore.upsert(item)
        languageDeckRevision &+= 1
    }

    /// Deletes a card from the deck.
    func deleteDeckItem(_ id: UUID) {
        languageStore.delete(id: id)
        languageDeckRevision &+= 1
    }

    /// Keep the selected conversation consistent with the current mode's sidebar list.
    func syncSelectionToMode() {
        let wantLanguage = (mode == .language)
        if let sel = selectedConversation, (sel.isLanguage == true) == wantLanguage { return }
        if let match = conversations.first(where: { ($0.isLanguage == true) == wantLanguage }) {
            selectedConversationID = match.id
        } else {
            newConversation()
        }
    }

    func isLanguageConversation(_ id: UUID) -> Bool {
        conversations.first(where: { $0.id == id })?.isLanguage == true
    }

    func languageDeckContext() -> String {
        guard let p = activeLanguageProfile else { return "" }
        let key = "\(p.id.uuidString)#\(languageDeckRevision)"
        if let c = deckContextCache, c.key == key { return c.text }
        let (s, tags) = languageStore.deckSummary(profileID: p.id)
        let text: String
        if s.total == 0 {
            text = "# Learner's deck\nThe deck is empty — introduce and bank new words and grammar."
        } else {
            var head = "\(s.total) cards"
            let kinds = LearnKind.allCases.compactMap { k -> String? in
                let n = s.perKind[k] ?? 0
                return n > 0 ? "\(n) \(k.rawValue)" : nil
            }
            if !kinds.isEmpty { head += " (\(kinds.joined(separator: ", ")))" }
            var line = "\(head); \(s.due) due for review; \(s.mastered) mastered."
            if !tags.isEmpty { line += " Topics: \(tags.joined(separator: ", "))." }
            text = "# Learner's deck\n" + line
        }
        deckContextCache = (key, text)
        return text
    }

    /// Called by the multiple-choice UI when the user finishes answering. Grades card-linked
    /// questions deterministically, records those reviews, and resumes the paused turn.
    func submitInteraction(_ choices: [Int]) {
        guard let pending = pendingInteraction else { return }
        var lines: [String] = []
        for (i, q) in pending.questions.enumerated() {
            let choice = i < choices.count ? choices[i] : -1
            let chosen =
                (choice >= 0 && choice < q.options.count) ? q.options[choice] : "(no answer)"
            var line = "Q: \(q.prompt)\nA: \(chosen)"
            if let ci = q.correctIndex {
                let correct = choice == ci
                let answer = (ci >= 0 && ci < q.options.count) ? q.options[ci] : "?"
                line += correct ? " (correct)" : " (incorrect; correct answer: \(answer))"
                if let itemID = q.itemID { _ = recordDeckReview(itemID: itemID, correct: correct) }
            }
            lines.append(line)
        }
        pendingInteraction = nil
        let cont = interactionContinuation
        interactionContinuation = nil
        cont?.resume(returning: lines.joined(separator: "\n\n"))
    }

    /// User dismissed the questions without answering — resume the turn with a note.
    func cancelInteraction() {
        guard interactionContinuation != nil else { return }
        pendingInteraction = nil
        let cont = interactionContinuation
        interactionContinuation = nil
        cont?.resume(returning: "User dismissed the questions without answering.")
    }

    static func parseMCQuestions(_ raw: [ToolArguments.MultipleChoice.Question]) -> [MCQuestion] {
        raw.compactMap { question in
            guard !question.prompt.isEmpty, !question.options.isEmpty else { return nil }
            return MCQuestion(
                id: UUID(), prompt: question.prompt, options: question.options,
                correctIndex: question.correctIndex, itemID: question.itemID
            )
        }
    }

    private static func dueString(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "tomorrow" }
        return "in \(days) days"
    }
}
