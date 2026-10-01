import Foundation

extension AppModel {
    /// Block until all queued writes have flushed (called on app termination).
    nonisolated static func flushPendingWrites() {
        Persistence.ioQueue.sync {}
    }

    func save(_ conversation: Conversation) {
        // Only hydrated conversations hold a real body; skip so we never clobber a file with empties.
        guard hydratedIDs.contains(conversation.id) else { return }
        Self.saveConversation(conversation)
    }

    /// Load only metadata for every conversation at launch; bodies are paged in on demand.
    static func loadConversations() -> [Conversation] {
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: Paths.conversations,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "json" }
        guard !urls.isEmpty else { return [] }
        // Decode files in parallel (per-thread decoder; JSONDecoder isn't safe to share across threads).
        var slots = [Conversation?](repeating: nil, count: urls.count)
        slots.withUnsafeMutableBufferPointer { buffer in
            // Each iteration writes a distinct index, so the distinct-offset writes don't race.
            nonisolated(unsafe) let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                guard let data = try? Data(contentsOf: urls[i]),
                      let meta = try? JSONDecoder().decode(ConversationMeta.self, from: data)
                else { return }
                (base + i).pointee = meta.asConversation()
            }
        }
        return slots.compactMap { $0 }
    }

    /// Read one conversation's full body (messages) from disk.
    static func loadConversationBody(_ id: UUID) -> Conversation? {
        let url = Paths.conversations.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Persistence.decoder.decode(Conversation.self, from: data)
    }

    /// Fallback content search used only if the SQLite full-text index is unavailable.
    nonisolated static func searchDisk(query q: String) -> Set<UUID> {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Paths.conversations, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        var ids: Set<UUID> = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let convo = try? decoder.decode(Conversation.self, from: data) else { continue }
            if convo.messages.contains(where: { $0.content.lowercased().contains(q) }) {
                ids.insert(convo.id)
            }
        }
        return ids
    }

    static func saveConversation(_ conversation: Conversation) {
        let url = Paths.conversations.appendingPathComponent("\(conversation.id.uuidString).json")
        guard let data = try? Persistence.encoder.encode(conversation) else { return }
        let searchRecord = ConversationSearchIndex.Record(conversation)
        Persistence.ioQueue.async {
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            try? ConversationSearchIndex().upsert(searchRecord)
        }
    }

    static func deleteConversationFile(_ id: UUID) {
        let url = Paths.conversations.appendingPathComponent("\(id.uuidString).json")
        // Same serial queue as saves so a delete never races ahead of a queued write for this id.
        Persistence.ioQueue.async {
            try? FileManager.default.removeItem(at: url)
            try? ConversationSearchIndex().delete(id)
        }
    }
}
