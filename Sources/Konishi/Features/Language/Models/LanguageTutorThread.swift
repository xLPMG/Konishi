import Foundation

enum LanguageTutorRole: String, Codable, Sendable {
    case user
    case assistant
}

struct LanguageTutorToolExchange: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var arguments: String
    var result: String
}

struct LanguageTutorMessage: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var role: LanguageTutorRole
    var content: String
    var createdAt: Date
    var reasoning: String?
    var toolExchanges: [LanguageTutorToolExchange]

    init(
        id: UUID = UUID(), role: LanguageTutorRole, content: String, createdAt: Date = Date(),
        reasoning: String? = nil, toolExchanges: [LanguageTutorToolExchange] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.reasoning = reasoning
        self.toolExchanges = toolExchanges
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, createdAt, reasoning, toolExchanges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(LanguageTutorRole.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        toolExchanges = try container.decodeIfPresent(
            [LanguageTutorToolExchange].self, forKey: .toolExchanges) ?? []
    }
}

struct LanguageTutorThread: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var profileID: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [LanguageTutorMessage]

    init(
        id: UUID = UUID(), profileID: UUID, title: String = "Tutor conversation",
        createdAt: Date = Date(), updatedAt: Date? = nil, messages: [LanguageTutorMessage] = []
    ) {
        self.id = id
        self.profileID = profileID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.messages = messages
    }
}