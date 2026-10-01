import Foundation
import Testing

@testable import Konishi

@Suite("Conversation search index")
struct ConversationSearchIndexTests {
    @Test("rebuilds from saved chats and tracks later updates and deletes")
    func rebuildUpdateDelete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationsDirectory = root.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: conversationsDirectory, withIntermediateDirectories: true)

        let conversation = Conversation(messages: [
            ChatMessage(role: .user, content: "Researching quasar telescope optics"),
            ChatMessage(role: .assistant, content: "The nebula observations were useful")
        ])
        let json = try JSONEncoder().encode(conversation)
        try json.write(
            to: conversationsDirectory.appendingPathComponent("\(conversation.id.uuidString).json"))

        let index = ConversationSearchIndex(databaseURL: root.appendingPathComponent("search.sqlite"))
        try index.rebuildIfNeeded(conversationsDirectory: conversationsDirectory)
        #expect(try index.search(query: "QUASAR telescope").contains(conversation.id))

        var updated = conversation
        updated.messages = [ChatMessage(role: .assistant, content: "A lunar observatory")]
        try index.upsert(.init(updated))
        #expect(try index.search(query: "quasar").isEmpty)
        #expect(try index.search(query: "lunar observatory").contains(conversation.id))

        try index.delete(conversation.id)
        #expect(try index.search(query: "lunar").isEmpty)
    }

    @Test("treats FTS operators and punctuation as ordinary query text")
    func queryCannotInjectFtsOperators() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationsDirectory = root.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: conversationsDirectory, withIntermediateDirectories: true)
        let conversation = Conversation(messages: [
            ChatMessage(role: .user, content: "A safe searchable sentence")
        ])
        try JSONEncoder().encode(conversation).write(
            to: conversationsDirectory.appendingPathComponent("\(conversation.id.uuidString).json"))

        let index = ConversationSearchIndex(databaseURL: root.appendingPathComponent("search.sqlite"))
        try index.rebuildIfNeeded(conversationsDirectory: conversationsDirectory)
        #expect(try index.search(query: "safe OR searchable").isEmpty)
    }
}