import Foundation

extension AppModel {
    func newConversation(personaID: UUID? = nil) {
        guard canCreateConversation else { return }
        let pid = personaID ?? currentPersonaIDForNewChat()
        let convo = Conversation(personaID: pid, isLanguage: mode == .language ? true : nil)
        searchText = ""
        conversations.insert(convo, at: 0)
        hydratedIDs.insert(convo.id)
        hydrationOrder.append(convo.id)
        selectedConversationID = convo.id
        draft = ""
        errorMessage = nil
        save(convo)
    }

    private func currentPersonaIDForNewChat() -> UUID? {
        selectedConversation?.personaID ?? personaStore.personas.first?.id
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        hydratedIDs.remove(id)
        hydrationOrder.removeAll { $0 == id }
        if streamingConversationID == id { streamingConversationID = nil }
        traceStore.traces[id] = nil
        traceStore.cancelTraceSave(conversationID: id)
        traceStore.deleteTraceFile(conversationID: id)
        documentStore.deleteAll(conversationID: id)
        Self.deleteConversationFile(id)
        try? FileManager.default.removeItem(at: Paths.conversationFiles(id))
        if selectedConversationID == id {
            selectedConversationID =
                conversations.first(where: { ($0.isLanguage == true) == (mode == .language) })?.id
        }
        if conversations.isEmpty { newConversation() }
    }

    func renameConversation(_ id: UUID, to title: String) {
        guard let idx = conversationIndex(id) else { return }
        conversations[idx].title = title.isEmpty ? "Untitled" : title
        autoTitledIDs.remove(id)  // user set it explicitly; never auto-refine over it
        touch(idx)
    }

    func setPersona(_ personaID: UUID, for conversationID: UUID) {
        guard let idx = conversationIndex(conversationID) else { return }
        conversations[idx].personaID = personaID
        touch(idx)
    }

    /// Keep the compression/memory counters consistent after messages are removed. If the rolling
    /// summary now covers messages that no longer exist, drop it — otherwise `runStream` would fold
    /// away (and skip) the live messages while re-injecting a stale summary.
    func reconcileFoldCounters(_ idx: Int) {
        let count = conversations[idx].messages.count
        if let s = conversations[idx].summarizedCount, s > count {
            conversations[idx].summary = nil
            conversations[idx].summarizedCount = nil
        }
        if let m = conversations[idx].memorizedCount, m > count {
            conversations[idx].memorizedCount = count
        }
        if let d = conversations[idx].digestCount, d > count {
            conversations[idx].digest = nil
            conversations[idx].digestCount = nil
            conversations[idx].digestUpdatedAt = nil
        }
    }

    func branch(fromMessage id: UUID) {
        guard let convo = selectedConversation,
            let mIdx = convo.messages.firstIndex(where: { $0.id == id })
        else { return }
        let branchedMessages = Array(convo.messages.prefix(mIdx + 1))
        let messageIDs = Set(branchedMessages.map(\.id))
        let copy = Conversation(
            title: convo.title + " (branch)",
            personaID: convo.personaID,
            messages: branchedMessages,
            contextPins: convo.contextPins?.filter { messageIDs.contains($0.messageID) }
        )
        conversations.insert(copy, at: 0)
        hydratedIDs.insert(copy.id)
        hydrationOrder.append(copy.id)
        selectedConversationID = copy.id
        save(copy)
    }

    func exportMarkdown(_ conversation: Conversation) -> String {
        // Sidebar may export a non-selected chat whose body isn't resident; read it from disk.
        let convo =
            hydratedIDs.contains(conversation.id)
            ? conversation
            : (Self.loadConversationBody(conversation.id) ?? conversation)
        let persona = personaStore.persona(for: convo)
        var out = "# \(convo.title)\n\n"
        for m in convo.messages {
            switch m.role {
            case .user: out += "**You:** \(m.content)\n\n"
            case .assistant where !m.content.isEmpty: out += "**\(persona.name):** \(m.content)\n\n"
            case .assistant: break
            case .tool: out += "> _tool `\(m.toolName ?? "")`_: \(m.content)\n\n"
            case .system: break
            }
        }
        return out
    }
}
