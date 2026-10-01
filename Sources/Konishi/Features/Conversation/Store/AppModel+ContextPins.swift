import Foundation

extension AppModel {
    var selectedContextPins: [ContextPin] {
        selectedConversation?.contextPins ?? []
    }

    func isContextPinned(_ messageID: UUID) -> Bool {
        selectedContextPins.contains { $0.messageID == messageID }
    }

    func toggleContextPin(_ messageID: UUID) {
        guard let conversationID = selectedConversationID,
            let index = ensureHydratedIndex(conversationID)
        else { return }

        var pins = conversations[index].contextPins ?? []
        if let pinIndex = pins.firstIndex(where: { $0.messageID == messageID }) {
            pins.remove(at: pinIndex)
        } else {
            guard pins.count < ContextPin.maximumCount,
                let message = conversations[index].messages.first(where: { $0.id == messageID }),
                message.role == .user || message.role == .assistant
            else { return }
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let excerpt = String(text.prefix(ContextPin.maximumPinCharacters))
            let storedText = excerpt.count < text.count ? excerpt + "…" : excerpt
            pins.append(ContextPin(messageID: message.id, role: message.role, text: storedText))
        }

        conversations[index].contextPins = pins.isEmpty ? nil : pins
        touch(index)
    }

    func removeContextPin(_ messageID: UUID) {
        guard let conversationID = selectedConversationID,
            let index = ensureHydratedIndex(conversationID)
        else { return }
        let oldCount = conversations[index].contextPins?.count ?? 0
        conversations[index].contextPins?.removeAll { $0.messageID == messageID }
        guard (conversations[index].contextPins?.count ?? 0) != oldCount else { return }
        if conversations[index].contextPins?.isEmpty == true {
            conversations[index].contextPins = nil
        }
        touch(index)
    }
}