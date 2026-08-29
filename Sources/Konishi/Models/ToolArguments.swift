import Foundation

enum ToolArguments {
    struct MemoryRead: Decodable {
        var scope: String?
        let name: String
    }

    struct MemoryWrite: Decodable {
        var scope: String?
        let name: String
        let content: String
    }

    struct FileRead: Decodable {
        let path: String
        var offset: Int?
        var limit: Int?
    }

    struct URLValue: Decodable { let url: String }
    struct Query: Decodable { let query: String }
    struct Research: Decodable {
        let query: String
        var maxSources: Int?
    }
    struct Python: Decodable { let code: String }
    struct Calculation: Decodable { let expression: String }
    struct DueItems: Decodable { var limit: Int? }

    struct AddVocabulary: Decodable {
        let term: String
        let translation: String
        var reading: String?
        var partOfSpeech: String?
        var example: String?
        var register: String?
        var notes: String?
        var tags: [String]?
    }

    struct AddGrammar: Decodable {
        let point: String
        let explanation: String
        var example: String?
        var notes: String?
        var tags: [String]?
    }

    struct Review: Decodable {
        let id: UUID
        let correct: Bool
    }

    struct MultipleChoice: Decodable {
        let questions: [Question]

        struct Question: Decodable {
            let prompt: String
            let options: [String]
            var correctIndex: Int?
            var itemID: UUID?
        }
    }
}