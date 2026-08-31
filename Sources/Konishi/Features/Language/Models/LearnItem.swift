import Foundation

/// What a deck card teaches.
enum LearnKind: String, Codable, CaseIterable, Sendable {
    case vocab
    case grammar
    case phrase

    var label: String {
        switch self {
        case .vocab: "Vocabulary"
        case .grammar: "Grammar"
        case .phrase: "Phrase"
        }
    }

    var icon: String {
        switch self {
        case .vocab: "textformat.abc"
        case .grammar: "text.book.closed"
        case .phrase: "quote.bubble"
        }
    }
}

/// A single spaced-repetition card (vocabulary word, grammar point, or phrase).
///
/// Scheduling uses a 5-box Leitner system: a correct answer promotes the card one box,
/// a wrong answer resets it to box 1, and the box determines the next review interval.
struct LearnItem: Identifiable, Equatable, Sendable {
    var id = UUID()
    var profileID: UUID
    var kind: LearnKind
    /// The word / grammar point / phrase in the target language.
    var term: String
    /// Pronunciation or reading aid (e.g. romanization, furigana). Optional.
    var reading: String
    /// Meaning in the base language.
    var translation: String
    /// Part of speech (vocab) or category (grammar). Optional.
    var partOfSpeech: String
    /// Display-only register marker (e.g. "formal", "honorific", "slang"). Never quizzed.
    var register: String
    /// Display-only usage caveats / notes, shown on hover or click. Never quizzed.
    var notes: String
    var examples: [String]
    var tags: [String]

    // Leitner scheduling
    var box: Int                // 1…5
    var dueDate: Date

    // Raw performance counts (shown in the deck view)
    var timesSeen: Int
    var timesCorrect: Int
    var timesWrong: Int

    var createdAt: Date
    var lastReviewedAt: Date?
    var sourceConversationID: UUID?

    /// Leitner review intervals in days, indexed by box (1…5).
    static let boxIntervals: [Int] = [1, 3, 7, 16, 35]
    static let boxCount = boxIntervals.count

    static func interval(forBox box: Int) -> Int {
        let clamped = min(max(box, 1), boxCount)
        return boxIntervals[clamped - 1]
    }

    init(
        id: UUID = UUID(),
        profileID: UUID,
        kind: LearnKind,
        term: String,
        reading: String = "",
        translation: String = "",
        partOfSpeech: String = "",
        register: String = "",
        notes: String = "",
        examples: [String] = [],
        tags: [String] = [],
        box: Int = 1,
        dueDate: Date? = nil,
        timesSeen: Int = 0,
        timesCorrect: Int = 0,
        timesWrong: Int = 0,
        createdAt: Date = Date(),
        lastReviewedAt: Date? = nil,
        sourceConversationID: UUID? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.kind = kind
        self.term = term
        self.reading = reading
        self.register = register
        self.notes = notes
        self.translation = translation
        self.partOfSpeech = partOfSpeech
        self.examples = examples
        self.tags = tags
        self.box = min(max(box, 1), Self.boxCount)
        // A brand-new card hasn't been studied yet, so it's due immediately (today); the box
        // interval only kicks in after the first review.
        self.dueDate = dueDate ?? createdAt
        self.timesSeen = timesSeen
        self.timesCorrect = timesCorrect
        self.timesWrong = timesWrong
        self.createdAt = createdAt
        self.lastReviewedAt = lastReviewedAt
        self.sourceConversationID = sourceConversationID
    }

    /// Due when the review date has passed.
    func isDue(at now: Date = Date()) -> Bool { dueDate <= now }

    /// Progress toward mastery, 0…1, derived from the current Leitner box.
    var mastery: Double { Double(box) / Double(Self.boxCount) }

    var accuracy: Double {
        let total = timesCorrect + timesWrong
        return total == 0 ? 0 : Double(timesCorrect) / Double(total)
    }

    /// Applies a Leitner review outcome in place: promotes on correct, resets on wrong,
    /// then reschedules the next review based on the new box.
    mutating func recordReview(correct: Bool, at now: Date = Date()) {
        timesSeen += 1
        if correct {
            timesCorrect += 1
            box = min(box + 1, Self.boxCount)
        } else {
            timesWrong += 1
            box = 1
        }
        lastReviewedAt = now
        dueDate = Calendar.current.date(byAdding: .day, value: Self.interval(forBox: box), to: now) ?? now
    }
}
