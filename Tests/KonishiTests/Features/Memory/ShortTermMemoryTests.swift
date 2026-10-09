import Foundation
import Testing

@testable import Konishi

@Suite("ShortTermMemory")
struct ShortTermMemoryTests {

    private func fact(
        _ text: String = "likes tea", category: MemoryCategory = .preferences, salience: Int = 2,
        day: Int = 0, mentions: Int = 1, retrievals: Int = 0
    ) -> STMFact {
        STMFact(
            category: category, scope: "global", text: text, salience: salience,
            createdAt: Date(timeIntervalSince1970: 1_000), createdDay: day,
            mentionedIn: (0..<mentions).map { _ in UUID() },
            retrievedIn: (0..<retrievals).map { _ in UUID() })
    }

    private func tempStore() -> (MemoryStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stm-\(UUID().uuidString)", isDirectory: true)
        return (MemoryStore(root: root, backupsRoot: root.appendingPathComponent("backups")), root)
    }

    // MARK: Promotion scoring

    @Test("a fresh minor fact is kept pending")
    func freshMinorFactKept() {
        #expect(MemoryPromotion.decide(fact(salience: 1), activeDay: 0) == .keep)
    }

    @Test("an explicit, high-salience fact is promoted right away")
    func highSalienceFactPromoted() {
        #expect(MemoryPromotion.decide(fact(salience: 3), activeDay: 0) == .promote)
    }

    @Test("a medium fact repeated in another conversation is promoted")
    func repeatedFactPromoted() {
        #expect(MemoryPromotion.decide(fact(salience: 2, mentions: 2), activeDay: 0) == .promote)
    }

    @Test("mature facts need independent reinforcement to be promoted")
    func matureFactsResolve() {
        let day = MemoryPromotion.maturityDays
        #expect(MemoryPromotion.decide(fact(salience: 2), activeDay: day) == .drop)
        #expect(MemoryPromotion.decide(fact(salience: 2, mentions: 2), activeDay: day) == .promote)
        #expect(MemoryPromotion.decide(fact(salience: 1), activeDay: day) == .drop)
    }

    @Test("a mature minor fact that keeps being retrieved is promoted")
    func retrievedMinorFactPromoted() {
        let day = MemoryPromotion.maturityDays
        #expect(MemoryPromotion.decide(fact(salience: 1, retrievals: 1), activeDay: day) == .promote)
    }

    @Test("overflow evicts the lowest-scoring facts first")
    func overflowEvictsLowest() {
        let weak = fact("weak", salience: 1)
        let strong = fact("strong", salience: 2, retrievals: 1)
        #expect(MemoryPromotion.overflow([strong, weak], capacity: 1) == [weak.id])
    }

    // MARK: Active-day clock

    @Test("the clock advances only when the calendar day changes")
    func clockAdvancesOncePerDay() {
        let cal = Calendar(identifier: .gregorian)
        let morning = Date(timeIntervalSince1970: 1_750_000_000)
        let evening = morning.addingTimeInterval(3_600)
        let nextWeek = morning.addingTimeInterval(7 * 86_400)
        let first = ActiveDayClock.advance(day: 0, last: "", now: morning, calendar: cal)
        let same = ActiveDayClock.advance(day: first.day, last: first.last, now: evening, calendar: cal)
        let later = ActiveDayClock.advance(day: same.day, last: same.last, now: nextWeek, calendar: cal)
        #expect(first.day == 1)
        #expect(same.day == 1)
        #expect(later.day == 2)
    }

    // MARK: Extraction → staging

    @Test("apply stages new facts instead of writing them to the category file")
    func applyStagesAdds() {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let delta = MemoryProfile.Delta(operations: [
            .init(action: .add, category: .profile, fact: "Name is Luca", salience: 3)
        ])
        let result = MemoryProfile.apply(delta, store: store, global: "global", persona: "p", pending: [:])
        #expect(result.changedBodies.isEmpty)
        #expect(result.staged == [.init(category: .profile, fact: "Name is Luca", salience: 3)])
    }

    @Test("apply without pending facts still writes straight to long-term memory")
    func applyWithoutPendingWrites() {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let delta = MemoryProfile.Delta(operations: [
            .init(action: .add, category: .profile, fact: "Name is Luca")
        ])
        let result = MemoryProfile.apply(delta, store: store, global: "global", persona: "p")
        #expect(result.changedBodies[.profile] == "- Name is Luca")
        #expect(result.staged.isEmpty)
    }

