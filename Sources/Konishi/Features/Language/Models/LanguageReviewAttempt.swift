import Foundation

struct LanguageReviewAttempt: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var profileID: UUID
    var itemID: UUID
    var activity: LanguageActivity
    var outcome: LanguageReviewOutcome
    var createdAt: Date
    var submittedAnswer: String?
    var sessionID: UUID?

    init(
        id: UUID = UUID(), profileID: UUID, itemID: UUID, activity: LanguageActivity,
        outcome: LanguageReviewOutcome, createdAt: Date = Date(), submittedAnswer: String? = nil,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.itemID = itemID
        self.activity = activity
        self.outcome = outcome
        self.createdAt = createdAt
        self.submittedAnswer = submittedAnswer
        self.sessionID = sessionID
    }
}

enum LanguageReviewRecordResult: Equatable, Sendable {
    case recorded(LearnItem)
    case alreadyRecorded(LearnItem)
    case missingCard
    case profileMismatch
    case invalidAttempt
    case attemptIDConflict
    case failed(String)
}