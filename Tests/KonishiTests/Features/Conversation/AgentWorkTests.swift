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

    @Test("Autopilot stops after the permission-denial ceiling")
    func permissionDenialsStopAutopilot() {
        #expect(!AgentToolLoopPolicy.shouldStopForPermissionDenials(count: 4, autopilot: true))
        #expect(AgentToolLoopPolicy.shouldStopForPermissionDenials(
            count: AgentToolLoopPolicy.permissionDenialCeiling, autopilot: true))
        #expect(!AgentToolLoopPolicy.shouldStopForPermissionDenials(
            count: AgentToolLoopPolicy.permissionDenialCeiling, autopilot: false))
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

    @Test("repeated multi-line reasoning blocks are caught across blank lines")
    func repeatedBlocksAcrossBlankLines() {
        var guardrail = RepeatedLineGuard()
        let block = [
            "The same first reasoning line repeats.",
            "The same second reasoning line repeats.",
            "The same third reasoning line repeats.",
        ]

        for repetition in 0..<3 {
            for (lineIndex, line) in block.enumerated() {
                let result = guardrail.consume(line + "\n")
                if repetition == 2 && lineIndex == block.count - 1 {
                    #expect(result != nil)
                } else {
                    #expect(result == nil)
                }
            }
            if repetition < 2 {
                #expect(guardrail.consume("\n") == nil)
            }
        }
    }

    @Test("different lines do not trigger the repeated-block guard")
    func distinctLinesDoNotTriggerRepeatGuard() {
        var guardrail = RepeatedLineGuard()
        for index in 0..<12 {
            #expect(guardrail.consume("A distinct reasoning line number \(index).\n") == nil)
        }
    }
}

@Suite("Agent work settings")
@MainActor
struct AgentWorkSettingsTests {
    @Test("current output limit is a soft work budget and chat has no fixed cap")
    func currentOutputLimitIsSoftBudget() {
        let suite = "AgentWorkSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2_048, forKey: "konishi.workOutputTokenLimit")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.workOutputTokenLimit == 2_048)
        #expect(settings.requestConfig(modelOverride: nil).maxTokens == nil)
    }
}