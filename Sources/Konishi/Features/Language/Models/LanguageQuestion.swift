import Foundation

struct LanguageOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

struct LanguageMatch: Equatable, Hashable, Sendable {
    let termOptionID: UUID
    let meaningOptionID: UUID
}

struct LanguageQuestion: Identifiable, Equatable, Sendable {
    let id: UUID
    let activity: LanguageActivity
    let direction: LanguageQuestionDirection
    let prompt: String
    let itemIDs: [UUID]
    let answer: String
    let acceptedAnswers: [String]
    let choices: [LanguageOption]
    let correctChoiceID: UUID?
    let matchTerms: [LanguageOption]
    let matchMeanings: [LanguageOption]
    let correctMatches: [LanguageMatch]

    init(
        id: UUID = UUID(),
        activity: LanguageActivity,
        direction: LanguageQuestionDirection,
        prompt: String,
        itemIDs: [UUID],
        answer: String,
        acceptedAnswers: [String] = [],
        choices: [LanguageOption] = [],
        correctChoiceID: UUID? = nil,
        matchTerms: [LanguageOption] = [],
        matchMeanings: [LanguageOption] = [],
        correctMatches: [LanguageMatch] = []
    ) {
        self.id = id
        self.activity = activity
        self.direction = direction
        self.prompt = prompt
        self.itemIDs = itemIDs
        self.answer = answer
        self.acceptedAnswers = acceptedAnswers
        self.choices = choices
        self.correctChoiceID = correctChoiceID
        self.matchTerms = matchTerms
        self.matchMeanings = matchMeanings
        self.correctMatches = correctMatches
    }
}

enum LanguageAnswer: Equatable, Sendable {
    case selfRating(remembered: Bool)
    case choice(UUID)
    case dontKnow
    case text(String)
    case matches([LanguageMatch])
}

enum LanguageAnswerResult: Equatable, Sendable {
    case graded([UUID: LanguageReviewOutcome])
    case invalid

    var outcomes: [UUID: LanguageReviewOutcome]? {
        switch self {
        case .graded(let outcomes): outcomes
        case .invalid: nil
        }
    }

    var allCorrect: Bool { outcomes?.values.allSatisfy(\.isCorrect) == true }
}

struct LanguagePracticeSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let profileID: UUID
    let activity: LanguageActivity
    let questions: [LanguageQuestion]
    private(set) var currentIndex: Int
    private(set) var outcomes: [LanguageReviewOutcome]

    init(
        id: UUID = UUID(), profileID: UUID, activity: LanguageActivity,
        questions: [LanguageQuestion], currentIndex: Int = 0, outcomes: [LanguageReviewOutcome] = []
    ) {
        self.id = id
        self.profileID = profileID
        self.activity = activity
        self.questions = questions
        self.currentIndex = min(max(0, currentIndex), questions.count)
        self.outcomes = outcomes
    }

    var currentQuestion: LanguageQuestion? {
        guard currentIndex < questions.count else { return nil }
        return questions[currentIndex]
    }

    var isComplete: Bool { currentIndex >= questions.count }
    var completedCount: Int { outcomes.count }

    mutating func appendOutcomes(_ newOutcomes: [LanguageReviewOutcome]) {
        guard !isComplete else { return }
        outcomes.append(contentsOf: newOutcomes)
        currentIndex += 1
    }
}