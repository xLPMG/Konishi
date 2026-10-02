import Foundation
import Testing

@testable import Konishi

@Suite("Pinned conversation context")
struct ContextPinTests {
    @Test("conversation pins round-trip and old conversations still decode")
    func persistenceCompatibility() throws {
        let pin = ContextPin(messageID: UUID(), role: .user, text: "Keep this constraint in mind.")
        let permissionRule = PermissionRule(
            capability: .workspaceWrite, scope: .pathPrefix("/workspace/reports"), decision: .allow)
        let conversation = Conversation(
            title: "Pinned", contextPins: [pin], permissionRules: [permissionRule])
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let decoded = try decoder.decode(Conversation.self, from: encoder.encode(conversation))
        #expect(decoded.contextPins == [pin])
        #expect(decoded.permissionRules == [permissionRule])
        let metadata = try decoder.decode(ConversationMeta.self, from: encoder.encode(conversation))
        #expect(metadata.asConversation().permissionRules == [permissionRule])

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(Conversation(title: "Legacy")))
                as? [String: Any])
        legacyObject.removeValue(forKey: "contextPins")
        legacyObject.removeValue(forKey: "permissionRules")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try decoder.decode(Conversation.self, from: legacyData)
        let legacyMeta = try decoder.decode(ConversationMeta.self, from: legacyData)
        #expect(legacy.contextPins == nil)
        #expect(legacyMeta.asConversation().contextPins == nil)
        #expect(legacy.permissionRules == nil)
        #expect(legacyMeta.asConversation().permissionRules == nil)
    }

    @Test("prompt excerpt is bounded and includes at most five pins")
    func promptIsBounded() {
        let pins = (1...7).map { index in
            ContextPin(
                messageID: UUID(), role: index.isMultiple(of: 2) ? .assistant : .user,
                text: "pin-\(index) " + String(repeating: "x", count: 1_000))
        }

        let prompt = ContextPin.promptText(for: pins)

        #expect(prompt.contains("pin-1"))
        #expect(prompt.contains("pin-5"))
        #expect(!prompt.contains("pin-6"))
        #expect(prompt.count <= ContextPin.maximumPromptCharacters)
    }
}