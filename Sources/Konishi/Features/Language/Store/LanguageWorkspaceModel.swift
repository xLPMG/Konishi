import Foundation
import Observation

enum LanguageWorkspaceDestination: String, CaseIterable, Hashable, Identifiable, Sendable {
    case home
    case practice
    case session
    case study
    case deck
    case tutor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: "Home"
        case .practice: "Review"
        case .session: "Practice session"
        case .study: "Study"
        case .deck: "Deck"
        case .tutor: "Tutor"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .practice: "checkmark.circle"
        case .session: "rectangle.stack"
        case .study: "books.vertical"
        case .deck: "rectangle.stack"
        case .tutor: "bubble.left.and.bubble.right"
        }
    }
}

@Observable
@MainActor
final class LanguageWorkspaceModel {
    let store: LanguageStore
    private(set) var profiles: [LanguageProfile]
    private(set) var activeProfileID: UUID?
    var destination: LanguageWorkspaceDestination = .home
    private(set) var deckRevision = 0
    var selectedActivity: LanguageActivity = .mixedReview
    var questionDirection: LanguageQuestionDirection = .targetToBase
    var sessionLength = 10
    private(set) var practiceSession: LanguagePracticeSession?
    private(set) var answerResult: LanguageAnswerResult?
    private(set) var answerRecorded = false
    private(set) var reviewError: String?
    private(set) var recordedAttemptCount = 0
    private(set) var recordedCorrectCount = 0
    private(set) var isFlashcardRevealed = false
    private var pendingAttemptIDs: [UUID: UUID] = [:]
    var studyProposals: [VocabularyProposal] = []
    var proposalTopic = ""
    var isGeneratingProposals = false
    private(set) var proposalError: String?
    @ObservationIgnored private var proposalTask: Task<Void, Never>?
    private(set) var tutorThreads: [LanguageTutorThread] = []
    private(set) var selectedTutorThreadID: UUID?
    var tutorDraft = ""
    private(set) var tutorStreamedReply = ""
    private(set) var isTutorStreaming = false
    private(set) var tutorError: String?
    private(set) var failedTutorMessageID: UUID?
    @ObservationIgnored private var tutorTask: Task<Void, Never>?
    var onProfileChange: ((UUID?) -> Void)?

    init(store: LanguageStore, activeProfileID: String) {
        self.store = store
        self.profiles = store.allProfiles()
        let requestedID = UUID(uuidString: activeProfileID)
        self.activeProfileID = profiles.contains(where: { $0.id == requestedID }) ? requestedID : profiles.first?.id
        if let profileID = self.activeProfileID {
            self.tutorThreads = store.tutorThreads(profileID: profileID)
            self.selectedTutorThreadID = tutorThreads.first?.id
        }
    }

    var activeProfile: LanguageProfile? {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first
    }

    var activeStats: LanguageStore.Stats {
        activeProfile.map { store.stats(profileID: $0.id) } ?? .init()
    }

    var canSkipCurrentQuestion: Bool {
        !answerRecorded && pendingAttemptIDs.isEmpty
    }

    var canResumePractice: Bool {
        practiceSession.map { !$0.isComplete } == true
    }

