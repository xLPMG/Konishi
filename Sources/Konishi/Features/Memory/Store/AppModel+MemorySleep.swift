import Foundation

/// The background "sleep" pass: promotes or drops short-term facts, refreshes stale conversation
/// digests, and tidies long-term memory once it has grown. Runs when the app is idle, after a
/// conversation switch, and shortly after launch. Everything it needs is persisted, so a pass
/// interrupted by quitting is simply caught up on the next launch.
extension AppModel {
    static let sleepIdleDelay: Duration = .seconds(300)
    private static let digestsPerPass = 3
    /// Legacy chats without a digest are only back-filled within this many of the newest.
    private static let digestBackfillWindow = 50

    /// (Re)start the countdown to the next pass; a later call replaces an earlier one.
    func scheduleSleepPass(after delay: Duration) {
        guard !isSleeping else { return }
        sleepTask?.cancel()
        sleepFireDate = Date.now.addingTimeInterval(Double(delay.components.seconds))
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.sleepFireDate = nil
            await self.runSleepPass()
        }
    }

    /// One-line status of the background pass, for the Memory menu.
    var sleepStatusText: String {
        if !settings.autoMemory { return "Background memory pass: off" }
        if settings.pauseMemoryWrites { return "Background memory pass: paused" }
        if isSleeping { return "Background memory pass: running…" }
        guard let date = sleepFireDate else { return "Background memory pass: nothing scheduled" }
        return "Next memory pass at \(date.formatted(date: .omitted, time: .shortened))"
    }

    private var sleepShouldYield: Bool {
        isStreaming || isMemorizing || isReflecting || isCompressing || conversationActive
            || pendingApproval != nil
    }

    private func runSleepPass() async {
        guard settings.autoMemory, !settings.pauseMemoryWrites, !isSleeping else { return }
        if sleepShouldYield {
            scheduleSleepPass(after: .seconds(60))
            return
        }
        isSleeping = true
        let retry = await performSleepPass()
        isSleeping = false
        if let retry { scheduleSleepPass(after: retry) }
    }

    /// Returns how long to wait before another pass, or nil when nothing is left to do.
    private func performSleepPass() async -> Duration? {
        let target = selectedConversationID ?? conversations.first?.id
        func note(_ text: String, kind: TraceEntry.Kind = .memory, detail: String? = nil) {
            guard let target else { return }
            traceStore.trace(
                conversationID: target, kind: kind, text: text,
                saveTraces: settings.saveTraces, detail: detail)
        }

        stm.tick()
        let outcome = stm.applyPromotion(to: memoryStore)
        if !outcome.promoted.isEmpty || !outcome.dropped.isEmpty || !outcome.covered.isEmpty {
            let lines =
                outcome.promoted.map { "PROMOTE [\($0.category.header)] \($0.text)" }
                + outcome.covered.map {
                    "SKIP [\($0.fact.category.header)] \($0.fact.text) — already covered by \"\($0.by)\""
                }
                + outcome.dropped.map { "DROP [\($0.category.header)] \($0.text)" }
            note(
                "sleep: promoted \(outcome.promoted.count) short-term facts to long-term memory, dropped \(outcome.dropped.count), skipped \(outcome.covered.count) already covered",
                detail: lines.joined(separator: "\n"))
        }

        var retry: Duration?
        let stale = staleDigestCandidates()
        if !stale.isEmpty {
            if connectionOK == false {
                retry = .seconds(900)
            } else {
                if sleepShouldYield { return .seconds(60) }
                let result = await refreshDigests(stale)
                if result.refreshed > 0 {
                    note("sleep: refreshed \(result.refreshed) conversation summar\(result.refreshed == 1 ? "y" : "ies")")
                }
                if result.failed {
                    note(
                        "sleep: could not refresh conversation summaries: \(result.error ?? "unknown error")",
                        kind: .error)
                    retry = .seconds(900)
                } else if result.remaining > 0 {
                    retry = .seconds(45)
                }
            }
        }

        // Old digests: fold lasting highlights into History (the digests themselves are kept).
        if connectionOK != false, !sleepShouldYield {
            let candidates = ConversationRecall.rollupCandidates(from: conversations)
            if !candidates.isEmpty {
                if let added = await rollUpOldDigests(candidates) {
                    note(
                        "sleep: rolled \(candidates.count) old conversation summar\(candidates.count == 1 ? "y" : "ies") into History (\(added) highlight\(added == 1 ? "" : "s"))")
                    if ConversationRecall.rollupCandidates(from: conversations, limit: 1).count > 0 {
                        retry = min(retry ?? .seconds(45), .seconds(45))
                    }
                } else {
                    retry = retry ?? .seconds(900)
                }
            }
        }

        let entries = ConversationRecall.entries(from: conversations, excluding: nil)
        if !entries.isEmpty {
            try? await embeddingCache.warm(
                texts: entries.map(ConversationRecall.chunkText),
                requestConfig: settings.requestConfig(modelOverride: nil))
        }

        guard !sleepShouldYield else { return retry ?? .seconds(60) }
        if settings.autoConsolidate, connectionOK != false,
            let convo = conversations.filter({ $0.isLanguage != true })
                .max(by: { $0.updatedAt < $1.updatedAt })
        {
            let scope = personaStore.persona(for: convo).memoryScope
            let bullets =
                memoryStore.bulletCount(in: MemoryStore.globalScope) + memoryStore.bulletCount(in: scope)
            let last = stm.lastConsolidated(scope)
            // Wait for real growth so each cleanup (a full model rewrite) is worth its cost.
            let due =
                bullets >= max(10, settings.autoConsolidateThreshold)
                && (last.map { bullets >= $0 + max(8, $0 / 4) } ?? true)
            if due {
                runMemoryMaintenance(
                    conversationID: convo.id, messages: [], upTo: nil, consolidate: true)
            }
        }
        return retry
    }

    // MARK: Digests

    private func staleDigestCandidates() -> [UUID] {
        conversations
            .filter { $0.isLanguage != true }
            .sorted { $0.updatedAt > $1.updatedAt }
            .enumerated()
            .filter { offset, c in
                let stale = c.digestUpdatedAt.map { c.updatedAt > $0 } ?? true
                return stale && (c.digestUpdatedAt != nil || offset < Self.digestBackfillWindow)
            }
            .map(\.element.id)
    }

    private struct DigestRefresh {
        var refreshed = 0
        var remaining = 0
        var failed = false
        var error: String?
    }

    private func refreshDigests(_ ids: [UUID]) async -> DigestRefresh {
        var result = DigestRefresh()
        var modelCalls = 0
        for (n, id) in ids.enumerated() {
            if sleepShouldYield {
                result.remaining += ids.count - n
                break
            }
            guard let i = conversationIndex(id) else { continue }
            let convo = conversations[i]
            let messages =
                hydratedIDs.contains(id)
                ? convo.messages : (Self.loadConversationBody(id)?.messages ?? [])
            let covered = convo.digest == nil ? 0 : min(convo.digestCount ?? 0, messages.count)
            let isText: (ChatMessage) -> Bool = {
                ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty
            }
            let fresh = messages[covered...].filter(isText)
            // Nothing new to summarize, or too little to be worth a digest yet.
            if fresh.isEmpty || (convo.digest == nil && messages.filter(isText).count < 2) {
                stampDigest(id, digest: nil, count: messages.count, expecting: convo.updatedAt)
                continue
            }
            if modelCalls >= Self.digestsPerPass {
                result.remaining += 1
                continue
            }
            modelCalls += 1

            let persona = personaStore.persona(for: convo)
            var config = settings.requestConfig(modelOverride: persona.model)
            if settings.disableThinkingForTasks { config.enableThinking = false }
            config.maxTokens = min(config.maxTokens ?? 800, 800)
            let prompt = MemoryProfile.digestPrompt(
                title: convo.title, currentDigest: convo.digest,
                transcript: Self.clipTranscript(
                    fresh.map { "\($0.role == .user ? "USER" : "ASSISTANT"): \($0.content)" }
                        .joined(separator: "\n\n")))
            var digest = ""
            do {
                digest = try await ChatService.completeStreaming(
                    config: config, messages: [WireMessage(role: Role.user.rawValue, text: prompt)]
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                result.error = error.localizedDescription
            }
            guard !digest.isEmpty else {
                result.error = result.error ?? "the model returned no text (it may have spent the token limit on reasoning)"
                result.failed = true
                break
            }
            guard let completed = AuxiliaryPromptGuidance.content(from: digest),
                !AuxiliaryPromptGuidance.looksLikeRefusal(completed),
                completed.split(whereSeparator: \.isWhitespace).count <= 80
            else {
                result.error = AuxiliaryPromptGuidance.blockedReason(from: digest)
                    ?? "digest output was not a usable summary"
                result.failed = true
                break
            }
            digest = completed
            stampDigest(id, digest: digest, count: messages.count, expecting: convo.updatedAt)
            result.refreshed += 1
        }
        return result
    }

    /// Asks the model for lasting highlights in old digests and appends them to global History.
    /// Returns the number of new highlights written, or nil if the model reply was unusable.
    private func rollUpOldDigests(_ candidates: [Conversation]) async -> Int? {
        let summaries = candidates.map {
            "[\(ConversationRecall.dateString($0.updatedAt)) · \($0.title)] \($0.digest ?? "")"
        }
        let historyFile = memoryStore.file(
            scope: MemoryStore.globalScope, name: MemoryCategory.history.fileName)
        let existing = memoryStore.read(historyFile).trimmingCharacters(in: .whitespacesAndNewlines)
        var config = settings.requestConfig(modelOverride: nil)
        if settings.disableThinkingForTasks { config.enableThinking = false }
        config.maxTokens = min(config.maxTokens ?? 800, 800)
        let prompt = MemoryProfile.rollupPrompt(
            summaries: summaries, existingHistory: existing, now: DateContext.current())
        let raw = try? await ChatService.completeStreaming(
            config: config, messages: [WireMessage(role: Role.user.rawValue, text: prompt)])
        guard let raw,
            let completed = AuxiliaryPromptGuidance.content(from: raw),
            !AuxiliaryPromptGuidance.looksLikeRefusal(completed),
            let highlights = MemoryProfile.parseHighlights(completed)
        else { return nil }

        let merged = MemoryProfile.canonical(
            ([existing] + highlights.map { "- \($0)" }).joined(separator: "\n"))
        let added = MemoryStore.blocks(merged).count - MemoryStore.blocks(existing).count
        if added > 0 {
            memoryStore.write(
                scope: MemoryStore.globalScope, name: MemoryCategory.history.fileName, content: merged)
        }
        let stamp = Date.now
        for id in candidates.map(\.id) {
            guard let i = ensureHydratedIndex(id) else { continue }
            conversations[i].digestRolledUpAt = stamp
            save(conversations[i])
        }
        return max(0, added)
    }

    /// Records a digest as current, unless the conversation changed while the model was working.
    private func stampDigest(_ id: UUID, digest: String?, count: Int, expecting updatedAt: Date) {
        guard let i = ensureHydratedIndex(id), conversations[i].updatedAt == updatedAt else { return }
        if let digest {
            conversations[i].digest = String(digest.prefix(1200))
            conversations[i].digestRolledUpAt = nil
        }
        conversations[i].digestCount = count
        conversations[i].digestUpdatedAt = updatedAt
        save(conversations[i])
    }

    /// Keeps a long transcript within a prompt-sized budget, preserving its start and end.
    private static func clipTranscript(_ text: String, limit: Int = 12_000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit / 3)) + "\n[…]\n" + String(text.suffix(limit * 2 / 3))
    }
}