    @Test("a correction of a pending fact becomes a pending replacement")
    func applyReplacesPendingFact() {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let delta = MemoryProfile.Delta(operations: [
            .init(action: .replace, category: .profile, fact: "Lives in Munich", replacement: "Lives in Berlin")
        ])
        let result = MemoryProfile.apply(
            delta, store: store, global: "global", persona: "p",
            pending: [.profile: ["Lives in Munich"]])
        #expect(result.pendingReplacements.count == 1)
        #expect(result.pendingReplacements.first?.new == "Lives in Berlin")
        #expect(result.changedBodies.isEmpty)
    }

    @Test("a fact already in long-term memory is not staged again")
    func applySkipsKnownFact() {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.write(scope: "global", name: "profile.md", content: "- Name is Luca")
        let delta = MemoryProfile.Delta(operations: [
            .init(action: .add, category: .profile, fact: "name is luca")
        ])
        let result = MemoryProfile.apply(delta, store: store, global: "global", persona: "p", pending: [:])
        #expect(result.staged.isEmpty)
    }

    @Test("parseDelta accepts a digest-only reply and tolerates a bad salience")
    func parseDeltaTolerant() {
        let digestOnly = MemoryProfile.parseDelta(#"{"digest":"Talked about tea."}"#)
        #expect(digestOnly?.digest == "Talked about tea.")
        #expect(digestOnly?.operations.isEmpty == true)
        let messy = MemoryProfile.parseDelta(
            #"{"operations":[{"action":"add","category":"rapport","fact":"x y","salience":"high"}]}"#)
        #expect(messy?.operations.first?.category == .rapport)
        #expect(messy?.operations.first?.salience == nil)
    }

    @Test("relevantSnapshot keeps everything when small and only relevant bullets when large")
    func relevantSnapshotLimits() {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (0..<60).map { "- fact number \($0) about topic\($0)" }.joined(separator: "\n")
        store.write(scope: "global", name: "projects.md", content: lines)
        let small = MemoryProfile.relevantSnapshot(
            store: store, global: "global", persona: "p", pending: [:], query: "topic7", limit: 100)
        #expect(small.contains("topic59"))
        let focused = MemoryProfile.relevantSnapshot(
            store: store, global: "global", persona: "p", pending: [.profile: ["Name is Luca"]],
            query: "topic7", limit: 5)
        #expect(focused.contains("topic7"))
        #expect(!focused.contains("topic59"))
    }

    // MARK: STMStore

    // MARK: Near-duplicates

    @Test("a restated fact or one inside a short bare value is redundant")
    func redundancyRules() {
        #expect(MemoryProfile.isRedundant("Name is Luca", given: "- Luca-Philipp"))
        #expect(MemoryProfile.isRedundant("User's name is Luca.", given: "Name is Luca"))
        #expect(MemoryProfile.isRedundant("Studies physics", given: "Studies physics at university"))
        #expect(MemoryProfile.isRedundant("Uses Swift daily", given: "Uses Swift daily."))
    }

    @Test("the rule stays out of the way when facts may differ")
    func redundancyIsConservative() {
        #expect(!MemoryProfile.isRedundant("Likes tea", given: "Does not like tea"))
        #expect(!MemoryProfile.isRedundant("Name is Anna", given: "Luca-Philipp"))
        #expect(!MemoryProfile.isRedundant("Is the user", given: "Luca-Philipp"))
        // A longer existing bullet is not allowed to absorb a shorter fact.
        #expect(!MemoryProfile.isRedundant("Uses Swift", given: "Uses Swift for iOS apps at work"))
        // Labelled values keep their owner.
        #expect(!MemoryProfile.isRedundant("Name is Luca", given: "Sister's name is Luca"))
        // Change-of-state words must match.
        #expect(!MemoryProfile.isRedundant("Works at Google", given: "Left Google"))
        #expect(!MemoryProfile.isRedundant("Works at Google", given: "Formerly worked at Google"))
    }

    @Test("extraction does not stage a fact that a bare long-term bullet already covers")
    func applySkipsCoveredFact() {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.write(scope: "global", name: "profile.md", content: "- Luca-Philipp")
        let delta = MemoryProfile.Delta(operations: [
            .init(action: .add, category: .profile, fact: "Name is Luca"),
            .init(action: .add, category: .profile, fact: "Studies physics"),
            .init(action: .add, category: .profile, fact: "Studies physics at university"),
        ])
        let result = MemoryProfile.apply(delta, store: store, global: "global", persona: "p", pending: [:])
        #expect(result.staged.map(\.fact) == ["Studies physics", "Studies physics at university"])
        #expect(result.restated.isEmpty)
    }

    @Test("promotion skips facts already covered by the file and by each other")
    @MainActor
    func promotionSkipsNearDuplicates() {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.write(scope: "global", name: "profile.md", content: "- Luca-Philipp")
        let stm = STMStore(url: nil)
        var result = MemoryProfile.ApplyResult(changedBodies: [:], appliedCount: 2, skippedCount: 0, detail: "")
        result.staged = [
            .init(category: .profile, fact: "Name is Luca", salience: 3),
            .init(category: .profile, fact: "User's name is Luca.", salience: 3),
            .init(category: .profile, fact: "Studies physics", salience: 3),
            .init(category: .profile, fact: "Studies physics at university", salience: 3),
        ]
        stm.apply(result, global: "global", persona: "p", conversationID: UUID())
        let outcome = stm.applyPromotion(to: store)
        #expect(outcome.promoted.map(\.text) == ["Studies physics at university"])
        #expect(outcome.covered.count == 3)
        #expect(outcome.covered.contains { $0.fact.text == "Name is Luca" && $0.by == "Luca-Philipp" })
        #expect(
            store.read(store.file(scope: "global", name: "profile.md"))
                == "- Luca-Philipp\n- Studies physics at university")
    }

    @Test("staged facts are stored, counted once per conversation, and promoted")
    @MainActor
    func storeStagesAndPromotes() {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let stm = STMStore(url: nil)
        let convo = UUID()
        var result = MemoryProfile.ApplyResult(changedBodies: [:], appliedCount: 1, skippedCount: 0, detail: "")
        result.staged = [.init(category: .profile, fact: "Name is Luca", salience: 3)]
        stm.apply(result, global: "global", persona: "p", conversationID: convo)
        #expect(stm.facts.count == 1)
        #expect(stm.pendingLines(scopes: ["global"])[.profile] == ["Name is Luca"])

        let id = stm.facts[0].id
        stm.markRetrieved([id], in: convo)
        stm.markRetrieved([id], in: convo)
        #expect(stm.facts[0].retrievals == 0)
        let otherConversation = UUID()
        stm.markRetrieved([id], in: otherConversation)
        stm.markRetrieved([id], in: otherConversation)
        #expect(stm.facts[0].retrievals == 1)

        let outcome = stm.applyPromotion(to: store)
        #expect(outcome.promoted.count == 1)
        #expect(stm.facts.isEmpty)
        #expect(store.read(store.file(scope: "global", name: "profile.md")) == "- Name is Luca")
    }

    @Test("retrieval in the source conversation does not count as independent reuse")
    @MainActor
    func sourceConversationRetrievalDoesNotReinforce() {
        let stm = STMStore(url: nil)
        let sourceConversation = UUID()
        var result = MemoryProfile.ApplyResult(changedBodies: [:], appliedCount: 1, skippedCount: 0, detail: "")
        result.staged = [.init(category: .projects, fact: "Building a spectrometer", salience: 2)]
        stm.apply(result, global: "global", persona: "p", conversationID: sourceConversation)

        let id = stm.facts[0].id
        stm.markRetrieved([id], in: sourceConversation)
        #expect(stm.facts[0].retrievals == 0)
        #expect(MemoryPromotion.decide(stm.facts[0], activeDay: 0) == .keep)

        stm.markRetrieved([id], in: UUID())
        #expect(stm.facts[0].retrievals == 1)
        #expect(MemoryPromotion.decide(stm.facts[0], activeDay: 0) == .promote)
    }

    @Test("promotion does not duplicate a bullet that is already long-term")
    @MainActor
    func promotionDeduplicates() {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.write(scope: "global", name: "profile.md", content: "- Name is Luca")
        let stm = STMStore(url: nil)
        var result = MemoryProfile.ApplyResult(changedBodies: [:], appliedCount: 1, skippedCount: 0, detail: "")
        result.staged = [.init(category: .profile, fact: "name is luca", salience: 3)]
        stm.apply(result, global: "global", persona: "p", conversationID: UUID())
        stm.applyPromotion(to: store)
        #expect(store.read(store.file(scope: "global", name: "profile.md")) == "- Name is Luca")
    }

    @Test("a repeated statement in a second conversation counts as a mention")
    @MainActor
    func repeatedMentionRaisesScore() {
        let stm = STMStore(url: nil)
        var result = MemoryProfile.ApplyResult(changedBodies: [:], appliedCount: 1, skippedCount: 0, detail: "")
        result.staged = [.init(category: .preferences, fact: "Likes tea", salience: 2)]
        stm.apply(result, global: "global", persona: "p", conversationID: UUID())
        stm.apply(result, global: "global", persona: "p", conversationID: UUID())
        #expect(stm.facts.count == 1)
        #expect(stm.facts[0].mentions == 2)
    }

    @Test("pending facts are retrievable and reported as hits")
    @MainActor
    func retrieveIncludesShortTermFacts() async {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = fact("loves hiking in the mountains", category: .preferences)
        let cache = EmbeddingCache(url: FileManager.default.temporaryDirectory.appendingPathComponent("e-\(UUID()).bin"))
        let config = RequestConfig(
            chatURL: nil, modelsURL: nil, apiModelsURL: nil, embeddingsURL: nil,
            transcriptionsURL: nil, speechURL: nil, audioModelsURL: nil, audioVoicesURL: nil,
            model: "m", temperature: 0.7, topP: nil, maxTokens: nil, stop: nil, seed: nil,
            presencePenalty: nil, frequencyPenalty: nil, token: "", embeddingModel: "e",
            sttModel: "", ttsModel: "", ttsVoice: "")
        let result = await store.retrieve(
            scopes: ["global"], query: "hiking mountains", cache: cache, requestConfig: config,
            threshold: 0.5, topK: 3, shortTerm: [pending])
        #expect(result.text.contains("loves hiking in the mountains"))
        #expect(result.stmHits == [pending.id])
    }

    // MARK: Conversation recall

    @Test("mentionsPast recognises references to earlier conversations")
    func mentionsPast() {
        #expect(ConversationRecall.mentionsPast("What did we discuss last time about the thesis?"))
        #expect(ConversationRecall.mentionsPast("Remember when you told me about Rust?"))
        #expect(ConversationRecall.mentionsPast("Was haben wir gestern besprochen?"))
        #expect(!ConversationRecall.mentionsPast("How do I sort an array in Swift?"))
    }

    @Test("ambient recall rejects vague prompts and weak lexical matches")
    func ambientRecallRequiresSpecificEvidence() {
        #expect(!ConversationRecall.hasSpecificTopic("this is a test"))
        #expect(ConversationRecall.hasSpecificTopic("science rendering test sheet"))
        #expect(!ConversationRecall.hasStrongFallbackMatch(
            query: "this is a test", digest: "Science rendering test sheet"))
        #expect(ConversationRecall.hasStrongFallbackMatch(
            query: "science rendering test sheet", digest: "Science rendering formulas"))
    }

    @Test("entries skip the current chat and chats without a digest")
    func entriesFilter() {
        let current = Conversation(title: "current", digest: "now")
        let other = Conversation(title: "other", digest: "More tea.")
        let blank = Conversation(title: "blank", digest: "  ")
        let good = Conversation(title: "good", digest: "Talked about tea.")
        let entries = ConversationRecall.entries(
            from: [current, other, blank, good, Conversation(title: "none")], excluding: current.id)
        #expect(entries.map(\.title) == ["other", "good"])
    }

    // MARK: Rollup

    @Test("rollup candidates are old, summarized, not yet rolled up, oldest first")
    func rollupCandidatesFilter() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-120 * 86_400)
        let older = now.addingTimeInterval(-200 * 86_400)
        let recent = now.addingTimeInterval(-10 * 86_400)
        var done = Conversation(title: "done", updatedAt: old, digest: "x")
        done.digestRolledUpAt = now
        let candidates = ConversationRecall.rollupCandidates(
            from: [
                Conversation(title: "old", updatedAt: old, digest: "Finished thesis chapter 2."),
                Conversation(title: "older", updatedAt: older, digest: "Moved to Berlin."),
                Conversation(title: "recent", updatedAt: recent, digest: "Talked."),
                Conversation(title: "blank", updatedAt: old, digest: " "),
                done,
            ], now: now)
        #expect(candidates.map(\.title) == ["older", "old"])
    }

    @Test("parseHighlights reads the JSON reply and rejects prose")
    func parseHighlights() {
        let ok = MemoryProfile.parseHighlights(
            "```json\n{\"highlights\":[\"Moved to Berlin in March 2026\", \"  \"]}\n```")
        #expect(ok == ["Moved to Berlin in March 2026"])
        #expect(MemoryProfile.parseHighlights(#"{"highlights":[]}"#) == [])
        #expect(MemoryProfile.parseHighlights("Nothing lasting happened.") == nil)
    }
}
