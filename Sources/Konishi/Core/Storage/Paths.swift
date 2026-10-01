import Foundation

/// On-disk locations for Konishi's data (discoverable, hand-editable).
enum Paths {
    static let root: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Konishi", isDirectory: true)

    static let conversations = root.appendingPathComponent("conversations", isDirectory: true)
    static let memory = root.appendingPathComponent("memory", isDirectory: true)
    /// Facts awaiting promotion to long-term memory, plus the active-day clock.
    static let shortTermMemory = root.appendingPathComponent("memory-short-term.json")
    static let personasFile = root.appendingPathComponent("personas.json")
    static let venv = root.appendingPathComponent("env", isDirectory: true)
    static let serversFile = root.appendingPathComponent("servers.json")
    /// PIDs of servers Konishi launched, so orphans survive app restarts and port edits.
    static let runningServersFile = root.appendingPathComponent("running-servers.json")
    static let cache = root.appendingPathComponent("cache", isDirectory: true)
    static let logs = root.appendingPathComponent("logs", isDirectory: true)
    static let pythonDir = root.appendingPathComponent("python", isDirectory: true)
    /// Working directory for agent-created files (python_exec), one folder per conversation.
    static let filesRoot = root.appendingPathComponent("files", isDirectory: true)
    static let documents = root.appendingPathComponent("documents", isDirectory: true)
    /// Per-conversation request/response traces (JSON), one file per conversation.
    static let traces = root.appendingPathComponent("traces", isDirectory: true)
    /// Language-learning data (profiles + spaced-repetition deck).
    static let language = root.appendingPathComponent("language", isDirectory: true)
    static let languageDB = language.appendingPathComponent("deck.sqlite")
    /// Timestamped snapshots of memory taken before a consolidation rewrite (reversible).
    static let memoryBackups = root.appendingPathComponent("memory-backups", isDirectory: true)

    static func traceFile(_ id: UUID) -> URL {
        try? FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
        return traces.appendingPathComponent("\(id.uuidString).json")
    }

    static func serverLog(_ id: UUID) -> URL {
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("\(id.uuidString).log")
    }

    static func ensure() {
        for dir in [root, conversations, memory, cache, logs, pythonDir, traces, language] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Per-conversation folder for files the agent creates (e.g. plots, CSVs, exports).
    static func conversationFiles(_ id: UUID) -> URL {
        let url = filesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
