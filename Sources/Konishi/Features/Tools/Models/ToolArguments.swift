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
    struct FinanceLookup: Decodable {
        let identifier: String
        var identifierType: String?
    }
    struct FinanceQuote: Decodable {
        let identifier: String
        var identifierType: String?
        var exchange: String?
    }
    struct FinanceHistory: Decodable {
        let identifier: String
        var days: Int?
    }
    struct FinanceSeries: Decodable {
        let seriesId: String
        var days: Int?
    }
    struct FinancePortfolio: Decodable {
        let currency: String
        let holdings: [FinanceData.HoldingInput]
    }
    struct FinanceScenario: Decodable {
        let currency: String
        let initialAmount: Double
        let monthlyContribution: Double
        let years: Int
        let annualReturnPercent: Double
        let annualFeePercent: Double
        let inflationPercent: Double
    }
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

}