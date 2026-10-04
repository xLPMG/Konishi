import Foundation

/// Pure helpers for recalling past conversations through their stored digests.
enum ConversationRecall {
    struct Entry: Sendable {
        let id: UUID
        let title: String
        let date: Date
        let digest: String
    }

    /// Past-conversation summaries are held to a higher bar than memory bullets unless the user
    /// explicitly refers back to an earlier conversation.
    static let normalMargin = 0.1

    /// Conversations that have a digest, excluding Learn sessions and the one in progress.
    static func entries(from conversations: [Conversation], excluding current: UUID?) -> [Entry] {
        conversations.compactMap { c in
            guard c.id != current,
                let digest = c.digest?.trimmingCharacters(in: .whitespacesAndNewlines),
                !digest.isEmpty
            else { return nil }
            return Entry(id: c.id, title: c.title, date: c.updatedAt, digest: digest)
        }
    }

    static func chunkText(_ entry: Entry) -> String { "\(entry.title): \(entry.digest)" }

    /// Conversations untouched for this long have their digests mined for lasting highlights.
    static let rollupAge: TimeInterval = 90 * 86_400

    /// Old digests whose highlights have not been folded into History yet, oldest first.
    static func rollupCandidates(
        from conversations: [Conversation], now: Date = .now, limit: Int = 10
    ) -> [Conversation] {
        conversations
            .filter { c in
                c.digestRolledUpAt == nil
                    && c.updatedAt <= now.addingTimeInterval(-rollupAge)
                    && !(c.digest?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    static func dateString(_ date: Date) -> String { date.formatted(.iso8601.year().month().day()) }

    static func section(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "" }
        let lines = entries.map {
            "- [\(dateString($0.date)) · \($0.title)] \($0.digest)"
        }
        return "## Past conversations\n" + lines.joined(separator: "\n")
    }

    /// Whether the message points back at an earlier conversation ("last time", "we discussed", …).
    static func mentionsPast(_ text: String) -> Bool {
        pastPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let pastPattern = try! NSRegularExpression(
        pattern:
            #"\b(last time|previously|earlier (today|this week)|yesterday|last (week|month|night)|the other day|we (talked|discussed|spoke|went over|covered|decided)|remember when|you (said|told me|mentioned|suggested|recommended)|i (told|asked) you|letztes mal|neulich|gestern|vorhin|besprochen|erinnerst du|hast du (gesagt|erwähnt))\b"#,
        options: [.caseInsensitive])
}
