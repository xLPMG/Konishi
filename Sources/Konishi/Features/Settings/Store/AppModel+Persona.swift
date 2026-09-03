import Foundation

extension AppModel {
    func deletePersona(_ id: UUID) {
        guard let fallback = personaStore.deletePersona(id) else { return }
        let affectedConversationIDs = conversations.compactMap { conversation in
            conversation.personaID == id ? conversation.id : nil
        }
        for conversationID in affectedConversationIDs {
            ensureHydrated(conversationID)
            guard let index = conversationIndex(conversationID) else { continue }
            conversations[index].personaID = fallback
            save(conversations[index])
        }
    }
}
