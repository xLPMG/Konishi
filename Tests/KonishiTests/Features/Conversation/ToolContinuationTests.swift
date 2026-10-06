import Foundation
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

    @Test("restores only unresolved calls from the latest assistant batch")
    func restoresUnfinishedToolApproval() {
        let call = ToolCall(
            id: "file-write-1", type: "function",
            function: FunctionCall(name: "file_write", arguments: "{}"))
        let secondCall = ToolCall(
            id: "shell-1", type: "function",
            function: FunctionCall(name: "run_shell", arguments: "{}"))
        let assistant = ChatMessage(
            role: .assistant, content: "I will create that file.", toolCalls: [call, secondCall])
        let result = ChatMessage(
            role: .tool, content: "Saved", toolCallId: call.id, toolName: "file_write")
        let secondResult = ChatMessage(
            role: .tool, content: "Done", toolCallId: secondCall.id, toolName: "run_shell")
        let laterUser = ChatMessage(role: .user, content: "Another request")

        #expect(AppModel.recoverableToolCalls(in: [assistant])?.calls.map(\.id) == [call.id, secondCall.id])
        #expect(AppModel.recoverableToolCalls(in: [assistant, result])?.calls.map(\.id) == [secondCall.id])
        #expect(AppModel.recoverableToolCalls(in: [assistant, result, secondResult]) == nil)
        #expect(AppModel.recoverableToolCalls(in: [assistant, laterUser]) == nil)
    }

    @Test("preserves continuation required by an already-completed call")
    func recoveryPreservesFullBatchContinuation() {
        let calculate = ToolCall(
            id: "calculate-1", type: "function",
            function: FunctionCall(name: "calculate", arguments: "{\"expression\":\"1 + 1\"}"))
        let write = ToolCall(
            id: "write-1", type: "function",
            function: FunctionCall(name: "memory_write", arguments: "{}"))
        let assistant = ChatMessage(
            role: .assistant, content: "I will calculate and save that.",
            toolCalls: [calculate, write])
        let calculateResult = ChatMessage(
            role: .tool, content: "1 + 1 = 2", toolCallId: calculate.id, toolName: "calculate")

        let recovered = AppModel.recoverableToolCalls(in: [assistant, calculateResult])
        #expect(recovered?.calls.map(\.id) == [write.id])
        #expect(recovered?.continueAfter == true)
    }

    @Test("tool continuation keeps its original model and endpoint")
    func continuationKeepsTurnRoute() {
        let suite = "ToolContinuationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.baseURL = "http://127.0.0.1:8080"
        settings.model = "incoai/Qwen3.8-27B-Splash"
        let conversationID = UUID()
        let persona = Persona.defaults[0]

        let initial = AppModel.ActiveTurnContext.resolve(
            conversationID: conversationID, existing: nil, persona: persona, settings: settings)

        settings.baseURL = "http://127.0.0.1:8040"
        settings.model = "/Users/me/Models/gemma"
        var changedPersona = persona
        changedPersona.model = "/Users/me/Models/gemma"

        let continuation = AppModel.ActiveTurnContext.resolve(
            conversationID: conversationID, existing: initial,
            persona: changedPersona, settings: settings)
        #expect(continuation.requestConfig.model == "incoai/Qwen3.8-27B-Splash")
        #expect(continuation.requestConfig.chatURL?.port == 8080)
        #expect(continuation.persona.model == nil)

        let nextTurn = AppModel.ActiveTurnContext.resolve(
            conversationID: UUID(), existing: continuation,
            persona: changedPersona, settings: settings)
        #expect(nextTurn.requestConfig.model == "/Users/me/Models/gemma")
        #expect(nextTurn.requestConfig.chatURL?.port == 8040)
    }
}