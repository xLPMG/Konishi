import Foundation

extension AppModel {

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftImages.isEmpty || !draftAttachments.isEmpty, !isStreaming,
            let convoID = selectedConversationID, let idx = conversationIndex(convoID)
        else { return }

        errorMessage = nil
        resetSpeech()
        let images = draftImages
        let attachments = draftAttachments
        draft = ""
        draftImages = []
        draftAttachments = []
        loopSignatures.removeAll()
        turnSources.removeAll()
        conversations[idx].messages.append(
            ChatMessage(role: .user, content: text, images: images, attachments: attachments))

        if conversations[idx].title == "New Chat", !text.isEmpty {
            conversations[idx].title = String(text.prefix(40))
        }
        touch(idx)
        startTurn(conversationID: convoID)
        maybeAutoTitle(conversationID: convoID)
    }

    func regenerate(messageID: UUID) {
        guard let convoID = selectedConversationID, let idx = conversationIndex(convoID),
            let msgIdx = conversations[idx].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        conversations[idx].messages.removeSubrange(msgIdx...)
        reconcileFoldCounters(idx)
        loopSignatures.removeAll()
        turnSources.removeAll()
        resetSpeech()
        touch(idx)
        startTurn(conversationID: convoID)
    }

    func deleteMessage(_ id: UUID) {
        guard let convoID = selectedConversationID, let idx = conversationIndex(convoID) else {
            return
        }
        conversations[idx].messages.removeAll { $0.id == id }
        reconcileFoldCounters(idx)
        touch(idx)
    }

    func startTurn(conversationID: UUID) {
        guard let idx = conversationIndex(conversationID) else { return }
        streamingConversationID = conversationID
        let assistant = ChatMessage(role: .assistant, content: "")
        conversations[idx].messages.append(assistant)
        runStream(conversationID: conversationID, assistantID: assistant.id)
    }

    private func runStream(conversationID: UUID, assistantID: UUID) {
        guard let idx = conversationIndex(conversationID) else { return }
        let persona = personaStore.persona(for: conversations[idx])
        let allHistory = conversations[idx].messages.filter { $0.id != assistantID }
        let folded = min(conversations[idx].summarizedCount ?? 0, allHistory.count)
        let history = Array(allHistory.dropFirst(folded))
        let summary = conversations[idx].summary ?? ""
        var config = settings.requestConfig(modelOverride: persona.model)
        config.enableThinking = settings.reasoningEnabled
        let tools: [ToolDef]?
        if mode == .language {
            tools = Tools.definitions(enabled: settings.enabledTools(for: .language))
        } else if settings.toolsEnabled {
            var enabled = settings.enabledTools(for: mode)
            if !persona.vaultAccessEnabled { enabled.subtract(Tools.vaultToolNames) }
            tools = Tools.definitions(enabled: enabled)
        } else {
            tools = nil
        }

        isStreaming = true
        activity = "Thinking…"
        streamTask?.cancel()  // never run two loops against one conversation
        let start = Date()

        streamTask = Task { [weak self] in
            guard let self else { return }
            let systemText =
                self.mode == .language
                ? languageSystemPrompt(persona: persona)
                : personaStore.stableSystemPrompt(
                    persona: persona, injectDateContext: settings.injectDateContext, mode: mode,
                    vaultConfigured: !settings.vaultPath.isEmpty)
            async let memTask = self.memoryContext(
                conversationID: conversationID, persona: persona, history: history)
            async let docTask = self.documentContext(
                conversationID: conversationID, history: history)
            async let vaultTask = self.vaultContext(
                conversationID: conversationID, persona: persona, history: history)
            let (memoryText, documentText, vaultText) = await (memTask, docTask, vaultTask)
            let wire = self.buildWire(
                systemText: systemText, summary: summary, memoryText: memoryText,
                documentText: documentText, vaultText: vaultText, history: history)

            traceStore.trace(
                conversationID: conversationID, kind: .request,
                text: self.requestSummary(
                    config: config, wire: wire, tools: tools, memory: memoryText, summary: summary),
                saveTraces: settings.saveTraces,
                detail: self.requestDetail(wire: wire))

            var firstTokenAt: Date?
            var firstGenerationAt: Date?
            var charCount = 0
            var deltaCount = 0
            var reasoning = ""
            var answer = ""
            var finishReason: String?
            var usage: Usage?
            var toolCalls: [ToolCall]?
            var caughtError = false
            var stripper = ThinkStripper()  // strip inline chain-of-thought some models emit as content
            do {
                for try await event in ChatService.stream(
                    config: config, messages: wire, tools: tools, toolChoice: nil)
                {
                    switch event {
                    case .delta(let d):
                        if firstGenerationAt == nil { firstGenerationAt = Date() }
                        if firstTokenAt == nil {
                            firstTokenAt = Date()
                            self.activity = nil
                            traceStore.trace(
                                conversationID: conversationID, kind: .token,
                                text: String(
                                    format: "First token after %.0f ms",
                                    Date().timeIntervalSince(start) * 1000),
                                saveTraces: settings.saveTraces)
                        }
                        let out = stripper.consume(d)
                        if !out.reasoning.isEmpty {
                            reasoning += out.reasoning
                            self.appendReasoning(
                                out.reasoning, conversationID: conversationID,
                                assistantID: assistantID)
                        }
                        if !out.visible.isEmpty {
                            deltaCount += 1
                            charCount += out.visible.count
                            answer += out.visible
                            self.appendDelta(
                                out.visible, conversationID: conversationID,
                                assistantID: assistantID)
                        }
                    case .reasoning(let r):
                        if !r.isEmpty && firstGenerationAt == nil { firstGenerationAt = Date() }
                        reasoning += r
                        self.appendReasoning(
                            r, conversationID: conversationID, assistantID: assistantID)
                    case .usage(let u):
                        usage = u
                        traceStore.trace(
                            conversationID: conversationID, kind: .usage,
                            text:
                                "prompt=\(u.promptTokens ?? 0), completion=\(u.completionTokens ?? 0), total=\(u.totalTokens ?? 0)",
                            saveTraces: settings.saveTraces)
                    case .toolCalls(let calls):
                        toolCalls = calls
                        for c in calls {
                            traceStore.trace(
                                conversationID: conversationID, kind: .tool,
                                text: "\(c.function.name ?? "tool")(\(c.function.arguments))",
                                saveTraces: settings.saveTraces)
                        }
                    case .finish(let reason):
                        finishReason = reason
                        traceStore.trace(
                            conversationID: conversationID, kind: .finish,
                            text:
                                "finish_reason=\(reason ?? "nil"), deltas=\(deltaCount), chars=\(charCount)",
                            saveTraces: settings.saveTraces)
                    }
                }
                let tail = stripper.finish()
                if !tail.reasoning.isEmpty { reasoning += tail.reasoning }
                if !tail.visible.isEmpty {
                    deltaCount += 1
                    charCount += tail.visible.count
                    answer += tail.visible
                    self.appendDelta(
                        tail.visible, conversationID: conversationID, assistantID: assistantID)
                }
                if !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    traceStore.trace(
                        conversationID: conversationID, kind: .reasoning,
                        text: reasoning,
                        saveTraces: settings.saveTraces)
                }
                if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    traceStore.trace(
                        conversationID: conversationID, kind: .result,
                        text: answer,
                        saveTraces: settings.saveTraces)
                }
                if deltaCount == 0 && (toolCalls?.isEmpty ?? true) {
                    if finishReason == "length" {
                        let hint =
                            "The model hit the token limit while reasoning and produced no answer. Raise Max tokens in Settings › Generation."
                        traceStore.trace(
                            conversationID: conversationID, kind: .info,
                            text: hint,
                            saveTraces: settings.saveTraces)
                        self.errorMessage = hint
                    } else {
                        traceStore.trace(
                            conversationID: conversationID, kind: .info,
                            text:
                                "No content received (empty reply). finish_reason=\(finishReason ?? "nil").",
                            saveTraces: settings.saveTraces)
                    }
                }
            } catch {
                caughtError = true
                self.errorMessage = error.localizedDescription
                traceStore.trace(
                    conversationID: conversationID, kind: .error,
                    text: error.localizedDescription,
                    saveTraces: settings.saveTraces)
            }
            self.finishStream(
                conversationID: conversationID,
                assistantID: assistantID,
                start: start,
                firstTokenAt: firstTokenAt,
                firstGenerationAt: firstGenerationAt,
                charCount: charCount,
                usage: usage,
                toolCalls: toolCalls,
                failed: caughtError
            )
        }
    }

    private func appendDelta(_ delta: String, conversationID: UUID, assistantID: UUID) {
        deltaBuffer += delta
        let interval = settings.streamFlushMs
        if interval <= 0 {
            flushDeltas(conversationID: conversationID, assistantID: assistantID)
            return
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(interval))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushDeltas(conversationID: conversationID, assistantID: assistantID)
        }
    }

    /// Apply the buffered tokens to the assistant message in a single mutation.
    private func flushDeltas(conversationID: UUID, assistantID: UUID) {
        guard !deltaBuffer.isEmpty else { return }
        let pending = deltaBuffer
        deltaBuffer = ""
        guard let idx = conversationIndex(conversationID),
            let mIdx = conversations[idx].messages.firstIndex(where: { $0.id == assistantID })
        else { return }
        conversations[idx].messages[mIdx].content += pending
        streamSpeak(delta: pending, assistantID: assistantID)
    }

    private func appendReasoning(_ chunk: String, conversationID: UUID, assistantID: UUID) {
        reasoningBuffer += chunk
        let interval = settings.streamFlushMs
        if interval <= 0 {
            flushReasoning(conversationID: conversationID, assistantID: assistantID)
            return
        }
        guard reasoningFlushTask == nil else { return }
        reasoningFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(interval))
            guard let self, !Task.isCancelled else { return }
            self.reasoningFlushTask = nil
            self.flushReasoning(conversationID: conversationID, assistantID: assistantID)
        }
    }

    private func flushReasoning(conversationID: UUID, assistantID: UUID) {
        guard !reasoningBuffer.isEmpty else { return }
        let pending = reasoningBuffer
        reasoningBuffer = ""
        guard let idx = conversationIndex(conversationID),
            let mIdx = conversations[idx].messages.firstIndex(where: { $0.id == assistantID })
        else { return }
        conversations[idx].messages[mIdx].reasoning =
            (conversations[idx].messages[mIdx].reasoning ?? "") + pending
    }

    private func finishStream(
        conversationID: UUID,
        assistantID: UUID,
        start: Date,
        firstTokenAt: Date?,
        firstGenerationAt: Date?,
        charCount: Int,
        usage: Usage?,
        toolCalls: [ToolCall]?,
        failed: Bool = false
    ) {
        streamTask = nil
        flushTask?.cancel()
        flushTask = nil
        flushDeltas(conversationID: conversationID, assistantID: assistantID)
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        flushReasoning(conversationID: conversationID, assistantID: assistantID)
        guard let idx = conversationIndex(conversationID),
            let mIdx = conversations[idx].messages.firstIndex(where: { $0.id == assistantID })
        else {
            isStreaming = false
            streamingConversationID = nil
            return
        }

        let hasTools = !(toolCalls?.isEmpty ?? true)
        let hasReasoning = !(conversations[idx].messages[mIdx].reasoning?.isEmpty ?? true)
        if conversations[idx].messages[mIdx].content.isEmpty, !hasTools, !hasReasoning {
            conversations[idx].messages.remove(at: mIdx)
            touch(idx)
            activity = nil
            isStreaming = false
            streamingConversationID = nil
            return
        }

        conversations[idx].messages[mIdx].stats = Self.makeStats(
            start: start, firstTokenAt: firstTokenAt, firstGenerationAt: firstGenerationAt,
            charCount: charCount, usage: usage
        )

        if let toolCalls, hasTools {
            conversations[idx].messages[mIdx].toolCalls = toolCalls
            touch(idx)
            let content = conversations[idx].messages[mIdx].content
            emitFinalSpeech(assistantID: assistantID, content: content)
            // Only loop back for another turn if the model must act on a tool's OUTPUT. A written
            // reply plus fire-and-forget writes (e.g. banking a card) is already a complete answer.
            let batch = PendingToolBatch(
                conversationID: conversationID, calls: toolCalls,
                continueAfter: Self.needsToolContinuation(content: content, calls: toolCalls))
            let names = toolCalls.compactMap { $0.function.name }
            if !names.isEmpty && toolCalls.allSatisfy({ toolCallIsAutoApproved($0, mode: mode) }) {
                activity = "Calling \(names.joined(separator: ", "))…"
                executeAndContinue(batch: batch, approved: true)  // auto-approved: keeps streaming
            } else {
                activity = nil
                isStreaming = false
                streamingConversationID = nil
                pendingApproval = batch
            }
            return
        }

        touch(idx)
        if !turnSources.isEmpty {
            conversations[idx].messages[mIdx].sources = turnSources
            turnSources.removeAll()
            touch(idx)
        }
        activity = nil
        isStreaming = false
        streamingConversationID = nil
        compressIfNeeded(conversationID: conversationID)
        updateMemoryIfNeeded(conversationID: conversationID)
        maybeRefineTitle(conversationID: conversationID)
        emitFinalSpeech(
            assistantID: assistantID, content: conversations[idx].messages[mIdx].content)
    }

    static func needsToolContinuation(content: String, calls: [ToolCall]) -> Bool {
        content.trimmingCharacters(in: .whitespaces).isEmpty
            || calls.contains { continuationTools.contains($0.function.name ?? "") }
    }

    static func makeStats(
        start: Date, firstTokenAt: Date?, firstGenerationAt: Date?, charCount: Int,
        usage: Usage?, end: Date = Date()
    )
        -> MessageStats
    {
        let duration = end.timeIntervalSince(start)
        let ttft = firstTokenAt?.timeIntervalSince(start)
        let completion = usage?.completionTokens
        let genSeconds = firstGenerationAt.map { end.timeIntervalSince($0) } ?? duration
        let tps: Double? = {
            if let completion, genSeconds > 0 { return Double(completion) / genSeconds }
            if genSeconds > 0 { return (Double(charCount) / 4.0) / genSeconds }
            return nil
        }()
        return MessageStats(
            timeToFirstToken: ttft,
            tokensPerSecond: tps,
            promptTokens: usage?.promptTokens,
            completionTokens: completion,
            totalTokens: usage?.totalTokens,
            duration: duration
        )
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        cancelInteraction()  // resume/clear any paused multiple-choice prompt
        resetSpeech()
        flushTask?.cancel()
        flushTask = nil
        deltaBuffer = ""
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        reasoningBuffer = ""
        streamingConversationID = nil
        activity = nil
        isStreaming = false
    }

    func buildWire(
        systemText: String,
        summary: String,
        memoryText: String,
        documentText: String = "",
        vaultText: String = "",
        history: [ChatMessage]
    ) -> [WireMessage] {
        var wire: [WireMessage] = []
        if !systemText.isEmpty {
            wire.append(WireMessage(role: Role.system.rawValue, text: systemText))
        }
        let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryText.isEmpty {
            wire.append(
                WireMessage(
                    role: Role.system.rawValue,
                    text: "# Summary of earlier conversation\n\(summaryText)"))
        }
        let budgeted = budget(history: history)
        let memory = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let retrievedDocs = documentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let vaultNotes = vaultText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastUserIdx = budgeted.lastIndex(where: { $0.role == .user })
        // Keep only the most recent tool outputs verbatim; older ones are re-sent every
        // turn otherwise, so collapse them to a stub to save context.
        let keepFullTool = Set(
            budgeted.indices.filter { budgeted[$0].role == .tool }.suffix(Self.maxFullToolResults))
        for (i, msg) in budgeted.enumerated() {
            switch msg.role {
            case .system:
                continue
            case .tool:
                let content = keepFullTool.contains(i) ? msg.content : Self.stubToolResult(msg)
                wire.append(
                    .toolResult(
                        id: msg.toolCallId ?? "", name: msg.toolName ?? "tool", content: content))
            case .assistant:
                let assistantText =
                    msg.interrupted
                    ? msg.content + "\n\n[Response interrupted by the user.]"
                    : msg.content
                if let calls = msg.toolCalls, !calls.isEmpty {
                    wire.append(
                        WireMessage(
                            role: "assistant",
                            content: assistantText.isEmpty ? nil : .text(assistantText),
                            toolCalls: calls
                        ))
                } else {
                    wire.append(WireMessage(role: "assistant", text: assistantText))
                }
            case .user:
                // Attach memory to the latest user turn only → stable prefix, cache-friendly.
                var text = msg.content
                if !msg.attachments.isEmpty {
                    let docs = msg.attachments
                        .map { "# Attached file: \($0.name)\n\($0.text)" }
                        .joined(separator: "\n\n")
                    text = text.isEmpty ? docs : docs + "\n\n---\n\n" + text
                }
                if i == lastUserIdx, !retrievedDocs.isEmpty {
                    text =
                        "# Relevant excerpts from attached documents\n\(retrievedDocs)\n\n---\n\n"
                        + text
                }
                if i == lastUserIdx, !vaultNotes.isEmpty {
                    text =
                        "# Relevant notes from your research vault\n\(vaultNotes)\n\n---\n\n"
                        + text
                }
                if i == lastUserIdx, !memory.isEmpty {
                    text = "# Relevant memory\n\(memory)\n\n---\n\n" + text
                }
                if msg.images.isEmpty || !settings.sendImagesToModel {
                    wire.append(WireMessage(role: "user", text: text))
                } else {
                    var parts: [ContentPart] = []
                    if !text.isEmpty { parts.append(.text(text)) }
                    parts.append(contentsOf: msg.images.map { .image($0) })
                    wire.append(WireMessage(role: "user", parts: parts))
                }
            }
        }
        return wire
    }

    /// Keep the most recent turns that fit the model's context window.
    private func budget(history: [ChatMessage]) -> [ChatMessage] {
        guard let window = contextWindow else { return history }
        let reserve = max(settings.effectiveMaxTokens ?? 1024, 512)
        let budgetTokens = max(1000, window - reserve - 256)
        var total = 0
        var kept: [ChatMessage] = []
        for msg in history.reversed() {
            let est = msg.content.utf8.count / 4 + msg.attachmentBytes / 4 + msg.images.count * 600
            if total + est > budgetTokens, !kept.isEmpty { break }
            total += est
            kept.insert(msg, at: 0)
        }
        // Never start the window on an orphaned tool result: its assistant `tool_calls` parent may
        // have been dropped, and servers reject a `tool` message with no preceding `tool_calls`.
        while let first = kept.first, first.role == .tool {
            kept.removeFirst()
        }
        return kept
    }
}
