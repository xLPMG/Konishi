import Foundation

extension AppModel {
    /// Summaries of past conversations relevant to this turn, as a prompt section (or empty).
    /// Held to a higher bar than memory bullets unless the user explicitly refers back ("last time…").
    func recallPastConversations(conversationID: UUID, query: String, config: RequestConfig) async
        -> String
    {
        guard !query.isEmpty else { return "" }
        let entries = ConversationRecall.entries(from: conversations, excluding: conversationID)
        guard !entries.isEmpty else { return "" }
        let refersToPast = ConversationRecall.mentionsPast(query)
        guard refersToPast || ConversationRecall.hasSpecificTopic(query) else { return "" }
        let ranking = await HybridRetrieval.rank(
            chunks: entries.map { (ConversationRecall.shortID($0.id), ConversationRecall.chunkText($0)) },
            query: query, cache: embeddingCache, requestConfig: config,
            hybridThreshold: min(
                1, settings.memoryThreshold + (refersToPast ? 0 : ConversationRecall.normalMargin)),
            lexicalThreshold: refersToPast ? 0.25 : 0.60)
        guard !Task.isCancelled else { return "" }
        let eligible = ranking.scored.filter { item in
            ranking.failure == nil || refersToPast
                || ConversationRecall.hasStrongFallbackMatch(query: query, digest: item.chunk.text)
        }
        if let failure = ranking.failure {
            traceStore.trace(
                conversationID: conversationID, kind: .error,
                text: "past conversation embedding retrieval failed; BM25 fallback retained \(eligible.count)/\(entries.count) summaries: \(failure)",
                saveTraces: settings.saveTraces,
                detail: HybridRetrieval.traceDetail(eligible))
        }
        let byID = Dictionary(
            entries.map { (ConversationRecall.shortID($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let picked = eligible.prefix(refersToPast ? 3 : 2).compactMap { byID[$0.chunk.label] }
        guard !picked.isEmpty else { return "" }
        traceStore.trace(
            conversationID: conversationID, kind: .memory,
            text: "recalled \(picked.count) past conversation summar\(picked.count == 1 ? "y" : "ies")",
            saveTraces: settings.saveTraces,
            detail: picked.map { "\(ConversationRecall.dateString($0.date)) · \($0.title)\n\($0.digest)" }
                .joined(separator: "\n\n"))
        return ConversationRecall.section(Array(picked))
    }

    // MARK: Tools

    func conversationSearchResult(query: String, limit: Int?, current: UUID) async -> String {
        let entries = ConversationRecall.entries(from: conversations, excluding: current)
        guard !entries.isEmpty else { return "(no conversation summaries yet)" }
        let ranking = await HybridRetrieval.rank(
            chunks: entries.map { (ConversationRecall.shortID($0.id), ConversationRecall.chunkText($0)) },
            query: query, cache: embeddingCache,
            requestConfig: settings.requestConfig(modelOverride: nil),
            hybridThreshold: settings.memoryThreshold, lexicalThreshold: 0.15)
        let byID = Dictionary(
            entries.map { (ConversationRecall.shortID($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let hits = ranking.scored.prefix(min(max(limit ?? 5, 1), 15)).compactMap { byID[$0.chunk.label] }
        guard !hits.isEmpty else { return "(no matching conversations)" }
        return hits.map(Self.conversationLine).joined(separator: "\n")
    }

    func conversationListResult(days: Int?, limit: Int?, current: UUID) -> String {
        let cutoff = days.map { Date.now.addingTimeInterval(-Double(max($0, 1)) * 86_400) }
        let matches =
            conversations
            .filter { c in
                c.id != current && (cutoff.map { c.updatedAt >= $0 } ?? true)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(min(max(limit ?? 10, 1), 30))
        guard !matches.isEmpty else { return "(no conversations)" }
        return matches.map { c in
            Self.conversationLine(
                ConversationRecall.Entry(
                    id: c.id, title: c.title, date: c.updatedAt,
                    digest: c.digest ?? "(no summary yet)"))
        }.joined(separator: "\n")
    }

    func conversationReadResult(id: String) -> String {
        let key = id.trimmingCharacters(in: .whitespaces).lowercased()
        guard key.count >= 4 else { return "Error: id too short" }
        let matches = conversations.filter { $0.id.uuidString.lowercased().hasPrefix(key) }
        guard let c = matches.first else { return "Error: no conversation with id \(id)" }
        guard matches.count == 1 else { return "Error: id \(id) is ambiguous; use more characters" }
        let digest = c.digest?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return
            "\(c.title) (\(ConversationRecall.dateString(c.updatedAt)))\n"
            + (digest.isEmpty ? "(no summary yet)" : digest)
    }

    private static func conversationLine(_ entry: ConversationRecall.Entry) -> String {
        let snippet = entry.digest.count > 240 ? String(entry.digest.prefix(240)) + "…" : entry.digest
        return "\(ConversationRecall.shortID(entry.id)) | \(ConversationRecall.dateString(entry.date)) | \(entry.title)\n  \(snippet)"
    }
}
