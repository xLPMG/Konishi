import Foundation

/// One multiple-choice question posed to the user by the `ask_multiple_choice` tool.
struct MCQuestion: Identifiable, Sendable, Equatable {
    let id: UUID
    let prompt: String
    let options: [String]
    /// 0-based index of the correct option, if the model supplied one.
    let correctIndex: Int?
    /// Deck card this question tests, if any — enables deterministic auto-grading.
    let itemID: UUID?
}

/// A paused turn waiting for the user to answer multiple-choice questions in the UI.
struct PendingInteraction: Identifiable, Sendable {
    let id = UUID()
    let conversationID: UUID
    let questions: [MCQuestion]
}
