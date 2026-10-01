import Foundation
import Testing

@testable import Konishi

@Suite("ChatMessage")
struct ChatMessageTests {
    @Test("decodes legacy localOnly field and omits it when re-encoded")
    func legacyLocalOnlyFieldIsIgnored() throws {
        let data = Data(#"{"role":"user","content":"hello","localOnly":true}"#.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)

        #expect(message.content == "hello")

        let encoded = try JSONEncoder().encode(message)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["localOnly"] == nil)
    }
}