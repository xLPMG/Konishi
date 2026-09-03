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
        return await retrieveMemory(conversationID: conversationID, scopes: scopes, query: query)
    }

    private struct ScoredMemoryChunk {
        // label is the memory chunk's identifier (scope/file), text is the content of the chunk.
        let chunk: (label: String, text: String)
        let score: Double
        let semanticScore: Double?
        let lexicalScore: Double
        let rawLexicalScore: Double
    }

    /// Injects the user's identity (global profile) in full plus the top-K bullets most relevant
    /// to the current query, so memory can grow large without flooding the context.  When an
    /// embeddings endpoint is available, lexical BM25 and semantic similarity are combined;
    /// otherwise BM25 remains a useful fully-local fallback.
    private func retrieveMemory(conversationID: UUID, scopes: [String], query: String) async
        -> String
    {
        let profileName = MemoryCategory.profile.fileName
        let profileScope = MemoryStore.globalScope
        let profileURL = Paths.memoryScope(profileScope).appendingPathComponent(profileName)
        let profileBody = memoryStore.read(
            MemoryStore.File(scope: profileScope, name: profileName, url: profileURL)
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []
        if !profileBody.isEmpty {
            sections.append("## \(profileScope)/\(profileName)\n\(profileBody)")
        }

        // Every other bullet is a retrieval candidate.
        var chunks: [(label: String, text: String)] = []
        for scope in scopes {
            for file in memoryStore.files(in: scope) {
                if scope == profileScope, file.name == profileName { continue }
                for block in MemoryStore.blocks(memoryStore.read(file)) {
                    chunks.append((label: "\(scope)/\(file.name)", text: block))
                }
            }
        }
        guard !chunks.isEmpty, !query.isEmpty else { return sections.joined(separator: "\n\n") }
        let rawLexicalScores = MemoryRetrieval.bm25(query: query, documents: chunks.map(\.text))
        let lexicalScores = rawLexicalScores.map(MemoryRetrieval.boundedBM25)
        do {
            let (q, blockEmb) = try await embedWithCache(
                query: query, blocks: chunks.map(\.text), model: settings.embeddingModel)
            let semanticScores = blockEmb.map { (Self.cosine(q, $0) + 1.0) / 2.0 }  // map cosine to [0, 1] range for comparison with BM25
            let scored = chunks.indices
                .map { index in
                    ScoredMemoryChunk(
                        chunk: chunks[index],
                        score: 0.7 * semanticScores[index] + 0.3 * lexicalScores[index],
                        semanticScore: semanticScores[index],
                        lexicalScore: lexicalScores[index],
                        rawLexicalScore: rawLexicalScores[index]
                    )
                }
                .filter { $0.score >= settings.memoryThreshold }
                .sorted { $0.score > $1.score }
                .prefix(max(1, settings.memoryTopK))
            appendMemorySections(Array(scored), to: &sections)
            traceStore.trace(
                conversationID: conversationID, kind: .memory,
                text:
                    "memory retrieval: \(scored.count)/\(chunks.count) bullets ≥ \(String(format: "%.2f", settings.memoryThreshold)) injected",
                saveTraces: settings.saveTraces,
                detail: memoryRetrievalTraceDetail(Array(scored))
            )
        } catch {
            // An embeddings server is optional: retain targeted lexical retrieval when it is down.
            let scored = chunks.indices
                .map { index in
                    ScoredMemoryChunk(
                        chunk: chunks[index],
                        score: lexicalScores[index],
                        semanticScore: nil,
                        lexicalScore: lexicalScores[index],
                        rawLexicalScore: rawLexicalScores[index]
                    )
                }
                .filter { $0.score >= 0.2 }  // magic number :)
                .sorted { $0.score > $1.score }
                .prefix(max(1, settings.memoryTopK))
            appendMemorySections(Array(scored), to: &sections)
            traceStore.trace(
                conversationID: conversationID, kind: .error,
                text:
                    "memory embedding retrieval failed; BM25 fallback injected \(scored.count)/\(chunks.count) bullets: \(Self.embedErrorHint(error))",
                saveTraces: settings.saveTraces,
                detail: memoryRetrievalTraceDetail(Array(scored))
            )
        }
        return sections.joined(separator: "\n\n")
    }

    /// Group selected bullets by source file, preserving score order between files.
    private func appendMemorySections(_ scored: [ScoredMemoryChunk], to sections: inout [String]) {
        var order: [String] = []
        var byLabel: [String: [String]] = [:]
        for item in scored {
            if byLabel[item.chunk.label] == nil { order.append(item.chunk.label) }
            byLabel[item.chunk.label, default: []].append(item.chunk.text)
        }
        sections.append(
            contentsOf: order.map { "## \($0)\n\((byLabel[$0] ?? []).joined(separator: "\n"))" })
    }

    /// Trace details for the exact bullets injected this turn, in retrieval order.
    private func memoryRetrievalTraceDetail(_ scored: [ScoredMemoryChunk]) -> String {
        guard !scored.isEmpty else { return "No memory bullets met the retrieval criteria." }
        return scored.enumerated().map { rank, item in
            let scores: String
            if let semantic = item.semanticScore {
                scores =
                    "hybrid \(String(format: "%.3f", item.score))  semantic \(String(format: "%.3f", semantic))  BM25 \(String(format: "%.3f", item.lexicalScore)) (raw \(String(format: "%.3f", item.rawLexicalScore)))"
            } else {
                scores =
                    "BM25 \(String(format: "%.3f", item.score)) (raw \(String(format: "%.3f", item.rawLexicalScore)))"
            }
            return "\(rank + 1). \(scores)\n   \(item.chunk.label)\n   \(item.chunk.text)"
        }.joined(separator: "\n\n")
    }
}
