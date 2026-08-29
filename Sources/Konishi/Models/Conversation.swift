import Foundation

struct Conversation: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var personaID: UUID?
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date
    /// Rolling summary of folded-away early turns (compression).
    var summary: String?
    /// Number of leading messages already folded into `summary`.
    var summarizedCount: Int?
    /// Number of leading messages already folded into long-term memory.
    var memorizedCount: Int?
    /// True for Learn-mode sessions; kept separate from normal chats and excluded from memory.
    var isLanguage: Bool?

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        personaID: UUID? = nil,
        messages: [ChatMessage] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        summary: String? = nil,
        summarizedCount: Int? = nil,
        memorizedCount: Int? = nil,
        isLanguage: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.personaID = personaID
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summary = summary
        self.summarizedCount = summarizedCount
        self.memorizedCount = memorizedCount
        self.isLanguage = isLanguage
    }

    var lastStats: MessageStats? {
        // The in-progress assistant message has no stats yet; keep the last completed turn's stats
        // so the context gauge / metrics don't blank out to zero while a reply is streaming.
        messages.last(where: { $0.role == .assistant && $0.stats != nil })?.stats
    }
}

/// Decodes a conversation's metadata without its (potentially large) message bodies, so the
/// launch load stays cheap and bodies can be paged in on demand.
struct ConversationMeta: Decodable {
    var id: UUID
    var title: String
    var personaID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var summary: String?
    var summarizedCount: Int?
    var memorizedCount: Int?
    var isLanguage: Bool?

    /// A body-less `Conversation` (empty `messages`) carrying just the metadata.
    func asConversation() -> Conversation {
        Conversation(
            id: id, title: title, personaID: personaID, messages: [],
            createdAt: createdAt, updatedAt: updatedAt,
            summary: summary, summarizedCount: summarizedCount, memorizedCount: memorizedCount,
            isLanguage: isLanguage
        )
    }
}
