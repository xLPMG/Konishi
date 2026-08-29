import Foundation

/// The activity for a language-learning session; swaps the model's teaching behaviour.
enum LanguageSessionKind: String, CaseIterable, Identifiable, Sendable {
    case study
    case practice
    case free

    var id: String { rawValue }

    var label: String {
        switch self {
        case .study: "Study"
        case .practice: "Practice"
        case .free: "Free talk"
        }
    }

    var icon: String {
        switch self {
        case .study: "book"
        case .practice: "checkmark.circle"
        case .free: "bubble.left.and.bubble.right"
        }
    }

    /// Instruction injected into the system prompt describing how to run the session.
    var guidance: String {
        switch self {
        case .study:
            return "STUDY mode: introduce new vocabulary and grammar suited to the topic and level, each with a clear example. Bank every genuinely new item in the deck."
        case .practice:
            return "PRACTICE mode: quiz the user on what is due for review, judge each answer, and record the result. Keep it interactive and give brief corrective feedback."
        case .free:
            return "FREE CONVERSATION: chat naturally in the target language, gently correcting mistakes, and weave in words that are due for review. Bank only genuinely new words the user meets."
        }
    }
}

/// Transient per-session configuration for language mode (not persisted).
struct LanguageSession: Sendable {
    var kind: LanguageSessionKind = .free
    var topic: String = ""
    /// Optional difficulty override; nil falls back to the profile's level.
    var difficulty: CEFRLevel? = nil
}
