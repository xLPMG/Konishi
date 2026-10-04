import Foundation

extension AppModel {
    /// Dynamic memory for this turn (attached to the latest user message, not the system prompt):
    /// the user's profile, the most relevant long-term and short-term facts, and summaries of
    /// relevant past conversations.
    func memoryContext(conversationID: UUID, persona: Persona, history: [ChatMessage]) async
        -> String
    {
        guard settings.injectMemory else { return "" }
        let scopes = [MemoryStore.globalScope, persona.memoryScope]
        let query = history.last(where: { $0.role == .user })?.content ?? ""
        let config = settings.requestConfig(modelOverride: nil)
        let result = await memoryStore.retrieve(
            scopes: scopes, query: query, cache: embeddingCache,
            requestConfig: config,
            threshold: settings.memoryThreshold, topK: settings.memoryTopK,
            shortTerm: stm.facts
        )
        guard !Task.isCancelled else { return "" }
        stm.markRetrieved(result.stmHits, in: conversationID)
        if let trace = result.trace {
            traceStore.trace(
                conversationID: conversationID, kind: trace.kind, text: trace.text,
                saveTraces: settings.saveTraces, detail: trace.detail)
        }
        let past = await recallPastConversations(
            conversationID: conversationID, query: query, config: config)
        guard !Task.isCancelled else { return "" }
        return [result.text, past].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// After a completed turn, fold new messages into memory once enough fresh user turns
    /// have accumulated. The extractor itself decides whether anything is worth saving (it
    /// returns no operations when nothing is durable) and refreshes the conversation digest.
    /// New facts land in short-term memory; the sleep pass promotes and tidies them later.
    func updateMemoryIfNeeded(conversationID: UUID) {
        scheduleSleepPass(after: Self.sleepIdleDelay)
        guard settings.autoMemory, !settings.pauseMemoryWrites, !isMemorizing, !isReflecting,
            let idx = conversationIndex(conversationID)
        else { return }
        let convo = conversations[idx]
        let start = min(convo.memorizedCount ?? 0, convo.messages.count)
        let fresh = Array(convo.messages[start...])
        let newUserTurns = fresh.filter { $0.role == .user && !$0.content.isEmpty }.count
        guard newUserTurns >= max(1, settings.autoMemoryEvery) else { return }
        runMemoryMaintenance(
            conversationID: conversationID, messages: fresh, upTo: convo.messages.count,
            consolidate: false)
    }

    /// Manual "Update Memory": extract durable facts from the whole conversation using the
    /// same safe, additive delta path as the automatic pass (no full rewrite).
    func reflect() {
        guard let convo = selectedConversation, !convo.messages.isEmpty,
            !isReflecting, !isMemorizing
        else { return }
        runMemoryMaintenance(
            conversationID: convo.id, messages: convo.messages, upTo: convo.messages.count,
            consolidate: false)
    }

    /// Manual "Clean Up Memory": a full dedup/reorganize rewrite of the whole memory, backed up
    /// first so it is reversible.
    func consolidateMemory() {
        guard let convo = selectedConversation, !convo.messages.isEmpty,
            !isReflecting, !isMemorizing
        else { return }
        runMemoryMaintenance(
            conversationID: convo.id, messages: convo.messages, upTo: convo.messages.count,
            consolidate: true)
    }

    /// Merge `messages` into the persona's categorized memory files.
    /// Consolidation rewrites the full profile; incremental maintenance applies typed deltas, stages
    /// new facts in short-term memory, and refreshes the conversation digest. With `upTo == nil`
    /// (sleep-pass cleanup) no conversation is consumed and its counters are left untouched.
    func runMemoryMaintenance(
        conversationID: UUID, messages: [ChatMessage], upTo: Int?, consolidate: Bool
    ) {
        guard let idx = conversationIndex(conversationID) else { return }
        let convo = conversations[idx]
        let persona = personaStore.persona(for: convo)
        let personaScope = persona.memoryScope
        let globalScope = MemoryStore.globalScope
        let userText =
            messages
            .filter { $0.role == .user && !$0.content.isEmpty }
            .map(\.content)
            .joined(separator: "\n")
        let transcript =
            messages
            .filter { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty }
            .map { "\($0.role == .user ? "USER" : "ASSISTANT"): \($0.content)" }
            .joined(separator: "\n\n")
        guard !transcript.isEmpty || upTo == nil else { return }
        let promptTranscript =
            transcript.isEmpty ? "(none — only tidy the existing memory)" : transcript

        stm.tick()
        let pending = stm.pendingLines(scopes: [globalScope, personaScope])
        let snapshot =
            consolidate
            ? MemoryProfile.snapshot(store: memoryStore, global: globalScope, persona: personaScope)
            : MemoryProfile.relevantSnapshot(
                store: memoryStore, global: globalScope, persona: personaScope,
                pending: pending, query: userText)
        let beforeMemory = Dictionary(
            uniqueKeysWithValues: MemoryProfile.contents(
                store: memoryStore, global: globalScope, persona: personaScope))
        let extra = settings.reflectionCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = personaStore.assistantName(for: persona)
        let now = DateContext.current()
        let instruction =
            consolidate
            ? MemoryProfile.consolidatePrompt(
                current: snapshot, transcript: promptTranscript, extra: extra,
                assistantName: assistant, now: now)
            : MemoryProfile.maintainerPrompt(
                current: snapshot, transcript: promptTranscript, extra: extra,
                assistantName: assistant, now: now, currentDigest: convo.digest)
        // Gemma/Qwen-style thinking is wasteful for this mechanical rewrite: disable it and cap output.
        var config = settings.requestConfig(modelOverride: persona.model)
        if settings.disableThinkingForTasks { config.enableThinking = false }
        config.maxTokens = min(config.maxTokens ?? 2000, 2000)

        isReflecting = true
        isMemorizing = true
        traceStore.trace(
            conversationID: conversationID, kind: .memory,
            text: consolidate
                ? "consolidating memory (\(personaScope))…"
                : "auto memory: updating (\(personaScope))…",
            saveTraces: settings.saveTraces)
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isReflecting = false
                self.isMemorizing = false
            }
            let rawResult: String?
            do {
                rawResult = try await ChatService.completeStreaming(
                    config: config,
                    messages: [WireMessage(role: Role.user.rawValue, text: instruction)])
            } catch {
                traceStore.trace(
                    conversationID: conversationID, kind: .error,
                    text:
                        "\(consolidate ? "memory cleanup" : "auto memory") failed: \(error.localizedDescription)",
                    saveTraces: settings.saveTraces)
                return
            }
            guard let rawResult, !rawResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                traceStore.trace(
                    conversationID: conversationID, kind: .error,
                    text: "memory update produced no output (model returned an empty reply)",
                    saveTraces: settings.saveTraces)
                return
            }
            guard let result = AuxiliaryPromptGuidance.content(from: rawResult) else {
                let reason = AuxiliaryPromptGuidance.blockedReason(from: rawResult)
                    ?? "model returned no usable content"
                traceStore.trace(
                    conversationID: conversationID, kind: .error,
                    text: "memory update not applied: \(reason)",
                    saveTraces: settings.saveTraces)
                return
            }
            guard !AuxiliaryPromptGuidance.looksLikeRefusal(result) else {
                traceStore.trace(
                    conversationID: conversationID, kind: .error,
                    text: "memory update not applied: model returned a refusal instead of structured data",
                    saveTraces: settings.saveTraces)
                return
            }
            var traceDetail: String?
            var operationSummary = ""
            var newDigest: String?
            if consolidate {
                let sections = MemoryProfile.parse(result)
                guard MemoryCategory.allCases.allSatisfy({ sections[$0] != nil }) else {
                    traceStore.trace(
                        conversationID: conversationID, kind: .error,
                        text:
                            "memory consolidation skipped: output was missing one or more category sections",
                        saveTraces: settings.saveTraces)
                    return
                }
                if let backupURL = self.memoryStore.backup(scopes: [globalScope, personaScope]) {
                    traceStore.trace(
                        conversationID: conversationID, kind: .memory,
                        text: "backed up memory before cleanup → \(backupURL.lastPathComponent)",
                        saveTraces: settings.saveTraces)
                }
                var lintFixes: [String] = []
                for cat in MemoryCategory.allCases {
                    let target = cat.targetScope(global: globalScope, persona: personaScope)
                    let raw = (sections[cat] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let clean = MemoryProfile.canonical(raw)
                    if clean.isEmpty {
                        self.memoryStore.delete(scope: target, name: cat.fileName)
                    } else {
                        if clean != raw { lintFixes.append(cat.header) }
                        self.memoryStore.write(scope: target, name: cat.fileName, content: clean)
                    }
                }
                if !lintFixes.isEmpty {
                    operationSummary = "; fixed formatting (\(lintFixes.joined(separator: ", ")))"
                }
                let afterMemory = Dictionary(
                    uniqueKeysWithValues: MemoryProfile.contents(
                        store: self.memoryStore, global: globalScope, persona: personaScope))
                let changes = MemoryProfile.diff(before: beforeMemory, after: afterMemory)
                traceDetail = changes.isEmpty ? "(no file changes)" : changes
            } else {
                guard let delta = MemoryProfile.parseDelta(result) else {
                    traceStore.trace(
                        conversationID: conversationID, kind: .error,
                        text: "memory update skipped: could not parse typed operations from output",
                        saveTraces: settings.saveTraces)
                    return
                }
                let application = MemoryProfile.apply(
                    delta, store: self.memoryStore, global: globalScope, persona: personaScope,
                    pending: pending)
                for (cat, body) in application.changedBodies {
                    let target = cat.targetScope(global: globalScope, persona: personaScope)
                    if body.isEmpty {
                        self.memoryStore.delete(scope: target, name: cat.fileName)
                    } else {
                        self.memoryStore.write(scope: target, name: cat.fileName, content: body)
                    }
                }
                self.stm.apply(
                    application, global: globalScope, persona: personaScope,
                    conversationID: conversationID)
                let digest = delta.digest?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !digest.isEmpty { newDigest = String(digest.prefix(1200)) }
                operationSummary =
                    "; \(application.appliedCount) applied (\(application.staged.count) staged), \(application.skippedCount) skipped"
                    + (newDigest == nil ? "" : "; digest updated")
                traceDetail =
                    application.detail + (newDigest.map { "\n\n── digest ──\n\($0)" } ?? "")
            }
            if let upTo, let i = self.ensureHydratedIndex(conversationID) {
                let count = self.conversations[i].messages.count
                self.conversations[i].memorizedCount = min(upTo, count)
                if let newDigest {
                    self.conversations[i].digest = newDigest
                    self.conversations[i].digestCount = min(upTo, count)
                    self.conversations[i].digestRolledUpAt = nil
                }
                self.touch(i)
                // Messages that arrived during extraction are not covered, so leave the digest stale.
                if newDigest != nil, count == upTo {
                    self.conversations[i].digestUpdatedAt = self.conversations[i].updatedAt
                    self.save(self.conversations[i])
                }
            }
            if consolidate {
                self.stm.setConsolidated(
                    self.memoryStore.bulletCount(in: globalScope)
                        + self.memoryStore.bulletCount(in: personaScope),
                    scope: personaScope)
            }
            let how = consolidate ? "cleaned up" : "updated"
            traceStore.trace(
                conversationID: conversationID, kind: .memory,
                text:
                    "\(how) long-term memory (\(personaScope)) from \(messages.count) messages\(operationSummary)",
                saveTraces: settings.saveTraces,
                detail: traceDetail
            )
        }
    }
}
