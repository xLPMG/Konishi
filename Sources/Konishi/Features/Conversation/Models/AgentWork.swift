import Foundation

struct AgentWorkLimits: Equatable, Sendable {
    var outputTokens: Int
    var modelTurns: Int
    var toolCalls: Int

    static let defaults = AgentWorkLimits(outputTokens: 8_192, modelTurns: 8, toolCalls: 24)
}

enum AgentTaskEntry {
    static func isAvailable(
        isStreaming: Bool,
        awaitingToolApproval: Bool,
        awaitingWorkDecision: Bool,
        finishingToolOperation: Bool
    ) -> Bool {
        !isStreaming && !awaitingToolApproval && !awaitingWorkDecision && !finishingToolOperation
    }
}

enum AgentToolLoopPolicy {
    static let permissionDenialCeiling = 5

    static func shouldStopAutopilotBatch(repeats: Int, autopilot: Bool) -> Bool {
        autopilot && repeats >= 3
    }

    static func shouldStopForPermissionDenials(count: Int, autopilot: Bool) -> Bool {
        autopilot && count >= permissionDenialCeiling
    }

    static func remainingCalls(after index: Int, in calls: [ToolCall]) -> [ToolCall] {
        Array(calls.dropFirst(index + 1))
    }
}

enum AgentWorkPauseReason: Equatable, Sendable {
    case outputTokens
    case modelTurns
    case toolCalls
    case responseLength
    case repeatedOutput
    case safetyCeiling

    var title: String {
        switch self {
        case .outputTokens: "The agent reached its output-token budget."
        case .modelTurns: "The agent reached its model-turn limit."
        case .toolCalls: "The agent reached its tool-call limit."
        case .responseLength: "The server stopped this response at its output limit."
        case .repeatedOutput: "The agent repeated the same output several times."
        case .safetyCeiling: "Autopilot reached its safety ceiling."
        }
    }
}

struct AgentWorkSession: Equatable, Sendable {
    static let autopilotTurnCeiling = 40
    static let autopilotToolCallCeiling = 120
    static let autopilotOutputTokenCeiling = 100_000
    static let maximumLoopRecoveries = 2

    let conversationID: UUID
    let autopilot: Bool
    let limits: AgentWorkLimits
    private(set) var turns = 0
    private(set) var toolCalls = 0
    private(set) var outputBytes = 0
    private(set) var loopRecoveries = 0
    private(set) var tokenCeiling: Int
    private(set) var turnCeiling: Int
    private(set) var toolCallCeiling: Int

    var estimatedOutputTokens: Int { (outputBytes + 3) / 4 }

    init(conversationID: UUID, autopilot: Bool, limits: AgentWorkLimits) {
        self.conversationID = conversationID
        self.autopilot = autopilot
        self.limits = limits
        self.tokenCeiling = limits.outputTokens
        self.turnCeiling = limits.modelTurns
        self.toolCallCeiling = limits.toolCalls
    }

    mutating func beginTurn() -> AgentWorkPauseReason? {
        if autopilot {
            guard turns < Self.autopilotTurnCeiling else { return .safetyCeiling }
        } else if turnCeiling > 0, turns >= turnCeiling {
            return .modelTurns
        }
        turns += 1
        return nil
    }

    mutating func observeOutput(_ text: String) -> AgentWorkPauseReason? {
        outputBytes += text.utf8.count
        if autopilot {
            return estimatedOutputTokens >= Self.autopilotOutputTokenCeiling ? .safetyCeiling : nil
        }
        guard tokenCeiling > 0, estimatedOutputTokens >= tokenCeiling else { return nil }
        return .outputTokens
    }

    func pauseBeforeToolCalls(_ count: Int) -> AgentWorkPauseReason? {
        guard count > 0 else { return nil }
        if autopilot {
            return toolCalls + count > Self.autopilotToolCallCeiling ? .safetyCeiling : nil
        }
        guard toolCallCeiling > 0, toolCalls + count > toolCallCeiling else { return nil }
        return .toolCalls
    }

    mutating func recordToolCalls(_ count: Int) {
        toolCalls += max(0, count)
    }

    mutating func extendLimits(requiredToolCalls: Int = 0) {
        if limits.outputTokens > 0 {
            tokenCeiling = max(tokenCeiling + limits.outputTokens, estimatedOutputTokens + limits.outputTokens)
        }
        if limits.modelTurns > 0 { turnCeiling += limits.modelTurns }
        if limits.toolCalls > 0 {
            toolCallCeiling = max(
                toolCallCeiling + limits.toolCalls, toolCalls + max(0, requiredToolCalls))
        }
    }

    mutating func recordLoopRecovery() -> Bool {
        loopRecoveries += 1
        return loopRecoveries < Self.maximumLoopRecoveries
    }
}

struct RepeatedLineGuard {
    static let repetitionLimit = 5
    private static let repeatedBlockLimit = 3
    private static let maxBlockLength = 8
    private static let maxTrackedLines = maxBlockLength * repeatedBlockLimit

    private var pending = ""
    private var recentLines: [String] = []

    mutating func consume(_ text: String) -> String? {
        pending += text
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            if let repeated = record(line) { return repeated }
        }
        return nil
    }

    mutating func finish() -> String? {
        let line = pending
        pending = ""
        return record(line)
    }

    private mutating func record(_ line: String) -> String? {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 12 else { return nil }

        recentLines.append(normalized)
        if recentLines.count > Self.maxTrackedLines {
            recentLines.removeFirst(recentLines.count - Self.maxTrackedLines)
        }

        if recentLines.count >= Self.repetitionLimit,
            Set(recentLines.suffix(Self.repetitionLimit)).count == 1
        {
            return normalized
        }

        let maxBlockLength = min(Self.maxBlockLength, recentLines.count / Self.repeatedBlockLimit)
        guard maxBlockLength >= 2 else { return nil }
        for blockLength in 2...maxBlockLength {
            let repeated = Array(recentLines.suffix(blockLength * Self.repeatedBlockLimit))
            let block = Array(repeated.prefix(blockLength))
            let isRepeated = (1..<Self.repeatedBlockLimit).allSatisfy { repetition in
                let start = repetition * blockLength
                return Array(repeated[start..<(start + blockLength)]) == block
            }
            if isRepeated { return block.joined(separator: "\n") }
        }
        return nil
    }
}