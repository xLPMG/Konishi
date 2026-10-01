import Foundation

/// Short-term memory: facts staged by the extractor that are retrievable right away and later
/// promoted (or dropped) by the sleep pass. Persisted as one small JSON file.
@MainActor
final class STMStore {
    struct State: Codable {
        var activeDay = 0
        var lastActiveDate = ""
        var facts: [STMFact] = []
        /// Bullet count per persona scope at its last consolidation, so launches don't redo it.
        var lastConsolidated: [String: Int] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            activeDay = try c.decodeIfPresent(Int.self, forKey: .activeDay) ?? 0
            lastActiveDate = try c.decodeIfPresent(String.self, forKey: .lastActiveDate) ?? ""
            facts = try c.decodeIfPresent([STMFact].self, forKey: .facts) ?? []
            lastConsolidated = try c.decodeIfPresent([String: Int].self, forKey: .lastConsolidated) ?? [:]
        }
    }

    struct PromotionOutcome {
        var promoted: [STMFact] = []
        var dropped: [STMFact] = []
        /// Facts not written because a bullet already said the same, with that bullet.
        var covered: [(fact: STMFact, by: String)] = []
    }

    private(set) var state: State
    private let url: URL?
    private static let referenceCap = 50

    /// `url: nil` keeps everything in memory (tests).
    init(url: URL? = Paths.shortTermMemory) {
        self.url = url
        state = url.flatMap(Self.load) ?? State()
    }

    var facts: [STMFact] { state.facts }
    var activeDay: Int { state.activeDay }

    func lastConsolidated(_ scope: String) -> Int? { state.lastConsolidated[scope] }

    func setConsolidated(_ count: Int, scope: String) {
        state.lastConsolidated[scope] = count
        save()
    }

    /// Advance the active-day clock; call whenever the user is actually using the app.
    func tick(now: Date = .now) {
        let next = ActiveDayClock.advance(
            day: state.activeDay, last: state.lastActiveDate, now: now)
        guard next.day != state.activeDay else { return }
        state.activeDay = next.day
        state.lastActiveDate = next.last
        save()
    }

    /// Pending facts in the given scopes, keyed by category (bullet text without markers).
    func pendingLines(scopes: [String]) -> [MemoryCategory: [String]] {
        var result: [MemoryCategory: [String]] = [:]
        for fact in state.facts where scopes.contains(fact.scope) {
            result[fact.category, default: []].append(fact.text)
        }
        return result
    }

    // MARK: Mutations from extraction

    /// Applies the short-term effects of an extraction pass: new facts, repeat mentions, and
    /// removals or corrections of facts that have not been promoted yet.
    func apply(
        _ result: MemoryProfile.ApplyResult, global: String, persona: String,
        conversationID: UUID, now: Date = .now
    ) {
        tick(now: now)
        func scope(_ c: MemoryCategory) -> String { c.targetScope(global: global, persona: persona) }

        for item in result.staged {
            if let i = index(item.category, scope(item.category), item.fact) {
                mention(i, conversationID, salience: item.salience)
            } else {
                state.facts.append(
                    STMFact(
                        category: item.category, scope: scope(item.category), text: item.fact,
                        salience: item.salience, createdAt: now, createdDay: state.activeDay,
                        mentionedIn: [conversationID], retrievedIn: []))
            }
        }
        for item in result.restated {
            if let i = index(item.category, scope(item.category), item.fact) {
                mention(i, conversationID, salience: item.salience)
            }
        }
        for item in result.pendingRemovals {
            if let i = index(item.category, scope(item.category), item.fact) {
                state.facts.remove(at: i)
            }
        }
        for (old, new) in result.pendingReplacements {
            if let i = index(old.category, scope(old.category), old.fact) {
                state.facts[i].text = new
                mention(i, conversationID, salience: old.salience)
            }
        }
        save()
    }

    private func index(_ category: MemoryCategory, _ scope: String, _ text: String) -> Int? {
        let key = MemoryProfile.normalizedFact(text)
        return state.facts.firstIndex {
            $0.category == category && $0.scope == scope
                && MemoryProfile.normalizedFact($0.text) == key
        }
    }

    private func mention(_ i: Int, _ conversationID: UUID, salience: Int) {
        if !state.facts[i].mentionedIn.contains(conversationID) {
            state.facts[i].mentionedIn.append(conversationID)
            if state.facts[i].mentionedIn.count > Self.referenceCap {
                state.facts[i].mentionedIn.removeFirst()
            }
        }
        state.facts[i].salience = max(state.facts[i].salience, salience)
    }

    /// Records that these facts were injected into a conversation (counted once per conversation).
    func markRetrieved(_ ids: [UUID], in conversationID: UUID, now: Date = .now) {
        var changed = false
        for id in ids {
            guard let i = state.facts.firstIndex(where: { $0.id == id }) else { continue }
            state.facts[i].lastRetrievedAt = now
            if !state.facts[i].retrievedIn.contains(conversationID) {
                state.facts[i].retrievedIn.append(conversationID)
                if state.facts[i].retrievedIn.count > Self.referenceCap {
                    state.facts[i].retrievedIn.removeFirst()
                }
            }
            changed = true
        }
        if changed { save() }
    }

    func remove(_ id: UUID) {
        state.facts.removeAll { $0.id == id }
        save()
    }

    /// Manually promote one fact into its category file right now.
    func promote(_ id: UUID, to store: MemoryStore) {
        guard let fact = state.facts.first(where: { $0.id == id }) else { return }
        let file = store.file(scope: fact.scope, name: fact.category.fileName)
        store.write(
            scope: fact.scope, name: fact.category.fileName,
            content: MemoryProfile.canonical(store.read(file) + "\n- \(fact.text)"))
        remove(id)
    }

    // MARK: Promotion

    /// Promotes qualifying facts into the category files and drops the ones that never earned a
    /// place. Deterministic: no model involved.
    @discardableResult
    func applyPromotion(to store: MemoryStore) -> PromotionOutcome {
        var outcome = PromotionOutcome()
        var promoteIDs = Set<UUID>()
        var dropIDs = MemoryPromotion.overflow(state.facts)
        for fact in state.facts {
            switch MemoryPromotion.decide(fact, activeDay: state.activeDay) {
            case .promote: promoteIDs.insert(fact.id)
            case .drop: dropIDs.insert(fact.id)
            case .keep: break
            }
        }
        dropIDs.subtract(promoteIDs)
        guard !promoteIDs.isEmpty || !dropIDs.isEmpty else { return outcome }

        struct Target: Hashable {
            let scope: String
            let category: MemoryCategory
        }
        var byTarget: [Target: [STMFact]] = [:]
        for fact in state.facts where promoteIDs.contains(fact.id) {
            byTarget[Target(scope: fact.scope, category: fact.category), default: []].append(fact)
        }
        var coveredIDs = Set<UUID>()
        for (target, facts) in byTarget {
            let file = store.file(scope: target.scope, name: target.category.fileName)
            var lines = MemoryStore.blocks(store.read(file))
            var added: [String] = []
            // Most informative first, so a shorter restatement is judged against the fuller one.
            let ordered = facts.sorted {
                MemoryProfile.contentTokens($0.text).count > MemoryProfile.contentTokens($1.text).count
            }
            for fact in ordered {
                if let line = MemoryProfile.coveringLine(for: fact.text, in: lines) {
                    coveredIDs.insert(fact.id)
                    outcome.covered.append((fact, line))
                } else {
                    lines.append(fact.text)
                    added.append("- \(fact.text)")
                }
            }
            guard !added.isEmpty else { continue }
            store.write(
                scope: target.scope, name: target.category.fileName,
                content: MemoryProfile.canonical(([store.read(file)] + added).joined(separator: "\n")))
        }
        outcome.promoted = state.facts.filter { promoteIDs.contains($0.id) && !coveredIDs.contains($0.id) }
        outcome.dropped = state.facts.filter { dropIDs.contains($0.id) }
        state.facts.removeAll { promoteIDs.contains($0.id) || dropIDs.contains($0.id) }
        save()
        return outcome
    }

    // MARK: Persistence

    private func save() {
        guard let url else { return }
        guard let data = try? Self.encoder.encode(state) else { return }
        Persistence.ioQueue.async { try? data.write(to: url, options: .atomic) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static func load(from url: URL) -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }
}
