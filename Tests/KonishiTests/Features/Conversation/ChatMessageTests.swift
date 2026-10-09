import Foundation
import Testing

@testable import Konishi

@Suite("ChatMessage")
struct ChatMessageTests {
    @Test("web image result metadata persists and defaults empty for old messages")
    func webImageResultMetadataIsBackwardCompatible() throws {
        let result = WebImageResult(
            title: "Blue jay", sourceURL: "https://example.com/bird", dataURL: "data:image/jpeg;base64,AA==")
        let message = ChatMessage(role: .tool, content: "Found an image", webImageResults: [result])
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(restored.webImageResults == [result])

        let legacy = try JSONDecoder().decode(
            ChatMessage.self, from: Data(#"{"role":"user","content":"hello"}"#.utf8))
        #expect(legacy.webImageResults.isEmpty)
    }

    @Test("only explicitly user-interrupted replies say the user interrupted them")
    func assistantPromptTextReflectsUserInterruption() {
        let workPaused = ChatMessage(role: .assistant, content: "Partial answer")
        let userStopped = ChatMessage(role: .assistant, content: "Partial answer", interrupted: true)

        #expect(workPaused.assistantPromptText == "Partial answer")
        #expect(userStopped.assistantPromptText == "Partial answer\n\n[Response interrupted by the user.]")
    }
}