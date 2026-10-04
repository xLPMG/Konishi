import Testing

@testable import Konishi

@Suite("VocabularyProposal")
struct VocabularyProposalTests {
    @Test("normalizes required fields and deduplicates candidate batches")
    func normalizesAndDeduplicates() {
        let proposals = [
            VocabularyProposal(
                targetTerm: "  学校 ", translation: "  school  ",
                acceptedTranslations: [" school building ", "SCHOOL", "school   building", "academy"],
                reading: " がっこう ",
                example: "学校へ行きます", tags: ["daily life", "daily life", ""]),
            VocabularyProposal(targetTerm: "学校", translation: "school building"),
            VocabularyProposal(targetTerm: " ", translation: "invalid"),
        ]

        let result = VocabularyProposal.validatedBatch(proposals)
        #expect(result.count == 1)
        #expect(result[0].targetTerm == "学校")
        #expect(result[0].translation == "school")
        #expect(result[0].acceptedTranslations == ["school building", "academy"])
        #expect(result[0].reading == "がっこう")
        #expect(result[0].tags == ["daily life"])
    }

    @Test("limits candidate batches")
    func boundedBatch() {
        let proposals = (0..<8).map {
            VocabularyProposal(targetTerm: "term \($0)", translation: "meaning \($0)")
        }
        #expect(VocabularyProposal.validatedBatch(proposals).count == 5)
    }
}