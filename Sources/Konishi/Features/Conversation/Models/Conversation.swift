import Foundation

struct ConversationTask: Identifiable, Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending
        case inProgress
        case done
    }

    var id = UUID()
    var title: String
    var notes: String
    var status: Status
    var subtasks: [ConversationSubtask]

    init(
        id: UUID = UUID(), title: String, notes: String = "", status: Status = .pending,
        subtasks: [ConversationSubtask] = []
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.status = status
        self.subtasks = subtasks
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, status, subtasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decode(String.self, forKey: .notes)
        status = try container.decode(Status.self, forKey: .status)
        subtasks = try container.decodeIfPresent([ConversationSubtask].self, forKey: .subtasks) ?? []
    }
}

struct ConversationSubtask: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var status: ConversationTask.Status

    init(id: UUID = UUID(), title: String, status: ConversationTask.Status = .pending) {
        self.id = id
        self.title = title
        self.status = status
    }
}

struct ContextPin: Identifiable, Codable, Equatable, Sendable {
    static let maximumCount = 5
    static let maximumPinCharacters = 600
    static let maximumPromptCharacters = 3_200

    var messageID: UUID
    var role: Role
    var text: String

    var id: UUID { messageID }

    static func promptText(for pins: [ContextPin]) -> String {
        let header = "# User-pinned context\nThese are excerpts the user chose to keep in view. Use them when relevant; the current message takes precedence.\n"
        var remaining = maximumPromptCharacters - header.count
        var excerpts: [String] = []

        for pin in pins.prefix(maximumCount) {
            let label = pin.role == .user ? "You" : "Assistant"
            let prefix = "- \(label): "
            let available = min(maximumPinCharacters, remaining - prefix.count)
            guard available > 0 else { break }

            let excerpt = String(pin.text.prefix(available))
            let truncated = excerpt.count < pin.text.count ? "…" : ""
            excerpts.append(prefix + excerpt + truncated)
            remaining -= prefix.count + excerpt.count + truncated.count
        }

        guard !excerpts.isEmpty else { return "" }
        return header + excerpts.joined(separator: "\n")
    }
}

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
    /// Legacy marker decoded only so startup can remove pre-workspace Learn conversation files.
    /// Legacy marker used by startup cleanup; not used for conversation routing or memory policy.
    var isLanguage: Bool?
    /// Number of messages at the time the title was last updated.
    var lastTitledMessageCount: Int?
    /// Short recallable summary of the whole conversation (distinct from the compression `summary`).
    var digest: String?
    /// Number of leading messages the digest covers.
    var digestCount: Int?
    /// `updatedAt` at the moment the digest was known to be current; a later `updatedAt` means stale.
    var digestUpdatedAt: Date?
    /// When the digest's durable highlights were folded into long-term History (see the sleep pass).
    var digestRolledUpAt: Date?
    /// User-managed task plan and notes for this conversation.
    var tasks: [ConversationTask]?
    /// User-selected message excerpts kept in context across turns and compression.
    var contextPins: [ContextPin]?
    var permissionRules: [PermissionRule]?

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
        isLanguage: Bool? = nil,
        lastTitledMessageCount: Int? = nil,
        digest: String? = nil,
        digestCount: Int? = nil,
        digestUpdatedAt: Date? = nil,
        tasks: [ConversationTask]? = nil,
        contextPins: [ContextPin]? = nil,
        permissionRules: [PermissionRule]? = nil
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
        self.lastTitledMessageCount = lastTitledMessageCount
        self.digest = digest
        self.digestCount = digestCount
        self.digestUpdatedAt = digestUpdatedAt
        self.tasks = tasks
        self.contextPins = contextPins
        self.permissionRules = permissionRules
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
    var lastTitledMessageCount: Int?
    var digest: String?
    var digestCount: Int?
    var digestUpdatedAt: Date?
    var digestRolledUpAt: Date?
    var tasks: [ConversationTask]?
    var contextPins: [ContextPin]?
    var permissionRules: [PermissionRule]?

    /// A body-less `Conversation` (empty `messages`) carrying just the metadata.
    func asConversation() -> Conversation {
        var convo = Conversation(
            id: id, title: title, personaID: personaID, messages: [],
            createdAt: createdAt, updatedAt: updatedAt,
            summary: summary, summarizedCount: summarizedCount, memorizedCount: memorizedCount,
            isLanguage: isLanguage, lastTitledMessageCount: lastTitledMessageCount,
            digest: digest, digestCount: digestCount, digestUpdatedAt: digestUpdatedAt,
            tasks: tasks, contextPins: contextPins,
            permissionRules: permissionRules
        )
        convo.digestRolledUpAt = digestRolledUpAt
        return convo
    }
}