    func refresh() {
        profiles = store.allProfiles()
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            resetProfileScopedState()
            activeProfileID = profiles.first?.id
            onProfileChange?(activeProfileID)
        }
        refreshTutorThreads()
    }

    func selectProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }), activeProfileID != id else { return }
        resetProfileScopedState()
        activeProfileID = id
        onProfileChange?(id)
        refreshTutorThreads()
    }

    func saveProfile(_ profile: LanguageProfile, makeActive: Bool = false) {
        store.upsertProfile(profile)
        profiles = store.allProfiles()
        if makeActive || activeProfileID == nil {
            resetProfileScopedState()
            activeProfileID = profile.id
            onProfileChange?(profile.id)
            refreshTutorThreads()
        }
    }

    func deleteProfile(_ id: UUID) {
        store.deleteProfile(id: id)
        profiles = store.allProfiles()
        if activeProfileID == id {
            resetProfileScopedState()
            activeProfileID = profiles.first?.id
            onProfileChange?(activeProfileID)
            refreshTutorThreads()
        }
        notifyDeckChanged()
    }

    func deleteDeckItem(_ id: UUID) {
        store.delete(id: id)
        notifyDeckChanged()
    }

    @discardableResult
    func saveDeckItem(_ item: LearnItem) -> String? {
        guard let profile = activeProfile else { return "Set up a language profile first." }
        guard item.profileID == profile.id else { return "This card belongs to another language profile." }

        var cleaned = item
        func clean(_ value: String) -> String {
            value.precomposedStringWithCanonicalMapping
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
        cleaned.term = clean(item.term)
        cleaned.translation = clean(item.translation)
        guard !cleaned.term.isEmpty, !cleaned.translation.isEmpty else {
            return "A term and translation are required."
        }

        func alternatives(_ values: [String], primary: String) -> [String] {
            var seen: Set<String> = [LanguageLearningEngine.normalizeAnswer(primary)]
            return values.compactMap { value in
                let answer = clean(value)
                let key = LanguageLearningEngine.normalizeAnswer(answer)
                guard !key.isEmpty, seen.insert(key).inserted else { return nil }
                return answer
            }
        }
        cleaned.reading = clean(item.reading)
        cleaned.partOfSpeech = clean(item.partOfSpeech)
        cleaned.register = clean(item.register)
        cleaned.notes = clean(item.notes)
        cleaned.examples = item.examples.map(clean).filter { !$0.isEmpty }
        cleaned.tags = Array(Set(item.tags.map(clean).filter { !$0.isEmpty })).sorted()
        if cleaned.kind == .vocab {
            cleaned.acceptedAnswers = alternatives(item.acceptedAnswers, primary: cleaned.term)
            cleaned.acceptedTranslations = alternatives(item.acceptedTranslations, primary: cleaned.translation)
        } else {
            cleaned.acceptedAnswers = []
            cleaned.acceptedTranslations = []
        }

        let normalizedTerm = LanguageLearningEngine.normalizeAnswer(cleaned.term)
        let duplicate = store.items(profileID: profile.id, kind: cleaned.kind).contains {
            $0.id != cleaned.id && LanguageLearningEngine.normalizeAnswer($0.term) == normalizedTerm
        }
        guard !duplicate else { return "A card with this term already exists in this profile." }
        guard store.upsert(cleaned) else { return "Could not save this card." }
        notifyDeckChanged()
        return nil
    }

    @discardableResult
    func saveAcceptedAnswers(for itemID: UUID, values: [String]) -> Bool {
        guard let profileID = activeProfile?.id,
              var item = store.item(id: itemID),
              item.profileID == profileID, item.kind == .vocab
        else { return false }
        var seen: Set<String> = [LanguageLearningEngine.normalizeAnswer(item.term)]
        item.acceptedAnswers = values.compactMap { value in
            let answer = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            let key = LanguageLearningEngine.normalizeAnswer(answer)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return answer
        }
        guard store.upsert(item) else { return false }
        notifyDeckChanged()
        return true
    }

    @discardableResult
    func saveAcceptedTranslations(for itemID: UUID, values: [String]) -> Bool {
        guard let profileID = activeProfile?.id,
              var item = store.item(id: itemID),
              item.profileID == profileID, item.kind == .vocab
        else { return false }
        var seen: Set<String> = [LanguageLearningEngine.normalizeAnswer(item.translation)]
        item.acceptedTranslations = values.compactMap { value in
            let answer = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            let key = LanguageLearningEngine.normalizeAnswer(answer)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return answer
        }
        guard store.upsert(item) else { return false }
        notifyDeckChanged()
        return true
    }

    func startPractice() {
        guard let profile = activeProfile else {
            reviewError = "Set up a language profile first."
            return
        }
        guard store.initializationError == nil else {
            reviewError = store.initializationError
            return
        }
        let count = selectedActivity == .matching
            ? min(4, max(2, sessionLength))
            : min(30, max(1, sessionLength))
        let cards = store.items(profileID: profile.id)
        let session = LanguageLearningEngine.makeSession(
            from: cards, profileID: profile.id, activity: selectedActivity,
            direction: questionDirection, count: count)
        guard !session.questions.isEmpty else {
            reviewError = selectedActivity == .matching
                ? "At least two distinct due cards are needed for matching."
                : "There are no compatible cards due for review."
            return
        }
        practiceSession = session
        answerResult = nil
        answerRecorded = false
        reviewError = nil
        recordedAttemptCount = 0
        recordedCorrectCount = 0
        isFlashcardRevealed = false
        pendingAttemptIDs.removeAll()
        destination = .session
    }

    func revealFlashcard() {
        guard practiceSession?.currentQuestion?.activity == .flashcards else { return }
        isFlashcardRevealed = true
    }

    func submitAnswer(_ answer: LanguageAnswer) {
        guard let session = practiceSession,
              let question = session.currentQuestion,
              !answerRecorded
        else { return }
        let result = LanguageLearningEngine.evaluate(answer, for: question)
        guard let outcomes = result.outcomes,
              Set(outcomes.keys) == Set(question.itemIDs)
        else {
            reviewError = "That answer could not be checked. Please try again."
            return
        }

        var persistedAny = false
        for itemID in question.itemIDs {
            guard let outcome = outcomes[itemID] else { continue }
            let attemptID = pendingAttemptIDs[itemID, default: UUID()]
            pendingAttemptIDs[itemID] = attemptID
            let attempt = LanguageReviewAttempt(
                id: attemptID, profileID: session.profileID, itemID: itemID,
                activity: question.activity, outcome: outcome,
                submittedAnswer: submittedAnswer(answer, question: question, itemID: itemID),
                sessionID: session.id)
            switch store.recordReview(attempt) {
            case .recorded, .alreadyRecorded:
                persistedAny = true
            case .missingCard:
                reviewError = "The card no longer exists; the answer was not recorded."
                if persistedAny { notifyDeckChanged() }
                return
            case .profileMismatch:
                reviewError = "The card belongs to another language profile; the answer was not recorded."
                if persistedAny { notifyDeckChanged() }
                return
            case .invalidAttempt, .attemptIDConflict:
                reviewError = "The review could not be validated and was not recorded."
                if persistedAny { notifyDeckChanged() }
                return
            case .failed(let message):
                reviewError = "Could not save the review: \(message)"
                if persistedAny { notifyDeckChanged() }
                return
            }
        }

        answerResult = result
        answerRecorded = true
        recordedAttemptCount = outcomes.count
        recordedCorrectCount = outcomes.values.filter(\.isCorrect).count
        reviewError = nil
        if persistedAny { notifyDeckChanged() }
    }

    func continuePractice() {
        guard let session = practiceSession, answerRecorded,
              let outcomes = answerResult?.outcomes,
              let next = LanguageLearningEngine.advancing(session, outcomes: outcomes)
        else { return }
        practiceSession = next
        answerResult = nil
        answerRecorded = false
        reviewError = nil
        isFlashcardRevealed = false
        pendingAttemptIDs.removeAll()
    }

    func skipQuestion() {
        guard let session = practiceSession, canSkipCurrentQuestion,
              let next = LanguageLearningEngine.advancing(session, outcomes: [:])
        else { return }
        practiceSession = next
        answerResult = nil
        reviewError = nil
        isFlashcardRevealed = false
        pendingAttemptIDs.removeAll()
    }

    func cancelPractice() {
        practiceSession = nil
        answerResult = nil
        answerRecorded = false
        reviewError = nil
        isFlashcardRevealed = false
        pendingAttemptIDs.removeAll()
        destination = .practice
    }

    func pausePractice() {
        guard practiceSession != nil else { return }
        destination = .practice
    }

    func resumePractice() {
        guard practiceSession != nil else { return }
        destination = .session
    }

    func generateProposals(config: RequestConfig, topic: String) {
        guard let profile = activeProfile else {
            proposalError = "Set up a language profile first."
            return
        }
        guard !isGeneratingProposals else { return }
        isGeneratingProposals = true
        proposalError = nil
        let knownItems = store.items(profileID: profile.id)
        let requestedProfileID = profile.id
        proposalTask = Task { [weak self] in
            do {
                let proposals = try await LanguageTutorService.proposeVocabulary(
                    config: config, profile: profile, topic: topic, knownItems: knownItems)
                guard !Task.isCancelled, let self,
                      self.activeProfile?.id == requestedProfileID
                else { return }
                var seenTerms = Set(self.studyProposals.map {
                    LanguageLearningEngine.normalizeAnswer($0.targetTerm)
                })
                let additions = proposals.filter { proposal in
                    seenTerms.insert(LanguageLearningEngine.normalizeAnswer(proposal.targetTerm)).inserted
                        && !self.isDuplicateProposal(proposal)
                }
                self.studyProposals.append(contentsOf: additions)
                if proposals.isEmpty {
                    self.proposalError = "No valid proposals were returned. Try a different topic."
                } else if additions.isEmpty {
                    self.proposalError = "No new proposals were returned. Try a different topic."
                }
            } catch {
                guard let self, !Task.isCancelled,
                      self.activeProfile?.id == requestedProfileID
                else { return }
                self.proposalError = error.localizedDescription
            }
            guard let self, self.activeProfile?.id == requestedProfileID else { return }
            self.isGeneratingProposals = false
            self.proposalTask = nil
        }
    }

    func isDuplicateProposal(_ proposal: VocabularyProposal) -> Bool {
        guard let profileID = activeProfile?.id else { return false }
        let candidate = LanguageLearningEngine.normalizeAnswer(proposal.targetTerm)
        return store.items(profileID: profileID, kind: .vocab).contains {
            LanguageLearningEngine.normalizeAnswer($0.term) == candidate
        }
    }

    @discardableResult
    func saveProposal(_ proposal: VocabularyProposal) -> Bool {
        guard let profile = activeProfile, let clean = proposal.normalized() else {
            proposalError = "A target term and translation are required."
            return false
        }
        guard !isDuplicateProposal(clean) else {
            proposalError = "That term is already in this profile's deck. Edit it or skip it."
            return false
        }
        let item = LearnItem(
            profileID: profile.id, kind: .vocab, term: clean.targetTerm,
            reading: clean.reading, translation: clean.translation,
            partOfSpeech: clean.partOfSpeech, register: clean.register, notes: clean.notes,
            examples: clean.example.isEmpty ? [] : [clean.example], tags: clean.tags,
            acceptedTranslations: clean.acceptedTranslations)
        guard store.upsert(item) else {
            proposalError = "Could not save this vocabulary card."
            return false
        }
        studyProposals.removeAll { $0.id == proposal.id }
        proposalError = nil
        notifyDeckChanged()
        return true
    }

    func skipProposal(_ id: UUID) {
        studyProposals.removeAll { $0.id == id }
    }

    func cancelProposalGeneration() {
        proposalTask?.cancel()
        proposalTask = nil
        isGeneratingProposals = false
    }

    private func resetProfileScopedState() {
        practiceSession = nil
        answerResult = nil
        answerRecorded = false
        reviewError = nil
        isFlashcardRevealed = false
        pendingAttemptIDs.removeAll()
        cancelProposalGeneration()
        studyProposals.removeAll()
        proposalTopic = ""
        proposalError = nil
        cancelTutorTurn()
        tutorThreads = []
        selectedTutorThreadID = nil
        tutorDraft = ""
        tutorError = nil
    }

    func refreshTutorThreads() {
        guard let profileID = activeProfile?.id else {
            tutorThreads = []
            selectedTutorThreadID = nil
            return
        }
        tutorThreads = store.tutorThreads(profileID: profileID)
        if !tutorThreads.contains(where: { $0.id == selectedTutorThreadID }) {
            selectedTutorThreadID = tutorThreads.first?.id
        }
    }

    func createTutorThread() {
        guard let profile = activeProfile else {
            tutorError = "Set up a language profile first."
            return
        }
        cancelTutorTurn()
        guard let thread = store.createTutorThread(profileID: profile.id) else {
            tutorError = "Could not create a tutor thread."
            return
        }
        tutorThreads.insert(thread, at: 0)
        selectedTutorThreadID = thread.id
        tutorError = nil
    }

    func selectTutorThread(_ id: UUID) {
        guard tutorThreads.contains(where: { $0.id == id }), selectedTutorThreadID != id else { return }
        cancelTutorTurn()
        selectedTutorThreadID = id
        tutorDraft = ""
        tutorError = nil
    }

    func deleteTutorThread(_ id: UUID) {
        if selectedTutorThreadID == id { cancelTutorTurn() }
        store.deleteTutorThread(id: id)
        tutorThreads.removeAll { $0.id == id }
        if selectedTutorThreadID == id { selectedTutorThreadID = tutorThreads.first?.id }
    }

    func sendTutorMessage(config: RequestConfig) {
        let content = tutorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isTutorStreaming, let profile = activeProfile else { return }
        if selectedTutorThreadID == nil { createTutorThread() }
        guard let threadID = selectedTutorThreadID,
              let threadIndex = tutorThreads.firstIndex(where: { $0.id == threadID })
        else { return }

        let message = LanguageTutorMessage(role: .user, content: content)
        guard store.appendTutorMessage(message, to: threadID) else {
            tutorError = "Could not save your message. It was not sent."
            return
        }
        tutorThreads[threadIndex].messages.append(message)
        tutorThreads[threadIndex].updatedAt = message.createdAt
        if tutorThreads[threadIndex].messages.filter({ $0.role == .user }).count == 1 {
            let firstLine = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? content
            let title = String(firstLine.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
            tutorThreads[threadIndex].title = title.isEmpty ? "Tutor conversation" : title
            _ = store.updateTutorThreadTitle(tutorThreads[threadIndex].title, threadID: threadID)
        }
        let history = tutorThreads[threadIndex].messages
        tutorDraft = ""
        startTutorTurn(
            config: config, profile: profile, threadID: threadID,
            history: history, userMessageID: message.id)
    }

    func retryTutorMessage(config: RequestConfig) {
        guard !isTutorStreaming,
              let failedMessageID = failedTutorMessageID,
              let profile = activeProfile,
              let threadID = selectedTutorThreadID,
              let thread = tutorThreads.first(where: { $0.id == threadID }),
              thread.messages.last?.id == failedMessageID,
              thread.messages.last?.role == .user
        else { return }
        startTutorTurn(
            config: config, profile: profile, threadID: threadID,
            history: thread.messages, userMessageID: failedMessageID)
    }

    private func startTutorTurn(
        config: RequestConfig, profile: LanguageProfile, threadID: UUID,
        history: [LanguageTutorMessage], userMessageID: UUID
    ) {
        let knownItems = store.items(profileID: profile.id)
        tutorError = nil
        failedTutorMessageID = nil
        tutorStreamedReply = ""
        isTutorStreaming = true
        tutorTask = Task { [weak self] in
            do {
                for try await delta in LanguageTutorService.streamConversation(
                    config: config, profile: profile, knownItems: knownItems, history: history)
                {
                    guard !Task.isCancelled, let self else { return }
                    self.tutorStreamedReply += delta
                }
                guard !Task.isCancelled, let self else { return }
                let reply = self.tutorStreamedReply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reply.isEmpty else {
                    self.tutorError = "The tutor returned an empty reply. Retry the last message."
                    self.failedTutorMessageID = userMessageID
                    self.tutorStreamedReply = ""
                    self.isTutorStreaming = false
                    self.tutorTask = nil
                    return
                }
                let response = LanguageTutorMessage(role: .assistant, content: reply)
                guard self.store.appendTutorMessage(response, to: threadID) else {
                    self.tutorError = "The tutor replied, but the response could not be saved. Retry the last message."
                    self.failedTutorMessageID = userMessageID
                    self.tutorStreamedReply = ""
                    self.isTutorStreaming = false
                    self.tutorTask = nil
                    return
                }
                if let index = self.tutorThreads.firstIndex(where: { $0.id == threadID }) {
                    self.tutorThreads[index].messages.append(response)
                    self.tutorThreads[index].updatedAt = response.createdAt
                }
                self.tutorStreamedReply = ""
                self.isTutorStreaming = false
                self.tutorTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.tutorError = error.localizedDescription
                self.failedTutorMessageID = userMessageID
                self.tutorStreamedReply = ""
                self.isTutorStreaming = false
                self.tutorTask = nil
            }
        }
    }

    func cancelTutorTurn() {
        tutorTask?.cancel()
        tutorTask = nil
        tutorStreamedReply = ""
        isTutorStreaming = false
        failedTutorMessageID = nil
    }

    func notifyDeckChanged() {
        deckRevision &+= 1
    }

    private func submittedAnswer(_ answer: LanguageAnswer, question: LanguageQuestion, itemID: UUID) -> String? {
        switch answer {
        case .selfRating(let remembered):
            return remembered ? "remembered" : "again"
        case .choice(let optionID):
            return question.choices.first(where: { $0.id == optionID })?.text
        case .dontKnow:
            return "I don't know"
        case .text(let text):
            return text
        case .matches(let pairs):
            guard let index = question.itemIDs.firstIndex(of: itemID), index < question.correctMatches.count else { return nil }
            let matched = pairs.first(where: { $0 == question.correctMatches[index] })
            guard let matched,
                  let term = question.matchTerms.first(where: { $0.id == matched.termOptionID })?.text,
                  let meaning = question.matchMeanings.first(where: { $0.id == matched.meaningOptionID })?.text
            else { return "incorrect match" }
            return "\(term) -> \(meaning)"
        }
    }
}