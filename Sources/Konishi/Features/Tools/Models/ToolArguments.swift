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
    struct FileWrite: Decodable {
        let path: String
        let content: String
    }

    struct ConversationSearch: Decodable {
        let query: String
        var limit: Int?
    }
    struct ConversationList: Decodable {
        var days: Int?
        var limit: Int?
    }
    struct ConversationRead: Decodable { let id: String }

    struct URLValue: Decodable { let url: String }
    struct Query: Decodable { let query: String }
    struct Research: Decodable {
        let query: String
        var maxSources: Int?
    }
    struct Python: Decodable { let code: String }
    struct Shell: Decodable {
        let command: String
        var workingDirectory: String?
        var timeoutSeconds: Int?
    }
    struct Calculation: Decodable { let expression: String }
    struct DueItems: Decodable { var limit: Int? }

    struct CalendarEvents: Decodable {
        var days: Int?
        var calendar: String?
    }
    struct CalendarCreateEvent: Decodable {
        let title: String
        let startDate: String
        let endDate: String
        var location: String?
        var notes: String?
        var calendar: String?
    }
    struct CalendarUpdateEvent: Decodable {
        let eventID: String
        var title: String?
        var startDate: String?
        var endDate: String?
        var location: String?
        var notes: String?
    }
    struct RemindersList: Decodable {
        var days: Int?
        var includeUndated: Bool?
        var query: String?
        var limit: Int?
    }
    struct ReminderCreate: Decodable {
        let title: String
        var dueDate: String?
        var notes: String?
        var priority: Int?
    }
    struct ReminderUpdate: Decodable {
        let reminderID: String
        var title: String?
        var dueDate: String?
        var clearDueDate: Bool?
        var notes: String?
        var priority: Int?
        var completed: Bool?
    }

    struct VaultSearch: Decodable {
        let query: String
        var maxResults: Int?
    }
    struct VaultRead: Decodable { let note: String }
    struct VaultList: Decodable { var folder: String? }
    struct VaultWrite: Decodable {
        let note: String
        let content: String
    }

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