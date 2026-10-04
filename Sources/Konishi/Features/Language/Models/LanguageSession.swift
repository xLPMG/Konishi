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
            return """
                PRACTICE mode - mandatory review workflow:
                Quiz due deck cards one at a time. When `ask_multiple_choice` is available, ask each deck question with that tool, one card per call, and include the card's `item_id` and correct answer index. The tool grades and records linked cards automatically; never also call `record_review` for them. After the answer result, give brief feedback, then use `ask_multiple_choice` again for the next card. Never present a deck quiz question as plain text when the tool is available.

                If `ask_multiple_choice` is unavailable but `record_review` is available, ask one open-response deck question in plain text, judge the answer, then call `record_review` exactly once before feedback or the next question. Treat "I don't know" as incorrect. Do not claim a review was recorded unless the tool succeeded. Keep feedback brief.
                """
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
