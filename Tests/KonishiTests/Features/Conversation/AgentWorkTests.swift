import Foundation
import Testing

@testable import Konishi

@Suite("Agent work limits")
struct AgentWorkTests {
    @Test("new tasks are blocked during every in-flight or pending state")
    func taskEntryGuards() {
        #expect(AgentTaskEntry.isAvailable(
            isStreaming: false, awaitingToolApproval: false,
            awaitingWorkDecision: false, finishingToolOperation: false))
        #expect(!AgentTaskEntry.isAvailable(
            isStreaming: true, awaitingToolApproval: false,
            awaitingWorkDecision: false, finishingToolOperation: false))
        #expect(!AgentTaskEntry.isAvailable(
            isStreaming: false, awaitingToolApproval: true,
            awaitingWorkDecision: false, finishingToolOperation: false))
        #expect(!AgentTaskEntry.isAvailable(
            isStreaming: false, awaitingToolApproval: false,
            awaitingWorkDecision: true, finishingToolOperation: false))
        #expect(!AgentTaskEntry.isAvailable(
            isStreaming: false, awaitingToolApproval: false,
            awaitingWorkDecision: false, finishingToolOperation: true))
    }

    @Test("Autopilot halts the batch at the repeat threshold and identifies remaining calls")
    func repeatedToolStopsBatch() {
        let calls = (0..<3).map { index in
            ToolCall(
                id: "tool-\(index)", type: "function",
                function: FunctionCall(name: "calculate", arguments: "{\"x\":\(index)}"))
        }

        #expect(!AgentToolLoopPolicy.shouldStopAutopilotBatch(repeats: 2, autopilot: true))
        #expect(AgentToolLoopPolicy.shouldStopAutopilotBatch(repeats: 3, autopilot: true))
        #expect(!AgentToolLoopPolicy.shouldStopAutopilotBatch(repeats: 3, autopilot: false))
        #expect(AgentToolLoopPolicy.remainingCalls(after: 0, in: calls).map(\.id) == ["tool-1", "tool-2"])
    }

    @Test("soft limits pause at their thresholds and Continue extends them")
    func softLimitsExtend() {
        var session = AgentWorkSession(
            conversationID: UUID(), autopilot: false,
            limits: AgentWorkLimits(outputTokens: 3, modelTurns: 2, toolCalls: 2))

        #expect(session.beginTurn() == nil)
        #expect(session.beginTurn() == nil)
        #expect(session.beginTurn() == .modelTurns)
        #expect(session.observeOutput("123456789012") == .outputTokens)
        #expect(session.pauseBeforeToolCalls(2) == nil)
        session.recordToolCalls(2)
        #expect(session.pauseBeforeToolCalls(1) == .toolCalls)

        session.extendLimits()
        #expect(session.beginTurn() == nil)
        #expect(session.pauseBeforeToolCalls(1) == nil)
        #expect(session.observeOutput("123456789012") == .outputTokens)

        var oversizedBatch = AgentWorkSession(
            conversationID: UUID(), autopilot: false,
            limits: AgentWorkLimits(outputTokens: 0, modelTurns: 0, toolCalls: 2))
        oversizedBatch.recordToolCalls(1)
        #expect(oversizedBatch.pauseBeforeToolCalls(3) == .toolCalls)
        oversizedBatch.extendLimits(requiredToolCalls: 3)
        #expect(oversizedBatch.pauseBeforeToolCalls(3) == nil)
    }

    @Test("zero disables user limits")
    func zeroDisablesLimits() {
        var session = AgentWorkSession(
            conversationID: UUID(), autopilot: false,
            limits: AgentWorkLimits(outputTokens: 0, modelTurns: 0, toolCalls: 0))
        for _ in 0..<20 { #expect(session.beginTurn() == nil) }
        #expect(session.observeOutput(String(repeating: "x", count: 100_000)) == nil)
        #expect(session.pauseBeforeToolCalls(500) == nil)
    }

    @Test("Autopilot has hard ceilings independent of user soft limits")
    func autopilotHardCeilings() {
        var session = AgentWorkSession(
            conversationID: UUID(), autopilot: true,
            limits: AgentWorkLimits(outputTokens: 1, modelTurns: 1, toolCalls: 1))
        for _ in 0..<AgentWorkSession.autopilotTurnCeiling {
            #expect(session.beginTurn() == nil)
        }
        #expect(session.beginTurn() == .safetyCeiling)
        #expect(session.pauseBeforeToolCalls(AgentWorkSession.autopilotToolCallCeiling) == nil)
        #expect(session.pauseBeforeToolCalls(AgentWorkSession.autopilotToolCallCeiling + 1) == .safetyCeiling)
    }

    @Test("repeated-line guard handles stream chunks and ignores short lines")
    func repeatedLinesAcrossChunks() {
        var guardrail = RepeatedLineGuard()
        #expect(guardrail.consume("short\n") == nil)
        for _ in 0..<(RepeatedLineGuard.repetitionLimit - 1) {
            #expect(guardrail.consume("A long repeated line split") == nil)
            #expect(guardrail.consume(" across deltas\n") == nil)
        }
        #expect(guardrail.consume("A long repeated line split") == nil)
        #expect(guardrail.consume(" across deltas\n") == "A long repeated line split across deltas")
    }
}

@Suite("Agent work settings")
@MainActor
struct AgentWorkSettingsTests {
    @Test("legacy response cap migrates to a soft work budget and chat has no fixed cap")
    func legacyTokenSettingMigration() {
        let suite = "AgentWorkSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2_048, forKey: "konishi.maxTokens")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.workOutputTokenLimit == 2_048)
        #expect(settings.requestConfig(modelOverride: nil).maxTokens == nil)
    }
}