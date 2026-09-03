import Foundation
import Testing

@testable import Konishi

@Suite("MemoryStore")
struct MemoryStoreTests {

    /// Fresh temp root per test so tests never touch real memory files or race each other.
    private func withStore(_ body: @Sendable (MemoryStore, URL) async throws -> Void) async rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(MemoryStore(root: root), root)
    }

    /// A config whose embeddingsURL is nil, so ChatService.embed throws before any network call.
    private func offlineConfig() -> RequestConfig {
        RequestConfig(
            chatURL: nil, modelsURL: nil, apiModelsURL: nil, embeddingsURL: nil,
            transcriptionsURL: nil, speechURL: nil, audioModelsURL: nil, audioVoicesURL: nil,
            model: "test-model", temperature: 0.7, topP: nil, maxTokens: nil, stop: nil, seed: nil,
            presencePenalty: nil, frequencyPenalty: nil, token: "", embeddingModel: "test-embed",
            sttModel: "", ttsModel: "", ttsVoice: "")
    }

    @Test("write then read round-trips content")
    func writeReadRoundTrips() async throws {
        try await withStore { store, _ in
            store.write(scope: "global", name: "notes", content: "- likes tea")
            let file = MemoryStore.File(
                scope: "global", name: "notes.md",
                url: store.files(in: "global")[0].url)
            #expect(store.read(file) == "- likes tea")
        }
    }

    @Test("files(in:) only lists markdown files, sorted by name")
    func filesListsAndSortsMarkdown() async throws {
        try await withStore { store, root in
            store.write(scope: "global", name: "b", content: "- b")
            store.write(scope: "global", name: "a", content: "- a")
            try "not markdown".write(
                to: root.appendingPathComponent("global").appendingPathComponent("ignored.txt"),
                atomically: true, encoding: .utf8)

            let names = store.files(in: "global").map(\.name)
            #expect(names == ["a.md", "b.md"])
        }
    }

    @Test("append adds to existing content with a blank-line separator")
    func appendAddsSeparator() async throws {
        try await withStore { store, _ in
            store.write(scope: "global", name: "notes.md", content: "- first")
            store.append(scope: "global", name: "notes.md", content: "- second")

            let file = store.files(in: "global")[0]
            #expect(store.read(file) == "- first\n\n- second")
        }
    }

    @Test("delete(scope:name:) removes the file")
    func deleteByScopeAndNameRemoves() async throws {
        try await withStore { store, _ in
            store.write(scope: "global", name: "notes.md", content: "- gone soon")
            #expect(store.files(in: "global").count == 1)

            store.delete(scope: "global", name: "notes.md")

            #expect(store.files(in: "global").isEmpty)
        }
    }

    @Test("combined(scopes:) concatenates non-empty files across scopes as headed markdown")
    func combinedConcatenatesNonEmptyFiles() async throws {
        try await withStore { store, _ in
            store.write(scope: "global", name: "profile", content: "- name: Luca")
            store.write(scope: "persona-a", name: "notes", content: "- likes Swift")
            store.write(scope: "persona-a", name: "empty", content: "")

            let combined = store.combined(scopes: ["global", "persona-a"])

            #expect(combined.contains("## global/profile.md\n- name: Luca"))
            #expect(combined.contains("## persona-a/notes.md\n- likes Swift"))
            #expect(!combined.contains("empty.md"))
        }
    }

    @Test("signature(scopes:) changes when a file is added")
    func signatureChangesOnAdd() async throws {
        try await withStore { store, _ in
            let before = store.signature(scopes: ["global"])
            store.write(scope: "global", name: "notes", content: "- something")
            let after = store.signature(scopes: ["global"])

            #expect(before != after)
        }
    }

    @Test("blocks(_:) trims lines and drops ones shorter than 3 characters")
    func blocksFiltersShortLines() {
        let blocks = MemoryStore.blocks("- likes tea  \n\nno\n- enjoys Swift\n \n- ok")
        #expect(blocks == ["- likes tea", "- enjoys Swift", "- ok"])
    }

    @Test("bulletCount(in:) sums blocks across every file in a scope")
    func bulletCountSumsAcrossFiles() async throws {
        try await withStore { store, _ in
            store.write(scope: "global", name: "a", content: "- one\n- two")
            store.write(scope: "global", name: "b", content: "- three")

            #expect(store.bulletCount(in: "global") == 3)
        }
    }

    @Test("retrieve returns no context and no trace when there are no candidate bullets")
    @MainActor
    func retrieveWithNoBulletsReturnsEmpty() async throws {
        try await withStore { store, _ in
            let result = await store.retrieve(
                scopes: ["global"], query: "anything", cache: EmbeddingCache(url: tempCacheURL()),
                requestConfig: offlineConfig(), threshold: 0.5, topK: 3)

            #expect(result.text.isEmpty)
            #expect(result.trace == nil)
        }
    }

    @Test("retrieve always injects the full global profile")
    @MainActor
    func retrieveInjectsProfileInFull() async throws {
        try await withStore { store, _ in
            store.write(
                scope: "global", name: MemoryCategory.profile.fileName,
                content: "- name: Luca\n- likes Swift")

            let result = await store.retrieve(
                scopes: ["global"], query: "", cache: EmbeddingCache(url: tempCacheURL()),
                requestConfig: offlineConfig(), threshold: 0.5, topK: 3)

            #expect(result.text.contains("- name: Luca"))
            #expect(result.text.contains("- likes Swift"))
        }
    }

    @Test("retrieve falls back to lexical scoring and reports an .error trace when embeddings are unavailable")
    @MainActor
    func retrieveFallsBackToLexicalScoring() async throws {
        try await withStore { store, _ in
            store.write(
                scope: "global", name: "notes",
                content: "- loves hiking in the mountains\n- prefers tea over coffee")

            let result = await store.retrieve(
                scopes: ["global"], query: "hiking mountains", cache: EmbeddingCache(url: tempCacheURL()),
                requestConfig: offlineConfig(), threshold: 0.5, topK: 3)

            #expect(result.text.contains("loves hiking in the mountains"))
            #expect(result.trace?.kind == .error)
        }
    }

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("embeddings-\(UUID().uuidString).bin")
    }
}
