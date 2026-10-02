import Foundation

extension AppModel {
    func beginAgentWork(conversationID: UUID) {
        autopilotPermissionDenials = 0
        autopilotBlockedCapabilities = []
        autopilotRunConversationID = autopilotArmed ? conversationID : nil
        workSession = AgentWorkSession(
            conversationID: conversationID,
            autopilot: autopilotArmed,
            limits: AgentWorkLimits(
                outputTokens: settings.workOutputTokenLimit,
                modelTurns: settings.workTurnLimit,
                toolCalls: settings.workToolCallLimit))
        isAutopilotActive = autopilotArmed
        autopilotArmed = false
    }

    func pauseAgentWork(reason: AgentWorkPauseReason, batch: PendingToolBatch? = nil) {
        guard let session = workSession else { return }
        if session.autopilot {
            stopAutopilot(reason: reason, batch: batch)
            return
        }
        pendingWorkGate = PendingWorkGate(
            conversationID: session.conversationID, reason: reason, batch: batch)
        activity = nil
        isStreaming = false
        streamingConversationID = nil
    }

    func continueAgentWork() {
        guard let gate = pendingWorkGate, var session = workSession else { return }
        session.extendLimits(requiredToolCalls: gate.batch?.calls.count ?? 0)
        workSession = session
        pendingWorkGate = nil
        let note = "The user approved continuing after this work limit: \(gate.reason.title) Continue from the existing conversation state; do not repeat completed work."
        if var batch = gate.batch {
            batch.continuationNote = note
            routeToolBatch(batch)
        } else {
            appendWorkNotice(note, conversationID: gate.conversationID)
            startTurn(conversationID: gate.conversationID)
        }
    }

    func stopAgentWork() {
        guard let gate = pendingWorkGate else { return }
        if let batch = gate.batch {
            closePendingToolCalls(batch, message: "Not run: the user stopped this work session.")
        }
        appendWorkNotice(
            "The previous work session stopped at its configured limit (\(gate.reason.title)). The user chose not to continue that run. Treat their next message as the new instruction; do not resume automatically.",
            conversationID: gate.conversationID)
        finishAgentWork()
    }

    func finishAgentWork() {
        workSession = nil
        isAutopilotActive = false
        pendingWorkGate = nil
        isStreaming = false
        streamingConversationID = nil
        activity = nil
    }

    func stopAutopilot(reason: AgentWorkPauseReason, batch: PendingToolBatch? = nil) {
        guard let session = workSession else { return }
        if let batch {
            closePendingToolCalls(batch, message: "Not run: Autopilot stopped at its safety ceiling.")
        }
        appendWorkNotice(
            "Autopilot stopped because it reached a safety limit (\(reason.title)). Do not continue autonomously; wait for the user's next message.",
            conversationID: session.conversationID)
        errorMessage = "Autopilot stopped: \(reason.title)"
        finishAgentWork()
    }

    func stopAutopilotForPermissionDenials(capability: String) {
        guard let session = workSession else { return }
        appendWorkNotice(
            "Autopilot stopped after \(autopilotPermissionDenials) denied calls. The latest blocked capability was \(capability). Do not resume autonomously; wait for the user's next message.",
            conversationID: session.conversationID)
        errorMessage = "Autopilot stopped after repeated permission denials (\(capability))."
        finishAgentWork()
    }

    func appendWorkNotice(_ text: String, conversationID: UUID) {
        guard let index = ensureHydratedIndex(conversationID) else { return }
        conversations[index].messages.removeAll {
            $0.role == .system && $0.content.hasPrefix("[Konishi work-session note]")
        }
        conversations[index].messages.append(
            ChatMessage(role: .system, content: "[Konishi work-session note] \(text)"))
        touch(index)
    }

    func clearWorkNotices(conversationID: UUID) {
        guard let index = ensureHydratedIndex(conversationID) else { return }
        let oldCount = conversations[index].messages.count
        conversations[index].messages.removeAll {
            $0.role == .system && $0.content.hasPrefix("[Konishi work-session note]")
        }
        if conversations[index].messages.count != oldCount { touch(index) }
    }

    func closePendingToolCalls(
        _ batch: PendingToolBatch, message: String, calls: [ToolCall]? = nil
    ) {
        guard let index = ensureHydratedIndex(batch.conversationID) else { return }
        for call in calls ?? batch.calls {
            conversations[index].messages.append(
                ChatMessage(
                    role: .tool, content: message,
                    toolCallId: call.id, toolName: call.function.name))
        }
        touch(index)
    }

    func observeAgentOutput(_ text: String) -> AgentWorkPauseReason? {
        guard var session = workSession else { return nil }
        let reason = session.observeOutput(text)
        workSession = session
        return reason
    }

    func recordAgentToolCalls(_ count: Int) {
        guard var session = workSession else { return }
        session.recordToolCalls(count)
        workSession = session
    }

    func recordAgentLoopRecovery() -> Bool {
        guard var session = workSession else { return false }
        let shouldRetry = session.recordLoopRecovery()
        workSession = session
        return shouldRetry
    }
}