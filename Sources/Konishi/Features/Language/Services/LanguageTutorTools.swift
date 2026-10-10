import Foundation

enum LanguageTutorTools {
    struct Arguments: Decodable {
        struct Item: Decodable {
            let targetTerm: String
            let translation: String
            let acceptedTranslations: [String]?
            let reading: String?
            let partOfSpeech: String?
            let register: String?
            let example: String?
            let notes: String?
            let tags: [String]?
        }

        let items: [Item]?
        let query: String?
        let kind: String?
        let limit: Int?
        let offset: Int?
    }

    static let addVocabulary = ToolDef.function(
        name: "add_vocabulary",
        description: "Add up to five new vocabulary cards to the learner's active language deck. Use only when the learner explicitly asks to add or save words.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "items": .object([
                    "type": .string("array"),
                    "description": .string("Vocabulary cards to add, up to five."),
                    "maxItems": .number(5),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "target_term": JSONValue.property("string", "Word or phrase in the target language."),
                            "translation": JSONValue.property("string", "Meaning in the learner's explanation language."),
                            "accepted_translations": JSONValue.arrayProperty("Optional interchangeable translations."),
                            "reading": JSONValue.property("string", "Optional pronunciation or reading aid."),
                            "part_of_speech": JSONValue.property("string", "Optional part of speech."),
                            "register": JSONValue.property("string", "Optional register, such as formal or casual."),
                            "example": JSONValue.property("string", "Optional example sentence in the target language."),
                            "notes": JSONValue.property("string", "Optional usage note."),
                            "tags": JSONValue.arrayProperty("Optional short tags.")
                        ]),
                        "required": .array([.string("target_term"), .string("translation")])
                    ])
                ])
            ]),
            "required": .array([.string("items")])
        ])
    )

    static let deckSummary = ToolDef.function(
        name: "language_deck_summary",
        description: "Get totals, due count, mastered count, today's reviews, card-type counts, and common tags for the active language deck.",
        parameters: .schema(properties: [:], required: [])
    )

    static let deckList = ToolDef.function(
        name: "language_deck_list",
        description: "List cards in the active language deck, newest first. Use offset to page through larger decks; kind may be vocab, grammar, or phrase.",
        parameters: .schema(
            properties: [
                "kind": .property("string", "Optional card kind: vocab, grammar, or phrase."),
                "limit": .property("integer", "Number of cards, 1 to 30; default 20."),
                "offset": .property("integer", "Zero-based result offset for paging; default 0.")
            ],
            required: []
        )
    )

    static let deckSearch = ToolDef.function(
        name: "language_deck_search",
        description: "Search the active language deck by target term, reading, or translation.",
        parameters: .schema(
            properties: [
                "query": .property("string", "Text to find in a card's term, reading, or translation."),
                "limit": .property("integer", "Maximum matches, 1 to 30; default 20.")
            ],
            required: ["query"]
        )
    )

    static let dueItems = ToolDef.function(
        name: "language_due_items",
        description: "List cards currently due for review in the active language deck. A card is due when its scheduled review date has passed.",
        parameters: .schema(
            properties: ["limit": .property("integer", "Maximum cards, 1 to 30; default 20.")],
            required: []
        )
    )

    static let reviewHistory = ToolDef.function(
        name: "language_review_history",
        description: "Read recent review attempts for cards in the active language deck, newest first.",
        parameters: .schema(
            properties: ["limit": .property("integer", "Maximum attempts, 1 to 30; default 10.")],
            required: []
        )
    )

    static let definitions = [addVocabulary, deckSummary, deckList, deckSearch, dueItems, reviewHistory]
}