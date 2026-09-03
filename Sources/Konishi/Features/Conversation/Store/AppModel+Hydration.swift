import Foundation

extension AppModel {

    /// Load a conversation's messages into RAM if absent, and cap the working set.
    func ensureHydrated(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        if !hydratedIDs.contains(id) {
            if let body = Self.loadConversationBody(id) {
                conversations[idx].messages = body.messages
            }
            hydratedIDs.insert(id)
        }
        hydrationOrder.removeAll { $0 == id }
        hydrationOrder.append(id)
        evictHydrated()
    }

    /// Hydrate (if needed) then return the index — for use after an `await`, when the body may have
    /// been evicted while the task ran.
    @discardableResult
    func ensureHydratedIndex(_ id: UUID) -> Int? {
        ensureHydrated(id)
        return conversationIndex(id)
    }

    /// Drop message bodies of the least-recently-used conversations beyond the cap. Bodies are always
    /// on disk (save-through), so eviction is lossless. Selected / streaming / pending-approval chats
    /// are never evicted.
    func evictHydrated() {
        while hydrationOrder.count > Self.maxHydrated {
            guard
                let victim = hydrationOrder.first(where: {
                    $0 != selectedConversationID
                        && $0 != streamingConversationID
                        && $0 != pendingApproval?.conversationID
                })
            else { break }
            hydrationOrder.removeAll { $0 == victim }
            hydratedIDs.remove(victim)
            if let idx = conversations.firstIndex(where: { $0.id == victim }) {
                conversations[idx].messages = []
            }
        }
    }

    func conversationIndex(_ id: UUID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }

    func scheduleSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else {
            contentMatchIDs = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let ids = await Task.detached { Self.searchDisk(query: q) }.value
            guard !Task.isCancelled else { return }
            self?.contentMatchIDs = ids
        }
    }
}
