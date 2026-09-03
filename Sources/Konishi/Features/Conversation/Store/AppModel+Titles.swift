import Foundation

extension AppModel {

    func maybeAutoTitle(conversationID: UUID) {
        guard settings.autoTitle, let idx = conversationIndex(conversationID) else { return }
        let convo = conversations[idx]
        guard convo.messages.filter({ $0.role == .user }).count == 1,
            let firstUser = convo.messages.first(where: { $0.role == .user })?.content,
            !firstUser.isEmpty
        else { return }
        // Instant heuristic title (first line) so the sidebar isn't blank…
        let firstLine =
            firstUser
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? firstUser
        let clean = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        conversations[idx].title =
            clean.count > 48
            ? String(clean.prefix(48)).trimmingCharacters(in: .whitespaces) + "…"
            : clean
        autoTitledIDs.insert(conversationID)
        touch(idx)

        // refine it with the on-device model (ANE), if available.
        guard settings.useOnDeviceModel, OnDeviceLLM.isAvailable else { return }
        let placeholder = conversations[idx].title
        let source = String(firstUser.prefix(1000))
        Task { [weak self] in
            let prompt = """
                Write a concise chat title (3–6 words, Title Case, no quotes or trailing punctuation) \
                for a conversation that starts with this message:

                \(source)
                """
            guard let raw = await OnDeviceLLM.complete(prompt: prompt, temperature: 0.2) else {
                return
            }
            var title =
                raw
                .components(separatedBy: .newlines).first {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty
                }?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'.")) ?? ""
            // Small on-device models sometimes ignore "Title Case" and SHOUT, so normalize all-caps.
            if title == title.uppercased(), title != title.lowercased() {
                title = title.capitalized
            }
            guard let self, title.count >= 2, title.count <= 60,
                let i = self.conversationIndex(conversationID),
                // Only replace the placeholder if the user hasn't renamed it since.
                self.conversations[i].title == placeholder
            else { return }
            self.conversations[i].title = title
            self.touch(i)
        }
    }

    /// Refines the title, potentially multiple times, but only after a significant change in context.
    /// - Parameter conversationID: The UUID of the chat.
    /// - Parameter messageThreshold: How many new messages must occur before we re-title.
    func maybeRefineTitle(conversationID: UUID, messageThreshold: Int = 6) {
        guard settings.autoTitle, settings.useOnDeviceModel, OnDeviceLLM.isAvailable,
            let idx = conversationIndex(conversationID)
        else { return }

        let currentMsgs = conversations[idx].messages.filter {
            ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty
        }

        // have enough messages passed since the last successful title update?
        guard
            currentMsgs.count
                >= ((conversations[idx].lastTitledMessageCount ?? 0) + messageThreshold)
        else { return }

        let contextWindow = 8  // TODO: extract this as a setting or use messageThreshold?
        let transcript = currentMsgs.suffix(contextWindow)  // last messages
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.content.prefix(300))" }
            .joined(separator: "\n")

        let currentTitle = conversations[idx].title

        Task { [weak self] in
            let prompt = """
                Write a concise chat title (3–6 words, Title Case, no quotes or trailing punctuation) \
                that captures the subject of the most recent messages:

                \(transcript)
                """

            guard let raw = await OnDeviceLLM.complete(prompt: prompt, temperature: 0.3) else {
                return
            }

            var title =
                raw
                .components(separatedBy: .newlines).first {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty
                }?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'.")) ?? ""

            if title == title.uppercased() && title != title.lowercased() {
                title = title.capitalized
            }

            guard let self, title.count >= 2, title.count <= 60,  // check that title length is reasonable
                let i = self.conversationIndex(conversationID),  // revalidate conversation id
                self.conversations[i].title == currentTitle  // check that the user didnt manually change the title
            else { return }

            // Update the title and the tracking counter
            self.conversations[i].title = title
            self.conversations[i].lastTitledMessageCount = currentMsgs.count
            self.touch(i)
            traceStore.trace(
                conversationID: conversationID, kind: .info,
                text: "refined conversation title",
                saveTraces: settings.saveTraces)
        }
    }
}
