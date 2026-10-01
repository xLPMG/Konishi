import Foundation

/// A fact learned in conversation that has not yet been promoted to long-term memory. It is
/// retrievable immediately; the sleep pass decides later whether it earns a permanent bullet.
struct STMFact: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var category: MemoryCategory
    /// Memory scope the fact will be promoted into (global or a persona scope).
    var scope: String
    /// Plain fact text, without a bullet marker.
    var text: String
    /// 1 = minor or short-lived, 2 = likely useful later, 3 = stable identity or explicitly requested.
    var salience: Int
    var createdAt: Date
    /// Active-day index at creation (see `ActiveDayClock`).
    var createdDay: Int
    /// Distinct conversations that stated this fact.
    var mentionedIn: [UUID]
    /// Distinct conversations in which this fact was retrieved into context.
    var retrievedIn: [UUID]
    var lastRetrievedAt: Date?

    var mentions: Int { mentionedIn.count }
    var retrievals: Int { retrievedIn.filter { !mentionedIn.contains($0) }.count }
}

/// Decides which short-term facts graduate to long-term memory. Pure, so it is unit-testable.
enum MemoryPromotion {
    enum Decision: Equatable { case promote, keep, drop }

    static let promoteScore = 2.0
    /// Active days a fact may stay pending before it must be promoted or dropped.
    static let maturityDays = 7
    static let capacity = 300

    static func score(_ fact: STMFact) -> Double {
        Double(max(0, fact.salience - 1))
            + log2(1 + Double(fact.retrievals))
            + Double(max(0, fact.mentions - 1))
    }

    static func decide(_ fact: STMFact, activeDay: Int) -> Decision {
        let score = score(fact)
        if score >= promoteScore { return .promote }
        guard activeDay - fact.createdDay >= maturityDays else { return .keep }
        return fact.mentions > 1 || fact.retrievals > 0 ? .promote : .drop
    }

    /// Ids to evict so at most `capacity` facts remain: lowest score first, oldest first on ties.
    static func overflow(_ facts: [STMFact], capacity: Int = capacity) -> Set<UUID> {
        guard facts.count > capacity else { return [] }
        let ranked = facts.sorted {
            let (a, b) = (score($0), score($1))
            return a != b ? a < b : $0.createdAt < $1.createdAt
        }
        return Set(ranked.prefix(facts.count - capacity).map(\.id))
    }
}

/// Counts days the app was actually used, so short-term facts never expire while the user is away.
enum ActiveDayClock {
    static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The clock moves forward by one only when the calendar day differs from the last active day.
    static func advance(day: Int, last: String, now: Date, calendar: Calendar = .current) -> (
        day: Int, last: String
    ) {
        let today = stamp(now, calendar: calendar)
        return today == last ? (day, last) : (day + 1, today)
    }
}
