import Foundation

extension AppModel {
    /// Dynamic memory for this turn (attached to the latest user message, not the system prompt).
    func memoryContext(conversationID: UUID, persona: Persona, history: [ChatMessage]) async
        -> String
    {
        // Language sessions get a compact deck summary instead of personal memory (the deck is the memory).
        if isLanguageConversation(conversationID) { return languageDeckContext() }
        guard settings.injectMemory else { return "" }
        let scopes = [MemoryStore.globalScope, persona.memoryScope]
        let query = history.last(where: { $0.role == .user })?.content ?? ""
        let result = await memoryStore.retrieve(
            scopes: scopes, query: query, cache: embeddingCache,
            requestConfig: settings.requestConfig(modelOverride: nil),
            threshold: settings.memoryThreshold, topK: settings.memoryTopK
        )
        if let trace = result.trace {
            traceStore.trace(
                conversationID: conversationID, kind: trace.kind, text: trace.text,
                saveTraces: settings.saveTraces, detail: trace.detail)
        }
        return result.text
    }

    /// After a completed turn, fold new messages into memory once enough fresh user turns
    /// have accumulated. The extractor itself decides whether anything is worth saving (it
    /// returns no operations when nothing is durable). Escalates to a full consolidation once
    /// the memory has grown large, so it stays deduped and compact without manual effort.
    func updateMemoryIfNeeded(conversationID: UUID) {
        guard settings.autoMemory, !settings.pauseMemoryWrites, !isMemorizing, !isReflecting,
            let idx = conversationIndex(conversationID)
        else { return }
        let convo = conversations[idx]
        guard convo.isLanguage != true else { return }  // language chats never feed personal memory
        let start = min(convo.memorizedCount ?? 0, convo.messages.count)
        let fresh = Array(convo.messages[start...])
        let newUserTurns = fresh.filter { $0.role == .user && !$0.content.isEmpty }.count
        guard newUserTurns >= max(1, settings.autoMemoryEvery) else { return }
        let scope = personaStore.persona(for: convo).memoryScope
        let bullets =
            memoryStore.bulletCount(in: MemoryStore.globalScope)
            + memoryStore.bulletCount(in: scope)
        let consolidate =
            settings.autoConsolidate
            && bullets >= max(10, settings.autoConsolidateThreshold)
            && bullets > (lastConsolidatedBullets[scope] ?? 0)
        runMemoryMaintenance(
            conversationID: conversationID, messages: fresh, upTo: convo.messages.count,
            consolidate: consolidate)
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
    /// Consolidation rewrites the full profile; incremental maintenance applies typed deltas.
    private func runMemoryMaintenance(
        conversationID: UUID, messages: [ChatMessage], upTo: Int, consolidate: Bool
    ) {
        guard let idx = conversationIndex(conversationID) else { return }
        let persona = personaStore.persona(for: conversations[idx])
        let personaScope = persona.memoryScope
        let globalScope = MemoryStore.globalScope
        let transcript =
            messages
            .filter { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty }
            .map { "\($0.role == .user ? "USER" : "ASSISTANT"): \($0.content)" }
            .joined(separator: "\n\n")
        guard !transcript.isEmpty else { return }

        let snapshot = MemoryProfile.snapshot(
            store: memoryStore, global: globalScope, persona: personaScope)
        let beforeMemory = Dictionary(
            uniqueKeysWithValues: MemoryProfile.contents(
                store: memoryStore, global: globalScope, persona: personaScope))
        let extra = settings.reflectionCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = personaStore.assistantName(for: persona)
        let now = DateContext.current()
        let instruction =
            consolidate
            ? MemoryProfile.consolidatePrompt(
                current: snapshot, transcript: transcript, extra: extra, assistantName: assistant,
                now: now)
            : MemoryProfile.maintainerPrompt(
                current: snapshot, transcript: transcript, extra: extra, assistantName: assistant,
                now: now)
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
            let result: String?
            do {
                result = try await ChatService.completeStreaming(
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
            guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                traceStore.trace(
                    conversationID: conversationID, kind: .error,
                    text: "memory update produced no output (model returned an empty reply)",
                    saveTraces: settings.saveTraces)
                return
            }
            var traceDetail: String?
            var operationSummary = ""
            if consolidate {
                let sections = MemoryProfile.parse(result)
                guard !sections.isEmpty else {
                    traceStore.trace(
                        conversationID: conversationID, kind: .error,
                        text:
                            "memory consolidation skipped: could not parse category sections from output",
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
                    delta, store: self.memoryStore, global: globalScope, persona: personaScope)
                for (cat, body) in application.changedBodies {
                    let target = cat.targetScope(global: globalScope, persona: personaScope)
                    if body.isEmpty {
                        self.memoryStore.delete(scope: target, name: cat.fileName)
                    } else {
                        self.memoryStore.write(scope: target, name: cat.fileName, content: body)
                    }
                }
                operationSummary =
                    "; \(application.appliedCount) applied, \(application.skippedCount) skipped"
                traceDetail = application.detail
            }
            if let i = self.ensureHydratedIndex(conversationID) {
                self.conversations[i].memorizedCount = min(
                    upTo, self.conversations[i].messages.count)
                self.touch(i)
            }
            if consolidate {
                self.lastConsolidatedBullets[personaScope] =
                    self.memoryStore.bulletCount(in: globalScope)
                    + self.memoryStore.bulletCount(in: personaScope)
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
