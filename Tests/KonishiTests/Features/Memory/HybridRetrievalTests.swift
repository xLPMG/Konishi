import Foundation
import Testing

@testable import Konishi

@Suite("Hybrid retrieval")
@MainActor
struct HybridRetrievalTests {
    @Test("semantic and lexical scores blend to rank exact matches higher")
    func ranksWithHybridScore() {
        let chunks: [(label: String, text: String)] = [
            ("semantic", "A conceptually relevant passage"),
            ("lexical", "A passage with exact query terms")
        ]
        let ranking = HybridRetrieval.score(
            chunks: chunks, rawLexical: [0, 9], semantic: [0.95, 0.70],
            hybridThreshold: 0, lexicalThreshold: 0.15, failure: nil)

        #expect(ranking.scored.map(\.chunk.label) == ["lexical", "semantic"])
        #expect(abs(ranking.scored[0].score - (0.7 * 0.70 + 0.3 * HybridRetrieval.boundedBM25(9))) < 0.0001)
        #expect(ranking.failure == nil)
    }

    @Test("documents and vaults use lexical fallback when embeddings are unavailable")
    func documentAndVaultFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hybrid-retrieval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = EmbeddingCache(url: root.appendingPathComponent("embeddings.bin"))
        let config = offlineConfig()
        let conversationID = UUID()

        let documents = DocumentStore(root: root.appendingPathComponent("documents"))
        documents.add(
            name: "quasar-report.md", text: "The quasar telescope captured unusual spectra.",
            conversationID: conversationID)
        documents.add(
            name: "lunar-report.md", text: "A lunar rover mapped the crater floor.",
            conversationID: conversationID)
        let documentResult = await documents.context(
            for: conversationID, query: "quasar telescope", cache: cache, topK: 3,
            requestConfig: config)

        #expect(documentResult.text.contains("quasar-report.md"))
        #expect(!documentResult.text.contains("lunar-report.md"))
        #expect(documentResult.failure != nil)

        let vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try "The quasar telescope captured unusual spectra.".write(
            to: vaultURL.appendingPathComponent("quasar-notes.md"),
            atomically: true, encoding: .utf8)
        try "A lunar rover mapped the crater floor.".write(
            to: vaultURL.appendingPathComponent("lunar-notes.md"),
            atomically: true, encoding: .utf8)
        let vaultResult = await VaultStore().context(
            vaultPath: vaultURL.path, query: "quasar telescope", cache: cache, topK: 3,
            requestConfig: config)

        #expect(vaultResult.text.contains("quasar-notes.md"))
        #expect(!vaultResult.text.contains("lunar-notes.md"))
        #expect(vaultResult.failure != nil)
    }

    private func offlineConfig() -> RequestConfig {
        RequestConfig(
            chatURL: nil, modelsURL: nil, apiModelsURL: nil, embeddingsURL: nil,
            transcriptionsURL: nil, speechURL: nil, audioModelsURL: nil, audioVoicesURL: nil,
            model: "test-model", temperature: 0.7, topP: nil, maxTokens: nil, stop: nil, seed: nil,
            presencePenalty: nil, frequencyPenalty: nil, token: "", embeddingModel: "test-embed",
            sttModel: "", ttsModel: "", ttsVoice: "")
    }
}