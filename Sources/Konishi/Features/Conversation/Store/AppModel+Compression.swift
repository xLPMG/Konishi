import Foundation

extension AppModel {
    private func estimateTokens(_ msgs: [ChatMessage]) -> Int {
        msgs.reduce(0) {
            $0 + $1.content.utf8.count / 4 + $1.attachmentBytes / 4 + $1.images.count * 600
        }
    }

    /// Runs a short background task on Apple's on-device model (ANE), falling back to the server
    /// when it's unavailable. Used by the "On-device" choice of a per-task model picker, so it is
    /// intentionally independent of the titles/triage on-device toggle.
    private func onDeviceComplete(prompt: String, config: RequestConfig, temperature: Double? = nil)
        async -> String?
    {
        if OnDeviceLLM.isAvailable,
            let out = await OnDeviceLLM.complete(prompt: prompt, temperature: temperature)
        {
            return out
        }
        return try? await ChatService.complete(
            config: config, messages: [WireMessage(role: Role.user.rawValue, text: prompt)])
    }

    func compressIfNeeded(conversationID: UUID) {
        guard settings.compressionEnabled, !isCompressing,
            let idx = conversationIndex(conversationID)
        else { return }

        let msgs = conversations[idx].messages
        let start = min(conversations[idx].summarizedCount ?? 0, msgs.count)
        let recent = Array(msgs[start...])
        guard estimateTokens(recent) > settings.compressionBudget else { return }
        guard let lastUserRel = recent.lastIndex(where: { $0.role == .user }) else { return }

        // Walk back from the end; keep whole turns that fit, fold the rest at a user boundary.
        var keepFromRel = lastUserRel
        var acc = 0
        var i = recent.count - 1
        while i >= 0 {
            acc += estimateTokens([recent[i]])
            if acc > settings.compressionBudget { break }
            if recent[i].role == .user { keepFromRel = i }
            i -= 1
        }
        let foldEnd = start + min(keepFromRel, lastUserRel)
        guard foldEnd > start else { return }

        let toFold = Array(msgs[start..<foldEnd])
        guard !toFold.isEmpty else { return }

        let persona = personaStore.persona(for: conversations[idx])
        let existing = conversations[idx].summary ?? ""
        let transcript =
            toFold
            .filter { !$0.content.isEmpty }
            .map { "\($0.role.rawValue.uppercased()): \($0.content)" }
            .joined(separator: "\n\n")
        let instruction = """
            \(MemoryProfile.contentPolicy)

            You maintain a running summary of a long conversation so older turns can be dropped from context. \
            Rewrite the EXISTING SUMMARY together with the NEW MESSAGES into one tighter summary.

            Rules:
            - Synthesize in your own words. NEVER quote or reproduce message text, code, commands, or markdown formatting.
            - Keep only durable, reusable information: facts about the user, decisions made, stated preferences, \
            names/identifiers, and unresolved questions or open threads.
            - Drop pleasantries, meta-talk, and restatements. Merge duplicates and compress older points harder as it grows.
            - Write terse plain-text bullet points. No headings, no code blocks, one short line each.
            - Be brief: aim for well under 300 words total.

            Output ONLY the updated summary.

            EXISTING SUMMARY:
            \(existing.isEmpty ? "(none)" : existing)

            NEW MESSAGES:
            \(transcript)
            """
        // The summary is re-sent every turn, so cap it well below the live budget (≈¼) — otherwise
        // folding stops saving space and a rolling summary can grow unbounded.
        let summaryCap = max(256, settings.compressionBudget / 4)
        var config = settings.requestConfig(modelOverride: persona.model)
        config.maxTokens = min(config.maxTokens ?? summaryCap, summaryCap)
        if settings.disableThinkingForTasks { config.enableThinking = false }
        let useServer = settings.compressionUseServer

        isCompressing = true
        Task { [weak self] in
            defer { self?.isCompressing = false }
            guard let self else { return }
            let result: String?
            if useServer {
                result = try? await ChatService.complete(
                    config: config,
                    messages: [WireMessage(role: Role.user.rawValue, text: instruction)])
            } else {
                result = await self.onDeviceComplete(prompt: instruction, config: config)
            }
            guard let result else { return }
            let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, let i = self.ensureHydratedIndex(conversationID) else { return }
            self.conversations[i].summary = clean
            self.conversations[i].summarizedCount = foldEnd
            let detail = """
                ── folded messages (\(toFold.count)) ──
                \(transcript)

                ── previous summary ──
                \(existing.isEmpty ? "(none)" : existing)

                ── new summary ──
                \(clean)
                """
            traceStore.trace(
                conversationID: conversationID, kind: .compress,
                text:
                    "folded \(toFold.count) old messages into summary (\(clean.count) chars); \(self.conversations[i].messages.count - foldEnd) kept live",
                saveTraces: settings.saveTraces,
                detail: detail)
            self.touch(i)
        }
    }
}
