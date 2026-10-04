import Foundation

enum LanguageActivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case mixedReview
    case flashcards
    case multipleChoice
    case matching
    case typedRecall
    case cloze

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flashcards: "Flashcards"
        case .multipleChoice: "Multiple choice"
        case .matching: "Word matching"
        case .typedRecall: "Typed recall"
        case .cloze: "Cloze"
        case .mixedReview: "Mixed review"
        }
    }

    var icon: String {
        switch self {
        case .flashcards: "rectangle.on.rectangle"
        case .multipleChoice: "checkmark.circle"
        case .matching: "arrow.left.arrow.right"
        case .typedRecall: "keyboard"
        case .cloze: "text.badge.minus"
        case .mixedReview: "shuffle"
        }
    }
}

enum LanguageQuestionDirection: String, CaseIterable, Identifiable, Sendable {
    case targetToBase
    case baseToTarget

    var id: String { rawValue }

    var label: String {
        switch self {
        case .targetToBase: "Target to base"
        case .baseToTarget: "Base to target"
        }
    }
}

enum LanguageReviewOutcome: String, Codable, Sendable {
    case again
    case remembered
    case correct
    case incorrect

    var isCorrect: Bool {
        self == .remembered || self == .correct
    }
}