import Foundation

enum LanguageTutorRole: String, Codable, Sendable {
    case user
    case assistant
}

struct LanguageTutorMessage: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var role: LanguageTutorRole
    var content: String
    var createdAt: Date

    init(id: UUID = UUID(), role: LanguageTutorRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
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