import Foundation

extension AppModel {
    /// Indexed documents for the current conversation.
    var indexedDocuments: [StoredDocument] {
        selectedConversationID.map { documentStore.documents(for: $0) } ?? []
    }

    /// Inline small attachments; index large ones for retrieval. Returns true when indexed as RAG.
    @discardableResult
    func addDocument(name: String, text: String) -> Bool {
        if settings.ragThresholdChars > 0, text.count > settings.ragThresholdChars,
            let convoID = selectedConversationID
        {
            documentStore.add(name: name, text: text, conversationID: convoID)
            return true
        }
        draftAttachments.append(Attachment(name: name, text: text))
        return false
    }

    func removeIndexedDocument(_ id: UUID) {
        guard let convoID = selectedConversationID else { return }
        documentStore.delete(id: id, conversationID: convoID)
    }

    /// Retrieve the most relevant passages from this conversation's indexed documentStore.
    func documentContext(conversationID: UUID, history: [ChatMessage]) async -> String {
        let docs = documentStore.documents(for: conversationID)
        guard !docs.isEmpty, let query = history.last(where: { $0.role == .user })?.content else {
            return ""
        }
        var chunks: [(label: String, text: String)] = []
        for doc in docs {
            for chunk in doc.chunks {
                let t = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 3 { chunks.append((label: doc.name, text: t)) }
            }
        }
        guard !chunks.isEmpty else { return "" }
        do {
            let (q, blockEmb) = try await embedWithCache(
                query: query, blocks: chunks.map(\.text), model: settings.embeddingModel)
            let scored = zip(chunks, blockEmb)
                .map { (chunk: $0.0, score: Self.cosine(q, $0.1)) }
                .sorted { $0.score > $1.score }
            return scored.prefix(max(1, settings.ragTopK))
                .map { "## \($0.chunk.label)\n\($0.chunk.text)" }
                .joined(separator: "\n\n")
        } catch {
            traceStore.trace(
                conversationID: conversationID, kind: .error,
                text: "document retrieval failed: \(Self.embedErrorHint(error))",
                saveTraces: settings.saveTraces)
            return ""
        }
    }
}
