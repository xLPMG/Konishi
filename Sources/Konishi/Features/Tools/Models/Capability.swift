import Foundation

enum Capability: String, CaseIterable, Codable, Sendable {
    case workspaceRead
    case externalRead
    case memoryRead
    case recallRead
    case vaultRead
    case personalDataRead
    case deckRead
    case webAccess
    case workspaceWrite
    case externalWrite
    case memoryWrite
    case vaultWrite
    case personalDataWrite
    case deckWrite
    case shellAllowlisted
    case codeExecution
    case userInput

    enum Kind: String, Codable, Sendable {
        case read
        case write
        case execute
        case interact
    }

    enum Risk: String, Codable, Sendable {
        case low
        case medium
        case high
    }

    var kind: Kind {
        switch self {
        case .workspaceRead, .externalRead, .memoryRead, .recallRead, .vaultRead,
             .personalDataRead, .deckRead, .webAccess:
            .read
        case .workspaceWrite, .externalWrite, .memoryWrite, .vaultWrite,
             .personalDataWrite, .deckWrite:
            .write
        case .shellAllowlisted, .codeExecution:
            .execute
        case .userInput:
            .interact
        }
    }

    var risk: Risk {
        switch self {
        case .externalWrite, .externalRead, .personalDataWrite, .codeExecution:
            .high
        case .memoryWrite, .vaultWrite, .webAccess, .personalDataRead, .shellAllowlisted:
            .medium
        default:
            .low
        }
    }

    var label: String {
        switch self {
        case .workspaceRead: "Read workspace"
        case .externalRead: "Read external files"
        case .memoryRead: "Read memory"
        case .recallRead: "Read past conversations"
        case .vaultRead: "Read research vault"
        case .personalDataRead: "Read personal data"
        case .deckRead: "Read language deck"
        case .webAccess: "Access the web"
        case .workspaceWrite: "Write workspace"
        case .externalWrite: "Write external files"
        case .memoryWrite: "Write memory"
        case .vaultWrite: "Write research vault"
        case .personalDataWrite: "Write personal data"
        case .deckWrite: "Write language deck"
        case .shellAllowlisted: "Run allowlisted commands"
        case .codeExecution: "Execute code"
        case .userInput: "Request user input"
        }
    }

    var groupLabel: String {
        switch self {
        case .workspaceRead, .workspaceWrite: "Workspace"
        case .externalRead, .externalWrite: "External"
        case .memoryRead, .memoryWrite: "Memory"
        case .recallRead: "Conversation history"
        case .vaultRead, .vaultWrite: "Vault"
        case .personalDataRead, .personalDataWrite: "Personal data"
        case .deckRead, .deckWrite: "Language deck"
        case .webAccess: "Web"
        case .shellAllowlisted, .codeExecution: "Code"
        case .userInput: "Interaction"
        }
    }

    func defaultDecision(for mode: AppMode) -> PermissionDecision {
        switch self {
        case .workspaceRead, .workspaceWrite, .memoryRead, .recallRead, .vaultRead,
             .personalDataRead, .webAccess, .shellAllowlisted:
            .allow
        case .deckRead, .deckWrite:
            mode == .language ? .allow : .ask
        case .memoryWrite, .vaultWrite, .personalDataWrite, .externalRead,
             .externalWrite, .codeExecution, .userInput:
            .ask
        }
    }
}