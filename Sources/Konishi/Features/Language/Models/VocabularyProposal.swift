import Foundation

struct VocabularyProposal: Identifiable, Equatable, Sendable {
    let id: UUID
    var targetTerm: String
    var translation: String
    var reading: String
    var partOfSpeech: String
    var register: String
    var example: String
    var notes: String
    var tags: [String]

    init(
        id: UUID = UUID(), targetTerm: String, translation: String, reading: String = "",
        partOfSpeech: String = "", register: String = "", example: String = "",
        notes: String = "", tags: [String] = []
    ) {
        self.id = id
        self.targetTerm = targetTerm
        self.translation = translation
        self.reading = reading
        self.partOfSpeech = partOfSpeech
        self.register = register
        self.example = example
        self.notes = notes
        self.tags = tags
    }

    func normalized() -> VocabularyProposal? {
        let term = Self.normalizeField(targetTerm)
        let meaning = Self.normalizeField(translation)
        guard !term.isEmpty, !meaning.isEmpty else { return nil }
        return VocabularyProposal(
            id: id, targetTerm: term, translation: meaning,
            reading: Self.normalizeField(reading), partOfSpeech: Self.normalizeField(partOfSpeech),
            register: Self.normalizeField(register), example: Self.normalizeField(example),
            notes: Self.normalizeField(notes),
            tags: Array(Set(tags.map(Self.normalizeField).filter { !$0.isEmpty })).sorted())
    }

    static func validatedBatch(_ proposals: [VocabularyProposal], limit: Int = 5) -> [VocabularyProposal] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        return proposals.compactMap { $0.normalized() }
            .filter { seen.insert(LanguageLearningEngine.normalizeAnswer($0.targetTerm)).inserted }
            .prefix(limit)
            .map { $0 }
    }

    private static func normalizeField(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}