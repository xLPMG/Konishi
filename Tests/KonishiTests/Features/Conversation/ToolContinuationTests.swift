import Testing

@testable import Konishi

@Suite("Tool continuation")
@MainActor
struct ToolContinuationTests {
    @Test("shell output requires a follow-up even after a preamble")
    func shellOutputRequiresFollowUp() {
        let call = ToolCall(
            id: "shell-1", type: "function",
            function: FunctionCall(name: "run_shell", arguments: "{}"))
        #expect(AppModel.needsToolContinuation(
            content: "Fair enough. Let me go find it.", calls: [call]))
    }

    @Test("a written reply with only a write tool stays complete")
    func writtenReplyWithWriteToolStaysComplete() {
        let call = ToolCall(
            id: "write-1", type: "function",
            function: FunctionCall(name: "memory_write", arguments: "{}"))
        #expect(!AppModel.needsToolContinuation(content: "Saved that.", calls: [call]))
    }
}